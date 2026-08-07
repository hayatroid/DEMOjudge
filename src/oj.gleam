import adapters/os
import adapters/sandbox
import adapters/store
import app/runner
import app/view/reader
import app/writer.{type Config, type Lease}
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import ports/console
import ports/web

pub fn main() -> Nil {
  case os.argv() {
    ["run"] -> run()
    _ -> panic as "usage: oj run"
  }
}

// owner names the OS process rather than the box: a lease dies with the
// process that took it.
fn owner() -> String {
  os.getenv("OJ_OWNER", "local") <> "#" <> os.os_pid()
}

fn number(name: String, fallback: String) -> Int {
  let assert Ok(value) = int.parse(os.getenv(name, fallback))
    as { name <> " is not a number" }
  value
}

// runners is 0 or 1 because holding is a single Option: a node holds at most
// one lease.
fn runners(count: Int) -> Option(process.Name(Lease)) {
  case count {
    0 -> None
    1 -> Some(process.new_name("oj_runner"))
    _ -> panic as "OJ_RUNNERS is 0 or 1"
  }
}

fn run() -> Nil {
  let names =
    writer.Names(
      writer: process.new_name("oj_writer"),
      runner: runners(number("OJ_RUNNERS", "1")),
    )
  case names.runner {
    Some(_) -> sandbox.require()
    None -> Nil
  }
  os.tune()
  let dir = os.getenv("OJ_DIR", "var")
  os.mkdir(dir <> "/src")
  os.write_file(dir <> "/node.pid", os.os_pid())
  let config =
    writer.Config(
      dir:,
      port: number("OJ_PORT", "7391"),
      http_port: number("OJ_HTTP_PORT", "8080"),
      store: store.open(owner()),
      lease_ms: number("OJ_LEASE_SECS", "15") * 1000,
      tick_ms: number("OJ_TICK_MS", "1000"),
      names:,
    )
  // The tree is linked to its starter, so an untrapped main folds with it and
  // outlive never gets to die.
  process.trap_exits(True)
  let views = process.new_name("oj_view")
  let assert Ok(tree) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(supervision.supervisor(fn() { query(config, views) }))
    |> supervisor.add(supervision.supervisor(fn() { command(config, views) }))
    |> supervisor.start
  outlive(tree.pid)
}

fn query(
  config: Config,
  views: process.Name(reader.Msg),
) -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.RestForOne)
  |> supervisor.add(
    supervision.worker(fn() {
      reader.start(config.store, config.tick_ms, views)
    }),
  )
  |> supervisor.add(supervision.worker(fn() { web.start(config, views) }))
  |> supervisor.start
}

fn command(
  config: Config,
  views: process.Name(reader.Msg),
) -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.RestForOne)
  |> supervisor.add(supervision.worker(fn() { writer.start(config) }))
  |> hand(config)
  |> supervisor.add(supervision.worker(fn() { console.start(config, views) }))
  |> supervisor.start
}

// The runner stands after the writer because a RestForOne child after the
// writer folds with it.
fn hand(tree: supervisor.Builder, config: Config) -> supervisor.Builder {
  case config.names.runner {
    None -> tree
    Some(name) ->
      supervisor.add(
        tree,
        supervision.worker(fn() { runner.start(config, name) }),
      )
  }
}

// Measured: a BEAM that outlives its tree keeps the service alive with the HTTP
// port closed.
fn outlive(tree: process.Pid) -> Nil {
  let collapsed = process.monitor(tree)
  process.new_selector()
  |> process.select_specific_monitor(collapsed, fn(_) { Nil })
  |> process.selector_receive_forever
  os.die(1)
}

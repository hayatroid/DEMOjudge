import adapters/os
import gleam/list
import gleam/string

const cache_ms: Int = 10_000

pub type Runner {
  Runner(runner: String, host: String, state: String)
}

/// An owner is OJ_OWNER#pid, and OJ_OWNER carries the host's name, so the
/// fleet is joined by prefix.
pub fn host_of(owner: String) -> Result(String, Nil) {
  case list.filter(runners(), fn(one) { string.starts_with(owner, one.host) }) {
    [one, ..] -> Ok(one.host)
    [] -> Error(Nil)
  }
}

pub fn host_for(runner: String) -> Result(String, Nil) {
  case list.filter(runners(), fn(one) { one.runner == runner }) {
    [one, ..] -> Ok(one.host)
    [] -> Error(Nil)
  }
}

pub fn runners() -> List(Runner) {
  case cache_get("runners") {
    Ok(found) -> found
    Error(_) -> {
      let found = discover()
      cache_put("runners", found, cache_ms)
      found
    }
  }
}

fn discover() -> List(Runner) {
  let query =
    "'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`OJKill`]|[0].Value]'"
  let answer =
    sh(
      "aws ec2 describe-instances --region "
      <> region()
      <> " --filters 'Name=tag:Name,Values=oj-worker'"
      <> " 'Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped'"
      <> " --query "
      <> query
      <> " --output text 2>/dev/null",
    )
  let found =
    string.split(string.trim(answer), "\n")
    |> list.filter_map(fn(row) {
      case string.split(row, "\t") {
        [host, state, runner] -> Ok(Runner(plain(runner), host, state))
        _ -> Error(Nil)
      }
    })
  case found {
    [] -> [Runner("runner-0", os.getenv("OJ_OWNER", "local"), "running")]
    known -> known
  }
}

pub fn kill(host: String) -> Result(String, String) {
  fire(host, kill_command)
}

pub fn stop(host: String) -> Result(String, String) {
  fire(host, stop_command)
}

fn fire(host: String, command: fn(String) -> String) -> Result(String, String) {
  case named(host) {
    False -> Error("reject malformed")
    True -> shot(command(host))
  }
}

fn kill_command(host: String) -> String {
  "aws ssm send-command --region "
  <> region()
  <> " --instance-ids "
  <> host
  <> " --document-name AWS-RunShellScript"
  <> " --parameters commands='systemctl stop oj ; sleep "
  <> os.getenv("OJ_KILL_SECONDS", "60")
  <> " ; systemctl start oj'"
  <> " --query 'Command.CommandId' --output text 2>&1"
}

fn stop_command(host: String) -> String {
  case template(host) {
    Ok(id) ->
      "aws fis start-experiment --region "
      <> region()
      <> " --experiment-template-id "
      <> id
      <> " --query 'experiment.id' --output text 2>&1"
    Error(_) ->
      "aws ec2 stop-instances --region "
      <> region()
      <> " --instance-ids "
      <> host
      <> " --query 'StoppingInstances[0].CurrentState.Name' --output text 2>&1"
  }
}

fn template(host: String) -> Result(String, Nil) {
  let table =
    string.split(os.getenv("OJ_FIS_TEMPLATES", ""), ",")
    |> list.filter_map(fn(pair) {
      case string.split(pair, "=") {
        [runner, id] -> Ok(#(runner, id))
        _ -> Error(Nil)
      }
    })
  case list.filter(runners(), fn(one) { one.host == host }) {
    [one, ..] -> list.key_find(table, one.runner)
    [] -> Error(Nil)
  }
}

// os:cmd answers output without the exit code, so failure is judged by the
// text.
fn shot(command: String) -> Result(String, String) {
  let text = string.trim(sh(command))
  case text == "" || string.contains(text, "error") {
    True -> {
      os.stderr(text <> "\n")
      Error("reject not-fired")
    }
    False -> Ok(text)
  }
}

fn region() -> String {
  os.getenv("AWS_REGION", "ap-northeast-1")
}

fn plain(field: String) -> String {
  case field {
    "None" -> ""
    other -> other
  }
}

fn named(host: String) -> Bool {
  host != ""
  && list.all(string.to_graphemes(host), fn(c) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789-#", c)
  })
}

@external(erlang, "oj_ffi", "sh")
fn sh(command: String) -> String

@external(erlang, "oj_ffi", "cache_get")
fn cache_get(key: String) -> Result(List(a), Nil)

@external(erlang, "oj_ffi", "cache_put")
fn cache_put(key: String, value: List(a), ms: Int) -> Nil

import adapters/os
import app/view/escalations.{type Escalation}
import app/view/reader
import app/view/standings.{type Standing}
import app/writer.{type Config}
import domain/submission/command
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/string

type Socket

const listening: String = "listening"

pub fn start(
  config: Config,
  views: Name(reader.Msg),
) -> Result(actor.Started(Nil), actor.StartError) {
  Ok(actor.Started(process.spawn(fn() { listen(config, views) }), Nil))
}

fn listen(config: Config, views: Name(reader.Msg)) -> Nil {
  let listener = tcp_listen(config.port)
  os.stderr(listening <> "\n")
  serve(config, views, listener)
}

fn serve(config: Config, views: Name(reader.Msg), listener: Socket) -> Nil {
  let socket = accept(listener)
  case recv(socket) {
    Ok(line) -> tcp_send(socket, answer(config, views, line))
    Error(_) -> Nil
  }
  tcp_close(socket)
  serve(config, views, listener)
}

fn answer(config: Config, views: Name(reader.Msg), line: String) -> String {
  case string.split(line, " ") {
    ["view", name] -> view(views, name)
    ["submit", submission, lang] ->
      said(writer.submit(config, submission, lang, os.now_ms()))
    ["resolve", submission, reason] ->
      said(writer.resolve(config, submission, reason))
    ["name", user, problem] -> writer.name(config, user, problem) <> "\n"
    ["idle"] ->
      case writer.idle(config) {
        True -> "idle\n"
        False -> "busy\n"
      }
    _ -> "reject unknown-command\n"
  }
}

fn said(answered: Result(Nil, command.Rejection)) -> String {
  case answered {
    Ok(_) -> "ok\n"
    Error(rejection) -> "reject " <> command.word(rejection) <> "\n"
  }
}

fn view(views: Name(reader.Msg), name: String) -> String {
  case name {
    "standings" -> rows(list.map(reader.standings(views), standing))
    "escalations" -> rows(list.map(reader.escalations(views), escalation))
    _ -> "reject unknown-view\n"
  }
}

fn standing(one: Standing) -> String {
  string.join(
    [
      int.to_string(one.rank),
      one.user,
      int.to_string(one.solved),
      int.to_string(one.penalty),
    ],
    " ",
  )
}

fn escalation(one: Escalation) -> String {
  string.join([one.submission, int.to_string(one.allowance), one.reason], " ")
}

fn rows(lines: List(String)) -> String {
  list.fold(lines, "", fn(acc, row) { acc <> row <> "\n" })
}

@external(erlang, "oj_ffi", "listen")
fn tcp_listen(port: Int) -> Socket

@external(erlang, "oj_ffi", "accept")
fn accept(listener: Socket) -> Socket

@external(erlang, "oj_ffi", "recv")
fn recv(socket: Socket) -> Result(String, Nil)

@external(erlang, "oj_ffi", "tcp_send")
fn tcp_send(socket: Socket, text: String) -> Nil

@external(erlang, "oj_ffi", "tcp_close")
fn tcp_close(socket: Socket) -> Nil

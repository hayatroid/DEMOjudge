import adapters/fleet
import adapters/json.{type Json, A, N, Null, O, S}
import adapters/os
import adapters/store
import app/view/escalations.{type Escalation}
import app/view/leases.{type Holding}
import app/view/reader
import app/view/standings.{type Standing}
import app/writer.{type Config}
import domain/submission/command
import domain/submission/event.{type Submission}
import domain/submission/fold
import gleam/bit_array
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri

type Socket

const serving: String = "serving"

const watch_ms: Int = 250

const watch_limit_ms: Int = 120_000

type Wanted {
  Any
  One(Submission)
}

type Sent {
  Sent(
    cursor: Int,
    traps: String,
    leases: String,
    standings: String,
    escalations: String,
    phases: String,
    scores: List(Standing),
  )
}

pub fn start(
  config: Config,
  views: Name(reader.Msg),
) -> Result(actor.Started(Nil), actor.StartError) {
  Ok(actor.Started(process.spawn(fn() { listen(config, views) }), Nil))
}

fn listen(config: Config, views: Name(reader.Msg)) -> Nil {
  let listener = http_listen(config.http_port)
  os.stderr(serving <> "\n")
  http_serve(listener, fn(socket) { serve(config, views, socket) })
}

fn serve(config: Config, views: Name(reader.Msg), socket: Socket) -> Nil {
  case http_request(socket) {
    Ok(#(method, target, token, kind, body)) ->
      route(
        config,
        views,
        socket,
        method,
        target,
        token,
        form(kind, body),
        body,
      )
    Error(_) -> Nil
  }
  tcp_close(socket)
}

fn form(kind: String, body: String) -> String {
  case string.contains(kind, "form-urlencoded") {
    True -> body
    False -> ""
  }
}

fn route(
  config: Config,
  views: Name(reader.Msg),
  socket: Socket,
  method: String,
  target: String,
  token: String,
  fields: String,
  body: String,
) -> Nil {
  let #(path, query) = case string.split_once(target, "?") {
    Ok(pair) -> pair
    Error(_) -> #(target, "")
  }
  let ask = fn(key) { param(query, fields, key) }
  case method, path {
    "GET", "/" -> asset(socket, "/index.html")
    "GET", "/login" -> login(socket, ask("token"))
    "GET", "/api/events" -> events(config, views, socket)
    "GET", "/api/escalations" ->
      data(socket, escalations_json(reader.escalations(views)))
    "GET", "/api/standings" ->
      data(socket, standings_json(reader.standings(views)))
    "GET", "/api/conformance" -> data(socket, reader.conformance(views))
    "GET", "/api/leases" -> data(socket, leases_json(reader.leases(views)))
    "GET", "/api/phases" -> data(socket, phases_json(reader.phases(views)))
    "GET", "/api/traps" -> data(socket, traps())
    "POST", "/api/submit" ->
      guarded(socket, token, fn() { submit(config, socket, ask, body) })
    "POST", "/api/resolve" ->
      guarded(socket, token, fn() {
        let reason = case ask("reason") {
          "" -> "referee"
          given -> given
        }
        order(socket, writer.resolve(config, ask("submission"), reason), [
          #("submission", S(ask("submission"))),
          #("event", S("EscalationResolved")),
        ])
      })
    "POST", "/api/trap" ->
      guarded(socket, token, fn() { trap(config, views, socket, ask) })
    "GET", _ ->
      case named(path) {
        True -> asset(socket, path)
        False -> answer(socket, 404, O([#("error", S("reject unknown-route"))]))
      }
    _, _ -> answer(socket, 404, O([#("error", S("reject unknown-route"))]))
  }
}

fn submit(
  config: Config,
  socket: Socket,
  ask: fn(String) -> String,
  body: String,
) -> Nil {
  let submission = case ask("submission") {
    "" -> writer.name(config, ask("user"), ask("problem"))
    given -> given
  }
  let lang = case ask("lang") {
    "" -> "c"
    given -> given
  }
  let source = case ask("source") {
    "" -> body
    given -> given
  }
  case
    command.name_ok(submission)
    && command.name_ok(lang)
    && string.trim(source) != ""
  {
    False ->
      answer(
        socket,
        409,
        O([#("error", S("reject malformed")), #("submission", S(submission))]),
      )
    True -> {
      case store.source(config.store, submission) {
        Ok(_) -> Nil
        Error(_) -> store.stow(config.store, submission, source)
      }
      // The IAM role can append and not delete, so a refused body is left
      // orphaned.
      case writer.submit(config, submission, lang, os.now_ms()) {
        Ok(_) ->
          answer(
            socket,
            202,
            O([
              #("submission", S(submission)),
              #("event", S("SubmissionReceived")),
            ]),
          )
        Error(rejection) ->
          answer(
            socket,
            409,
            O([
              #("error", S("reject " <> command.word(rejection))),
              #("submission", S(submission)),
            ]),
          )
      }
    }
  }
}

fn order(
  socket: Socket,
  answered: Result(Nil, command.Rejection),
  told: List(#(String, Json)),
) -> Nil {
  case answered {
    Ok(_) -> answer(socket, 200, O(told))
    Error(rejection) ->
      answer(
        socket,
        409,
        O([#("error", S("reject " <> command.word(rejection)))]),
      )
  }
}

// A reservation is not a fact: it lives in this node's memory and dies with the
// node.
fn traps() -> Json {
  A(
    list.map(trap_list(), fn(one) {
      O([#("trap", S(one.0)), #("submission", S(one.1))])
    }),
  )
}

fn trap(
  config: Config,
  views: Name(reader.Msg),
  socket: Socket,
  ask: fn(String) -> String,
) -> Nil {
  let trap = ask("trap")
  let submission = ask("submission")
  case fold.parse(trap), list.key_find(trap_list(), trap) {
    Error(_), _ ->
      answer(socket, 409, O([#("error", S("reject unknown-phase"))]))
    Ok(_), Ok(_) -> {
      trap_clear(trap)
      answer(socket, 200, O([#("trap", S(trap))]))
    }
    Ok(phase), Error(_) -> {
      // The reservation is read by the watcher below and by the traps view,
      // never by the runner; the delay that holds a phase is OJ_DELAY_MS.
      trap_set(trap, submission)
      process.spawn(fn() {
        trapping(
          config,
          views,
          wanted(submission),
          phase,
          watch_limit_ms / watch_ms,
        )
      })
      answer(
        socket,
        202,
        O([#("trap", S(trap)), #("submission", S(submission))]),
      )
    }
  }
}

fn wanted(submission: String) -> Wanted {
  case submission {
    "" -> Any
    given -> One(given)
  }
}

fn trapping(
  config: Config,
  views: Name(reader.Msg),
  wanted: Wanted,
  phase: fold.Phase,
  fuel: Int,
) -> Nil {
  let trap = fold.word(phase)
  case fuel, list.key_find(trap_list(), trap) {
    0, _ -> trap_clear(trap)
    _, Error(_) -> Nil
    _, Ok(_) ->
      case trapped(reader.hosts(views, phase), wanted) {
        Ok(id) -> {
          trap_clear(trap)
          case fleet.local(id) {
            // A lone node has no fleet to shoot; its writer falls instead,
            // and rest_for_one folds the runner with it.
            True -> down(config)
            False -> {
              let _ = fleet.stop(id)
              Nil
            }
          }
        }
        Error(_) -> {
          process.sleep(watch_ms)
          trapping(config, views, wanted, phase, fuel - 1)
        }
      }
  }
}

fn down(config: Config) -> Nil {
  case process.named(config.names.writer) {
    Ok(pid) -> process.kill(pid)
    Error(_) -> Nil
  }
}

fn trapped(
  hosts: List(#(Submission, String)),
  wanted: Wanted,
) -> Result(String, Nil) {
  case wanted {
    Any -> list.first(list.map(hosts, fn(one) { one.1 }))
    One(submission) -> list.key_find(hosts, submission)
  }
}

fn guarded(socket: Socket, token: String, run: fn() -> Nil) -> Nil {
  let expected = os.getenv("OJ_TOKEN", "")
  case expected != "" && token == expected {
    True -> run()
    False -> answer(socket, 403, O([#("error", S("reject not-referee"))]))
  }
}

fn login(socket: Socket, token: String) -> Nil {
  let expected = os.getenv("OJ_TOKEN", "")
  case expected != "" && token == expected {
    False -> answer(socket, 403, O([#("error", S("reject not-referee"))]))
    True -> {
      let _ =
        http_write(
          socket,
          "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
            <> "Set-Cookie: oj_token="
            <> token
            <> "; Path=/; Max-Age=604800; SameSite=Lax\r\n"
            <> "Content-Length: 0\r\nConnection: close\r\n\r\n",
        )
      Nil
    }
  }
}

fn events(config: Config, views: Name(reader.Msg), socket: Socket) -> Nil {
  let _ =
    http_write(
      socket,
      "HTTP/1.1 200 OK\r\n"
        <> "Content-Type: text/event-stream\r\n"
        <> "Cache-Control: no-cache\r\n"
        <> "Access-Control-Allow-Origin: *\r\n"
        <> "Connection: close\r\n\r\n",
    )
  store.watch(config.store)
  stream(config, views, socket, Sent(0, "", "", "", "", "", []))
}

// One question to reader per round, so the rows and the board come from one fold.
fn stream(
  config: Config,
  views: Name(reader.Msg),
  socket: Socket,
  sent: Sent,
) -> Nil {
  let seen = reader.sheet(views, sent.cursor)
  let rows = standings_json(seen.standings)
  let fresh =
    Sent(
      cursor: seen.seq,
      traps: json.render(traps()),
      leases: json.render(leases_json(seen.leases)),
      standings: json.render(rows),
      escalations: json.render(escalations_json(seen.escalations)),
      phases: json.render(phases_json(seen.phases)),
      scores: seen.standings,
    )
  let sheet =
    json.render(
      O([
        #("rows", rows),
        #(
          "changed",
          A(list.map(moved(sent.standings, sent.scores, seen.standings), S)),
        ),
      ]),
    )
  case
    feed(
      socket,
      list.map(seen.events, fn(one) {
        #("events", json.render(event_json(one.0, one.1)))
      }),
    )
    |> emit(socket, "traps", sent.traps != fresh.traps, fresh.traps)
    |> emit(socket, "phases", sent.phases != fresh.phases, fresh.phases)
    |> emit(socket, "leases", sent.leases != fresh.leases, fresh.leases)
    |> emit(
      socket,
      "escalations",
      sent.escalations != fresh.escalations,
      fresh.escalations,
    )
    |> emit(socket, "standings", sent.standings != fresh.standings, sheet)
  {
    Error(_) -> Nil
    Ok(_) -> {
      let _ = store.pause(config.store, 1000)
      stream(config, views, socket, fresh)
    }
  }
}

// An empty sent is the first frame: there is nothing to compare, so no row
// counts as changed.
fn moved(
  sent: String,
  before: List(Standing),
  after: List(Standing),
) -> List(String) {
  case sent {
    "" -> []
    _ ->
      list.filter_map(after, fn(row) {
        case list.find(before, fn(one) { one.user == row.user }) {
          Ok(one) if one.solved == row.solved && one.penalty == row.penalty ->
            Error(Nil)
          _ -> Ok(row.user)
        }
      })
  }
}

// A line goes out as the cells event.gleam names, so the screen is handed the
// fields and never the format they are written in.
fn event_json(seq: Int, e: event.Event) -> Json {
  let #(five, six) = event.fields(e)
  O([
    #("seq", N(seq)),
    #("event", S(event.name(e))),
    #("submission", S(event.submission(e))),
    #("attempt", N(event.attempt(e))),
    #(five.name, S(five.value)),
    #(six.name, S(six.value)),
  ])
}

fn standings_json(rows: List(Standing)) -> Json {
  A(
    list.map(rows, fn(one) {
      O([
        #("rank", N(one.rank)),
        #("user", S(one.user)),
        #("solved", N(one.solved)),
        #("penalty", N(one.penalty)),
      ])
    }),
  )
}

fn escalations_json(rows: List(Escalation)) -> Json {
  A(
    list.map(rows, fn(one) {
      O([
        #("submission", S(one.submission)),
        #("allowance", N(one.allowance)),
        #("reason", S(one.reason)),
      ])
    }),
  )
}

fn phases_json(rows: List(#(String, fold.Phase))) -> Json {
  O(list.map(rows, fn(one) { #(one.0, S(fold.word(one.1))) }))
}

fn leases_json(rows: List(Holding)) -> Json {
  O(
    list.map(rows, fn(one) {
      #(
        one.runner,
        O([
          #("host", S(one.host)),
          #("state", S(one.state)),
          #("submission", case one.submission {
            Some(submission) -> S(submission)
            None -> Null
          }),
          #("leased_until", N(option.unwrap(one.until, 0))),
        ]),
      )
    }),
  )
}

fn emit(
  carry: Result(Nil, Nil),
  socket: Socket,
  name: String,
  when: Bool,
  data: String,
) -> Result(Nil, Nil) {
  case carry, when {
    Error(_), _ -> Error(Nil)
    Ok(_), False -> Ok(Nil)
    Ok(_), True -> feed(socket, [#(name, data)])
  }
}

fn feed(socket: Socket, messages: List(#(String, String))) -> Result(Nil, Nil) {
  case messages {
    [] -> Ok(Nil)
    [#(name, data), ..rest] ->
      case
        http_write(socket, "event: " <> name <> "\ndata: " <> data <> "\n\n")
      {
        Ok(_) -> feed(socket, rest)
        Error(_) -> Error(Nil)
      }
  }
}

fn named(path: String) -> Bool {
  let name = string.drop_start(path, 1)
  string.starts_with(path, "/")
  && name != ""
  && !string.contains(name, "..")
  && list.all(string.to_graphemes(name), fn(c) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_",
      c,
    )
  })
}

fn asset(socket: Socket, path: String) -> Nil {
  let root = os.getenv("OJ_WEB", "web")
  case os.read_file(root <> path) {
    Ok(body) -> send(socket, 200, kind(path), body)
    Error(_) -> answer(socket, 404, O([#("error", S("reject unknown-route"))]))
  }
}

fn kind(path: String) -> String {
  case string.split(path, ".") |> list.last {
    Ok("html") -> "text/html; charset=utf-8"
    Ok("css") -> "text/css; charset=utf-8"
    Ok("js") -> "text/javascript; charset=utf-8"
    Ok("json") -> "application/json"
    Ok("svg") -> "image/svg+xml"
    _ -> "text/plain; charset=utf-8"
  }
}

fn data(socket: Socket, value: Json) -> Nil {
  answer(socket, 200, value)
}

fn answer(socket: Socket, status: Int, value: Json) -> Nil {
  send(socket, status, "application/json", json.render(value) <> "\n")
}

fn send(socket: Socket, status: Int, kind: String, body: String) -> Nil {
  let _ =
    http_write(
      socket,
      "HTTP/1.1 "
        <> int.to_string(status)
        <> " "
        <> phrase(status)
        <> "\r\nContent-Type: "
        <> kind
        <> "\r\nContent-Length: "
        <> int.to_string(bit_array.byte_size(bit_array.from_string(body)))
        // Measured after a redeploy: a cached client drew phases that had
        // stopped moving.
        <> "\r\nCache-Control: no-cache"
        <> "\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        <> body,
    )
  Nil
}

fn phrase(status: Int) -> String {
  case status {
    200 -> "OK"
    202 -> "Accepted"
    303 -> "See Other"
    403 -> "Forbidden"
    404 -> "Not Found"
    409 -> "Conflict"
    _ -> "OK"
  }
}

pub fn param(query: String, fields: String, key: String) -> String {
  case find(query, key) {
    "" -> find(fields, key)
    given -> given
  }
}

// A query that does not decode carries no field, the same as one that is empty.
fn find(text: String, key: String) -> String {
  uri.parse_query(text)
  |> result.try(list.key_find(_, key))
  |> result.unwrap("")
}

@external(erlang, "oj_web", "listen")
fn http_listen(port: Int) -> Socket

@external(erlang, "oj_web", "serve")
fn http_serve(listener: Socket, handler: fn(Socket) -> Nil) -> Nil

@external(erlang, "oj_web", "request")
fn http_request(
  socket: Socket,
) -> Result(#(String, String, String, String, String), Nil)

@external(erlang, "oj_web", "write")
fn http_write(socket: Socket, text: String) -> Result(Nil, Nil)

@external(erlang, "oj_ffi", "tcp_close")
fn tcp_close(socket: Socket) -> Nil

@external(erlang, "oj_ffi", "trap_set")
fn trap_set(trap: String, submission: String) -> Nil

@external(erlang, "oj_ffi", "trap_clear")
fn trap_clear(trap: String) -> Nil

@external(erlang, "oj_ffi", "traps")
fn trap_list() -> List(#(String, String))

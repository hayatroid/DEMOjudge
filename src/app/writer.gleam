//// Commands are serialised twice: the mailbox orders them inside a node, and
//// conditional writes with a re-decide loop order them between nodes.

import adapters/os
import adapters/store.{type Store}
import app/log
import domain/submission/command
import domain/submission/event.{type Event, type Submission}
import domain/submission/fold
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import trap

const append_tries: Int = 8

pub type Lease {
  Lease(submission: Submission, attempt: Int)
}

pub type Push {
  Committed
  LostLease
}

pub type Msg {
  Record(reply: Subject(Push), event: Event)
  Ready
  Submit(
    reply: Subject(Result(Nil, command.Rejection)),
    submission: Submission,
    lang: String,
    at: Int,
  )
  Resolve(
    reply: Subject(Result(Nil, command.Rejection)),
    submission: Submission,
    reason: String,
  )
  Name(reply: Subject(Submission), user: String, problem: String)
  Idle(reply: Subject(Bool))
  Tick
  Wake
}

pub type Names {
  Names(writer: Name(Msg), runner: Option(Name(Lease)))
}

pub type Config {
  Config(
    dir: String,
    port: Int,
    http_port: Int,
    store: Store,
    lease_ms: Int,
    tick_ms: Int,
    names: Names,
  )
}

type Runtime {
  Runtime(
    config: Config,
    state: fold.State,
    busy: Bool,
    holding: Option(Submission),
  )
}

pub fn subject(config: Config) -> Subject(Msg) {
  process.named_subject(config.names.writer)
}

// The panic is the recovery: the supervisor folds the runner, and the lease is
// left to expire into another node's hands.
pub fn record(config: Config, e: Event) -> Nil {
  case actor.call(subject(config), 60_000, fn(reply) { Record(reply, e) }) {
    Committed -> Nil
    LostLease -> panic as "the lease went stale mid-judgment"
  }
}

// A command can arrive in the middle of a pump round and waits out the whole
// of it, where a record cannot: pump is skipped while busy is true.
pub fn submit(
  config: Config,
  submission: Submission,
  lang: String,
  at: Int,
) -> Result(Nil, command.Rejection) {
  actor.call(subject(config), 300_000, fn(reply) {
    Submit(reply, submission, lang, at)
  })
}

pub fn resolve(
  config: Config,
  submission: Submission,
  reason: String,
) -> Result(Nil, command.Rejection) {
  actor.call(subject(config), 300_000, fn(reply) {
    Resolve(reply, submission, reason)
  })
}

pub fn name(config: Config, user: String, problem: String) -> Submission {
  actor.call(subject(config), 300_000, fn(reply) { Name(reply, user, problem) })
}

pub fn idle(config: Config) -> Bool {
  actor.call(subject(config), 300_000, Idle)
}

pub fn start(config: Config) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(60_000, fn(self) {
    // A lease dies with the writer that took it: each incarnation signs with
    // its own name, so a restarted writer waits out its predecessor's lease
    // like any other node instead of taking it back at once.
    let config =
      Config(
        ..config,
        store: store.open(
          store.owner(config.store) <> "#" <> int.to_string(os.now_ms()),
        ),
      )
    process.send_after(self, config.tick_ms, Tick)
    log.follow(config.store, config.tick_ms, fn() {
      process.send(subject(config), Wake)
    })
    // busy starts true only when a runner will send the Ready that clears it.
    let busy = option.is_some(config.names.runner)
    let rt = Runtime(config, fold.initial(), busy, None)
    actor.initialised(catch_up(rt))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(on_message)
  |> actor.named(config.names.writer)
  |> actor.start
}

fn on_message(rt: Runtime, msg: Msg) -> actor.Next(Runtime, Msg) {
  case msg {
    // Record carries a fact, so a lost seq leaves the same line to write again.
    Record(reply, e) -> {
      let #(rt, kept) = handle(rt, fn(_state) { Ok([e]) }, True)
      let assert Ok(kept) = kept as "a recorded fact cannot be rejected"
      process.send(reply, kept)
      actor.continue(rt)
    }
    Ready -> actor.continue(pump(catch_up(release(Runtime(..rt, busy: False)))))
    Submit(reply, submission, lang, at) ->
      ordered(rt, reply, command.Submit(submission, lang, at), trap.received)
    Resolve(reply, submission, reason) ->
      ordered(rt, reply, command.Resolve(submission, reason), trap.resolved)
    Name(reply, user, problem) -> {
      let rt = catch_up(rt)
      process.send(reply, fold.next_submission(rt.state, user, problem))
      actor.continue(rt)
    }
    Idle(reply) -> {
      let rt = catch_up(rt)
      process.send(reply, !rt.busy && fold.queued(rt.state) == [])
      actor.continue(rt)
    }
    Tick -> {
      process.send_after(subject(rt.config), rt.config.tick_ms, Tick)
      actor.continue(pump(renew(rt)))
    }
    Wake -> actor.continue(pump(catch_up(rt)))
  }
}

fn catch_up(rt: Runtime) -> Runtime {
  list.fold(log.since(rt.config.store, rt.state.seq), rt, fn(rt, one) {
    Runtime(..rt, state: fold.evolve(rt.state, one.1))
  })
}

fn deadline(rt: Runtime) -> Int {
  os.now_ms() + rt.config.lease_ms
}

// The result is dropped because a lease taken away answers Lost on the next
// fenced write.
fn renew(rt: Runtime) -> Runtime {
  case rt.holding {
    Some(submission) -> {
      let _ = store.acquire(rt.config.store, submission, deadline(rt))
      rt
    }
    None -> rt
  }
}

fn release(rt: Runtime) -> Runtime {
  case rt.holding {
    Some(submission) -> {
      let _ = store.acquire(rt.config.store, submission, os.now_ms() - 1)
      lost(rt)
    }
    None -> rt
  }
}

fn handle(
  rt: Runtime,
  choose: fn(fold.State) -> Result(List(Event), a),
  fenced: Bool,
) -> #(Runtime, Result(Push, a)) {
  retry_append(rt, choose, fenced, append_tries)
}

// choose runs again on the re-read state. A command carries its own clock, so a
// re-decide keeps the time the line arrived.
fn retry_append(
  rt: Runtime,
  choose: fn(fold.State) -> Result(List(Event), a),
  fenced: Bool,
  fuel: Int,
) -> #(Runtime, Result(Push, a)) {
  case fuel {
    0 -> panic as "the store never accepted the append"
    _ ->
      case choose(rt.state) {
        Error(reject) -> #(rt, Error(reject))
        Ok(events) ->
          case push(rt, events, fenced) {
            Ok(#(rt, kept)) -> #(rt, Ok(kept))
            Error(rt) -> retry_append(rt, choose, fenced, fuel - 1)
          }
      }
  }
}

fn push(
  rt: Runtime,
  events: List(Event),
  fenced: Bool,
) -> Result(#(Runtime, Push), Runtime) {
  case events {
    [] -> Ok(#(rt, Committed))
    [e, ..rest] ->
      case write(rt, e, fenced) {
        store.Written -> push(advanced(rt, e), rest, fenced)
        store.Duplicate -> push(catch_up(rt), rest, fenced)
        store.Taken -> {
          os.stderr("taken\n")
          Error(catch_up(rt))
        }
        store.Lost -> Ok(#(lost(catch_up(rt)), LostLease))
      }
  }
}

fn write(rt: Runtime, e: Event, fenced: Bool) -> store.Append {
  let seq = rt.state.seq + 1
  store.write(
    rt.config.store,
    seq,
    event.line(seq, e),
    event.submission(e),
    event.dedup(e),
    fenced,
  )
}

fn advanced(rt: Runtime, e: Event) -> Runtime {
  Runtime(..rt, state: fold.evolve(rt.state, e))
}

fn lost(rt: Runtime) -> Runtime {
  Runtime(..rt, holding: None)
}

// pump takes the delay once per round rather than once per candidate.
fn pump(rt: Runtime) -> Runtime {
  case rt.config.names.runner, rt.busy, fold.queued(rt.state) {
    Some(runner), False, [_, ..] as queued -> {
      trap.delay()
      offer(rt, runner, queued)
    }
    _, _, _ -> rt
  }
}

fn offer(rt: Runtime, runner: Name(Lease), queued: List(Submission)) -> Runtime {
  case queued {
    [] -> rt
    [submission, ..rest] -> {
      let until = deadline(rt)
      case store.acquire(rt.config.store, submission, until) {
        False -> offer(rt, runner, rest)
        True -> {
          let rt = catch_up(Runtime(..rt, holding: Some(submission)))
          case list.contains(fold.queued(rt.state), submission) {
            False -> offer(release(rt), runner, rest)
            True -> {
              let #(rt, kept) =
                handle(
                  rt,
                  fn(state) { Ok(command.escalation(state, submission)) },
                  True,
                )
              case kept, fold.escalated(rt.state, submission) {
                Ok(Committed), True -> {
                  trap.at(fold.word(fold.Escalated))
                  pump(release(rt))
                }
                Ok(Committed), False ->
                  case hand(rt, runner, submission, until) {
                    #(rt, Committed) -> rt
                    #(rt, LostLease) -> offer(release(rt), runner, rest)
                  }
                _, _ -> offer(release(rt), runner, rest)
              }
            }
          }
        }
      }
    }
  }
}

fn hand(
  rt: Runtime,
  runner: Name(Lease),
  submission: Submission,
  until: Int,
) -> #(Runtime, Push) {
  let owner = store.owner(rt.config.store)
  let #(rt, kept) =
    handle(rt, fn(state) { Ok(taking(state, submission, owner, until)) }, True)
  case kept {
    Ok(Committed) -> {
      process.send(
        process.named_subject(runner),
        Lease(submission, fold.attempt(rt.state, submission)),
      )
      #(Runtime(..rt, busy: True), Committed)
    }
    _ -> #(rt, LostLease)
  }
}

/// A lease still standing is let go of before the next one is taken, because
/// the model enables AttemptLeased only on a submission that is not leased.
pub fn taking(
  state: fold.State,
  submission: Submission,
  owner: String,
  until: Int,
) -> List(Event) {
  let displaced = case fold.lease(state, submission) {
    Ok(held) -> [event.LeaseExpired(submission, held.attempt, held.runner)]
    Error(_) -> []
  }
  list.append(displaced, [
    event.AttemptLeased(
      submission,
      fold.next_attempt(state, submission),
      owner,
      until,
    ),
  ])
}

fn ordered(
  rt: Runtime,
  reply: Subject(Result(Nil, command.Rejection)),
  cmd: command.Command,
  trapped: String,
) -> actor.Next(Runtime, Msg) {
  let #(rt, kept) = handle(catch_up(rt), command.decide(cmd, _), False)
  case kept {
    Error(rejection) -> {
      process.send(reply, Error(rejection))
      actor.continue(rt)
    }
    Ok(_) -> {
      trap.at(trapped)
      let rt = pump(rt)
      process.send(reply, Ok(Nil))
      actor.continue(rt)
    }
  }
}

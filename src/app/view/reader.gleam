import adapters/fleet
import adapters/json.{type Json}
import adapters/os
import adapters/store.{type Store}
import app/log
import app/view/conformance
import app/view/escalations
import app/view/leases
import app/view/phases
import app/view/standings
import domain/submission/event.{type Submission}
import domain/submission/fold
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor

pub type Msg {
  Standings(reply: Subject(List(standings.Standing)))
  Escalations(reply: Subject(List(escalations.Escalation)))
  Phases(reply: Subject(List(#(Submission, fold.Phase))))
  Leases(reply: Subject(List(leases.Holding)))
  Conformance(reply: Subject(Json))
  Sheet(reply: Subject(Views), from: Int)
  Hosts(reply: Subject(List(#(Submission, String))), phase: fold.Phase)
  Wake
}

pub type Views {
  Views(
    seq: Int,
    events: List(#(Int, event.Event)),
    phases: List(#(Submission, fold.Phase)),
    leases: List(leases.Holding),
    standings: List(standings.Standing),
    escalations: List(escalations.Escalation),
  )
}

type Runtime {
  Runtime(
    store: Store,
    tick_ms: Int,
    name: Name(Msg),
    state: fold.State,
    score: standings.State,
    escalation: escalations.State,
    // A fresh subscriber asks for the sheet from 0, so no line is dropped here.
    reversed: List(#(Int, event.Event)),
  )
}

pub fn subject(name: Name(Msg)) -> Subject(Msg) {
  process.named_subject(name)
}

pub fn standings(name: Name(Msg)) -> List(standings.Standing) {
  actor.call(subject(name), 60_000, Standings)
}

pub fn escalations(name: Name(Msg)) -> List(escalations.Escalation) {
  actor.call(subject(name), 60_000, Escalations)
}

pub fn phases(name: Name(Msg)) -> List(#(Submission, fold.Phase)) {
  actor.call(subject(name), 60_000, Phases)
}

pub fn leases(name: Name(Msg)) -> List(leases.Holding) {
  actor.call(subject(name), 60_000, Leases)
}

pub fn conformance(name: Name(Msg)) -> Json {
  actor.call(subject(name), 60_000, Conformance)
}

pub fn sheet(name: Name(Msg), from: Int) -> Views {
  actor.call(subject(name), 60_000, fn(reply) { Sheet(reply, from) })
}

pub fn hosts(name: Name(Msg), phase: fold.Phase) -> List(#(Submission, String)) {
  actor.call(subject(name), 60_000, fn(reply) { Hosts(reply, phase) })
}

pub fn start(
  store: Store,
  tick_ms: Int,
  name: Name(Msg),
) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(60_000, fn(self) {
    log.follow(store, tick_ms, fn() { process.send(subject(name), Wake) })
    let rt =
      Runtime(
        store:,
        tick_ms:,
        name:,
        state: fold.initial(),
        score: standings.initial(),
        escalation: escalations.initial(),
        reversed: [],
      )
    actor.initialised(catch_up(rt))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(on_message)
  |> actor.named(name)
  |> actor.start
}

fn on_message(rt: Runtime, msg: Msg) -> actor.Next(Runtime, Msg) {
  case msg {
    Standings(reply) -> {
      let rt = catch_up(rt)
      process.send(reply, standings.standings(rt.score))
      actor.continue(rt)
    }
    Escalations(reply) -> {
      let rt = catch_up(rt)
      process.send(reply, escalations.escalations(rt.escalation))
      actor.continue(rt)
    }
    Phases(reply) -> {
      let rt = catch_up(rt)
      process.send(
        reply,
        phases.phases(rt.state, store.peek(rt.store), os.now_ms()),
      )
      actor.continue(rt)
    }
    Leases(reply) -> {
      let rt = catch_up(rt)
      process.send(
        reply,
        leases.holdings(rt.state, store.peek(rt.store), fleet.runners()),
      )
      actor.continue(rt)
    }
    Conformance(reply) -> {
      let rt = catch_up(rt)
      process.send(reply, conformance_of(rt))
      actor.continue(rt)
    }
    // Sheet answers from the last subscription round rather than re-reading the
    // log.
    Sheet(reply, from) -> {
      process.send(reply, sheet_of(rt, from))
      actor.continue(rt)
    }
    Hosts(reply, phase) -> {
      process.send(reply, hosts_of(rt, phase))
      actor.continue(rt)
    }
    Wake -> actor.continue(catch_up(rt))
  }
}

fn catch_up(rt: Runtime) -> Runtime {
  list.fold(log.since(rt.store, rt.state.seq), rt, fn(rt, one) {
    let #(_, e) = one
    Runtime(
      ..rt,
      state: fold.evolve(rt.state, e),
      score: standings.evolve(rt.score, e),
      escalation: escalations.evolve(rt.escalation, e),
      reversed: [one, ..rt.reversed],
    )
  })
}

// The lease item and the fleet are not on the log, so the views that need them
// read the store and the fleet directly.
fn sheet_of(rt: Runtime, from: Int) -> Views {
  let peek = store.peek(rt.store)
  Views(
    seq: rt.state.seq,
    events: list.drop(list.reverse(rt.reversed), from),
    phases: phases.phases(rt.state, peek, os.now_ms()),
    leases: leases.holdings(rt.state, peek, fleet.runners()),
    standings: standings.standings(rt.score),
    escalations: escalations.escalations(rt.escalation),
  )
}

fn conformance_of(rt: Runtime) -> Json {
  conformance.render(
    rt.state,
    store.peek(rt.store),
    store.owner(rt.store),
    os.now_ms(),
  )
}

fn hosts_of(rt: Runtime, wanted: fold.Phase) -> List(#(Submission, String)) {
  list.filter_map(fold.leases(rt.state), fn(row) {
    let #(submission, held) = row
    case held.phase == wanted, held.runner {
      True, Some(owner) ->
        case fleet.host_of(owner) {
          Ok(one) -> Ok(#(submission, one))
          Error(_) -> Error(Nil)
        }
      _, _ -> Error(Nil)
    }
  })
}

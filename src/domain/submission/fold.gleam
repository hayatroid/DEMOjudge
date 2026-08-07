import domain/submission/event.{type Event, type Submission, type Verdict}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}

// MaxAttempts of DEMOjudge.tla: the allowance a submission opens on, and what
// a resolve adds to it.
pub const max_attempts: Int = 3

pub type Phase {
  Queued
  Compiling
  Running
  CE
  Completed
  Escalated
}

pub type Held {
  Held(attempt: Int, phase: Phase, runner: Option(String))
}

pub type State {
  State(
    seq: Int,
    reversed: List(Submission),
    attempt: Dict(Submission, Int),
    allowance: Dict(Submission, Int),
    escalated: Set(Submission),
    queued: Set(Submission),
    judgments: List(#(Submission, Int, Verdict)),
    lease: Dict(Submission, Held),
  )
}

pub fn initial() -> State {
  State(
    seq: 0,
    reversed: [],
    attempt: dict.new(),
    allowance: dict.new(),
    escalated: set.new(),
    queued: set.new(),
    judgments: [],
    lease: dict.new(),
  )
}

pub fn evolve(s: State, e: Event) -> State {
  let s = State(..s, seq: s.seq + 1)
  case e {
    event.SubmissionReceived(submission, _, _) ->
      State(
        ..s,
        reversed: [submission, ..s.reversed],
        allowance: dict.insert(s.allowance, submission, max_attempts),
        queued: set.insert(s.queued, submission),
        lease: dict.delete(s.lease, submission),
      )
    event.EscalationResolved(submission, _) ->
      State(
        ..s,
        escalated: set.delete(s.escalated, submission),
        allowance: dict.insert(
          s.allowance,
          submission,
          allowance(s, submission) + max_attempts,
        ),
        queued: set.insert(s.queued, submission),
        lease: dict.delete(s.lease, submission),
      )
    // Taking the lease spends the attempt, so a host that dies before its
    // first judging line still burns one.
    event.AttemptLeased(submission, a, runner, _) -> {
      let s = reached(s, submission, a)
      State(
        ..s,
        lease: dict.insert(
          s.lease,
          submission,
          Held(a, Compiling, Some(runner)),
        ),
      )
    }
    event.LeaseExpired(submission, _, _) ->
      State(..s, lease: dict.delete(s.lease, submission))
    event.CompilationFailed(submission, a) -> {
      let s = reached(s, submission, a)
      State(..s, lease: held(s, submission, a, CE))
    }
    event.TestCaseJudged(submission, a, _, _) -> {
      let s = reached(s, submission, a)
      State(..s, lease: held(s, submission, a, Running))
    }
    event.JudgmentCompleted(submission, a, v) -> {
      let s = reached(s, submission, a)
      State(
        ..s,
        queued: set.delete(s.queued, submission),
        judgments: [#(submission, a, v), ..s.judgments],
        lease: dict.delete(s.lease, submission),
      )
    }
    event.SubmissionEscalated(submission, a, _) -> {
      let s = reached(s, submission, a)
      State(
        ..s,
        escalated: set.insert(s.escalated, submission),
        queued: set.delete(s.queued, submission),
        lease: dict.delete(s.lease, submission),
      )
    }
  }
}

// LeaseExpired is enabled while the holder is still alive, so a judging line
// can arrive after the lease was deleted.
fn held(
  state: State,
  submission: Submission,
  a: Int,
  phase: Phase,
) -> Dict(Submission, Held) {
  let runner = case dict.get(state.lease, submission) {
    Ok(one) -> one.runner
    Error(_) -> None
  }
  dict.insert(state.lease, submission, Held(a, phase, runner))
}

pub fn leases(state: State) -> List(#(Submission, Held)) {
  received(state)
  |> list.filter_map(fn(submission) {
    case dict.get(state.lease, submission) {
      Ok(one) -> Ok(#(submission, one))
      Error(_) -> Error(Nil)
    }
  })
}

pub fn lease(state: State, submission: Submission) -> Result(Held, Nil) {
  dict.get(state.lease, submission)
}

pub fn phase(state: State, submission: Submission) -> Phase {
  case
    set.contains(state.escalated, submission),
    dict.get(state.lease, submission),
    set.contains(state.queued, submission)
  {
    True, _, _ -> Escalated
    _, Ok(one), _ -> one.phase
    _, _, True -> Queued
    _, _, _ -> Completed
  }
}

pub fn word(phase: Phase) -> String {
  case phase {
    Queued -> "queued"
    Compiling -> "compiling"
    Running -> "running"
    CE -> "ce"
    Completed -> "completed"
    Escalated -> "escalated"
  }
}

pub fn parse(word: String) -> Result(Phase, Nil) {
  case word {
    "queued" -> Ok(Queued)
    "compiling" -> Ok(Compiling)
    "running" -> Ok(Running)
    "ce" -> Ok(CE)
    "completed" -> Ok(Completed)
    "escalated" -> Ok(Escalated)
    _ -> Error(Nil)
  }
}

pub fn judgments(state: State) -> List(#(Submission, Int, Verdict)) {
  list.reverse(state.judgments)
}

fn reached(state: State, submission: Submission, a: Int) -> State {
  State(
    ..state,
    attempt: dict.insert(
      state.attempt,
      submission,
      int.max(attempt(state, submission), a),
    ),
  )
}

pub fn attempt(state: State, submission: Submission) -> Int {
  case dict.get(state.attempt, submission) {
    Ok(a) -> a
    Error(_) -> 0
  }
}

pub fn allowance(state: State, submission: Submission) -> Int {
  case dict.get(state.allowance, submission) {
    Ok(a) -> a
    Error(_) -> max_attempts
  }
}

pub fn next_attempt(state: State, submission: Submission) -> Int {
  attempt(state, submission) + 1
}

pub fn next_submission(
  state: State,
  user: String,
  problem: String,
) -> Submission {
  let taken =
    list.count(received(state), fn(submission) {
      let id = event.dimensions(submission)
      id.user == user && id.problem == problem
    })
  user <> "-" <> problem <> "-" <> int.to_string(taken + 1)
}

pub fn received(state: State) -> List(Submission) {
  list.reverse(state.reversed)
}

pub fn queued(state: State) -> List(Submission) {
  list.filter(received(state), set.contains(state.queued, _))
}

pub fn escalated(state: State, submission: Submission) -> Bool {
  set.contains(state.escalated, submission)
}

pub fn known(state: State, submission: Submission) -> Bool {
  list.contains(state.reversed, submission)
}

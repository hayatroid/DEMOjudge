import domain/submission/event.{type Event, type Submission}
import gleam/dict.{type Dict}
import gleam/list
import gleam/string

pub type Escalation {
  Escalation(submission: Submission, allowance: Int, reason: String)
}

pub type State {
  State(escalated: Dict(Submission, Escalation))
}

pub fn initial() -> State {
  State(escalated: dict.new())
}

pub fn evolve(s: State, e: Event) -> State {
  case e {
    event.SubmissionEscalated(submission, allowance, reason) ->
      State(escalated: dict.insert(
        s.escalated,
        submission,
        Escalation(submission, allowance, reason),
      ))
    event.EscalationResolved(submission, _) ->
      State(escalated: dict.delete(s.escalated, submission))
    _ -> s
  }
}

pub fn escalations(s: State) -> List(Escalation) {
  dict.keys(s.escalated)
  |> list.sort(string.compare)
  |> list.filter_map(fn(submission) { dict.get(s.escalated, submission) })
}

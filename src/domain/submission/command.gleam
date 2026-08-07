import domain/submission/event.{type Event, type Submission}
import domain/submission/fold
import gleam/list
import gleam/string

pub type Command {
  Submit(submission: Submission, lang: String, at: Int)
  Resolve(submission: Submission, reason: String)
}

pub type Rejection {
  Malformed
  AlreadyReceived
  NotEscalated
}

pub fn word(rejection: Rejection) -> String {
  case rejection {
    Malformed -> "malformed"
    AlreadyReceived -> "already-received"
    NotEscalated -> "not-escalated"
  }
}

pub fn decide(
  command: Command,
  state: fold.State,
) -> Result(List(Event), Rejection) {
  case command {
    Submit(submission, lang, at) ->
      case name_ok(submission) && name_ok(lang), fold.known(state, submission) {
        False, _ -> Error(Malformed)
        True, True -> Error(AlreadyReceived)
        True, False -> Ok([event.SubmissionReceived(submission, at, lang)])
      }
    Resolve(submission, reason) ->
      case name_ok(reason), fold.escalated(state, submission) {
        False, _ -> Error(Malformed)
        True, False -> Error(NotEscalated)
        True, True -> Ok([event.EscalationResolved(submission, reason)])
      }
  }
}

/// escalation reads the queue as well as the budget, because a re-decide after
/// a lost seq may find the submission already judged.
pub fn escalation(state: fold.State, submission: Submission) -> List(Event) {
  let allowance = fold.allowance(state, submission)
  let queued = list.contains(fold.queued(state), submission)
  case queued && fold.next_attempt(state, submission) > allowance {
    True -> [event.SubmissionEscalated(submission, allowance, "max_attempts")]
    False -> []
  }
}

pub fn name_ok(text: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), fn(c) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_",
      c,
    )
  })
}

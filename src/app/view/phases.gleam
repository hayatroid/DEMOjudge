import adapters/store.{type Lease}
import domain/submission/event.{type Submission}
import domain/submission/fold
import gleam/list

/// A lease is renewed off the log, so when a holder dies the log keeps saying
/// leased until the successor writes. The display trusts the lease item's
/// clock instead: a phase whose lease has expired is shown as queued.
pub fn phases(
  state: fold.State,
  leases: List(Lease),
  now: Int,
) -> List(#(Submission, fold.Phase)) {
  list.map(fold.received(state), fn(submission) {
    #(submission, phase(state, leases, now, submission))
  })
}

fn phase(
  state: fold.State,
  leases: List(Lease),
  now: Int,
  submission: Submission,
) -> fold.Phase {
  let seen = fold.phase(state, submission)
  case seen {
    fold.Compiling | fold.Running | fold.CE ->
      case list.find(leases, fn(one) { one.submission == submission }) {
        Ok(one) ->
          case one.until > now {
            True -> seen
            False -> fold.Queued
          }
        Error(_) -> fold.Queued
      }
    _ -> seen
  }
}

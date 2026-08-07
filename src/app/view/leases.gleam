import adapters/fleet.{type Runner}
import adapters/store.{type Lease}
import domain/submission/event.{type Submission}
import domain/submission/fold
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Holding {
  Holding(
    runner: String,
    host: String,
    state: String,
    submission: Option(Submission),
    until: Option(Int),
  )
}

pub fn holdings(
  state: fold.State,
  leases: List(Lease),
  runners: List(Runner),
) -> List(Holding) {
  let held = fold.leases(state)
  list.map(runners, fn(one) {
    let submission = case holding(held, one.host) {
      [submission, ..] -> Some(submission)
      [] -> None
    }
    Holding(
      runner: one.runner,
      host: one.host,
      state: one.state,
      submission:,
      until: case submission {
        Some(submission) -> until(leases, submission)
        None -> None
      },
    )
  })
}

fn holding(
  held: List(#(Submission, fold.Held)),
  host: String,
) -> List(Submission) {
  list.filter_map(held, fn(row) {
    let #(submission, one) = row
    case one.runner {
      Some(runner) ->
        case string.starts_with(runner, host) {
          True -> Ok(submission)
          False -> Error(Nil)
        }
      None -> Error(Nil)
    }
  })
}

// A renewal is not a fact, so the digits are read off the lease item.
fn until(leases: List(Lease), submission: Submission) -> Option(Int) {
  case list.filter(leases, fn(lease) { lease.submission == submission }) {
    [lease, ..] -> Some(lease.until / 1000)
    [] -> None
  }
}

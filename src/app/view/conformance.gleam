//// conformance renders the fold in the variables of DEMOjudge.tla; NoLease is
//// the spec's constant.

import adapters/json.{type Json, A, N, O, S}
import adapters/store.{type Lease}
import domain/submission/event.{type Submission}
import domain/submission/fold
import gleam/int
import gleam/list
import gleam/string

pub fn render(
  state: fold.State,
  leases: List(Lease),
  owner: String,
  now: Int,
) -> Json {
  let received = fold.received(state)
  let held = fold.leases(state)
  O([
    #("received", A(list.map(received, S))),
    #("queued", A(list.map(fold.queued(state), S))),
    #("leased", A(list.map(held, fn(row) { S(row.0) }))),
    #(
      "lease",
      O(
        list.map(owners(leases, owner), fn(who) {
          #(who, S(lease_of(held, leases, who, now)))
        }),
      ),
    ),
    #(
      "attempts",
      O(
        list.map(received, fn(submission) {
          #(submission, N(fold.attempt(state, submission)))
        }),
      ),
    ),
    #(
      "allowances",
      O(
        list.map(received, fn(submission) {
          #(submission, N(fold.allowance(state, submission)))
        }),
      ),
    ),
    #(
      "judgments",
      A(
        list.map(fold.judgments(state), fn(row) {
          let #(submission, attempt, verdict) = row
          O([
            #("submission", S(submission)),
            #("attempt", N(attempt)),
            #("verdict", S(event.verdict_to_string(verdict))),
          ])
        }),
      ),
    ),
    #(
      "escalated",
      A(
        list.filter(received, fn(submission) {
          fold.escalated(state, submission)
        })
        |> list.map(S),
      ),
    ),
  ])
}

fn owners(leases: List(Lease), owner: String) -> List(String) {
  [owner, ..list.map(leases, fn(lease) { lease.owner })]
  |> list.unique
  |> list.sort(string.compare)
}

fn lease_of(
  held: List(#(Submission, fold.Held)),
  leases: List(Lease),
  who: String,
  now: Int,
) -> String {
  let mine =
    list.filter(leases, fn(lease) { lease.owner == who && lease.until > now })
  let taken =
    list.filter_map(mine, fn(lease) {
      case list.find(held, fn(row) { row.0 == lease.submission }) {
        Ok(#(submission, one)) ->
          Ok(
            submission
            <> " "
            <> int.to_string(one.attempt)
            <> " "
            <> fold.word(one.phase),
          )
        Error(_) -> Error(Nil)
      }
    })
  case taken {
    [first, ..] -> first
    [] -> "NoLease"
  }
}

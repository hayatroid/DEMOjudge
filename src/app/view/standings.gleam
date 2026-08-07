import domain/submission/event.{type Event, type Submission, type Verdict}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/string

pub type Standing {
  Standing(rank: Int, user: String, solved: Int, penalty: Int)
}

pub type State {
  State(verdict: Dict(Submission, #(Int, Verdict)))
}

pub fn initial() -> State {
  State(verdict: dict.new())
}

pub fn evolve(s: State, e: Event) -> State {
  case e {
    event.JudgmentCompleted(submission, a, v) ->
      case dict.get(s.verdict, submission) {
        Ok(#(seen, _)) if seen >= a -> s
        _ -> State(verdict: dict.insert(s.verdict, submission, #(a, v)))
      }
    _ -> s
  }
}

pub fn standings(s: State) -> List(Standing) {
  let submissions = dict.keys(s.verdict)
  let users =
    list.unique(
      list.map(submissions, fn(submission) { event.dimensions(submission).user }),
    )
  users
  |> list.map(fn(user) { score(s, submissions, user) })
  |> list.sort(by_rank)
  |> list.index_map(fn(row, i) {
    let #(user, solved, penalty) = row
    Standing(rank: i + 1, user:, solved:, penalty:)
  })
}

// The penalty is a domain ruling: it counts the attempts before the AC, skips
// the ones that failed to compile, and adds no time term.
fn score(
  s: State,
  submissions: List(Submission),
  user: String,
) -> #(String, Int, Int) {
  let mine =
    list.filter(submissions, fn(submission) {
      event.dimensions(submission).user == user
    })
  let problems =
    list.unique(
      list.map(mine, fn(submission) { event.dimensions(submission).problem }),
    )
  list.fold(problems, #(user, 0, 0), fn(acc, problem) {
    let #(_, solved, penalty) = acc
    let attempts =
      list.filter(mine, fn(submission) {
        event.dimensions(submission).problem == problem
      })
      |> list.sort(by_serial)
    let #(before, rest) =
      list.split_while(attempts, fn(submission) { !accepted(s, submission) })
    let wrong = list.count(before, fn(submission) { charged(s, submission) })
    case rest {
      [] -> #(user, solved, penalty + wrong)
      _ -> #(user, solved + 1, penalty + wrong)
    }
  })
}

fn accepted(s: State, submission: Submission) -> Bool {
  case dict.get(s.verdict, submission) {
    Ok(#(_, event.AC)) -> True
    _ -> False
  }
}

fn charged(s: State, submission: Submission) -> Bool {
  case dict.get(s.verdict, submission) {
    Ok(#(_, event.CE)) -> False
    Ok(_) -> True
    Error(_) -> False
  }
}

fn by_serial(a: Submission, b: Submission) -> Order {
  int.compare(event.dimensions(a).serial, event.dimensions(b).serial)
}

fn by_rank(a: #(String, Int, Int), b: #(String, Int, Int)) -> Order {
  let #(user_a, solved_a, penalty_a) = a
  let #(user_b, solved_b, penalty_b) = b
  case int.compare(solved_b, solved_a) {
    order.Eq ->
      case int.compare(penalty_a, penalty_b) {
        order.Eq -> string.compare(user_a, user_b)
        other -> other
      }
    other -> other
  }
}

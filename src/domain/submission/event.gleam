import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A submission id, written user-problem-n.
pub type Submission =
  String

pub type Verdict {
  AC
  WA
  TLE
  MLE
  RE
  CE
}

pub type Event {
  SubmissionReceived(submission: Submission, at: Int, lang: String)
  AttemptLeased(
    submission: Submission,
    attempt: Int,
    runner: String,
    until: Int,
  )
  /// The log names a holder only while an AttemptLeased line stands unshut for
  /// it, so the lease a judging line reopens has none to name.
  LeaseExpired(submission: Submission, attempt: Int, runner: Option(String))
  CompilationFailed(submission: Submission, attempt: Int)
  TestCaseJudged(
    submission: Submission,
    attempt: Int,
    case_id: String,
    verdict: Verdict,
  )
  JudgmentCompleted(submission: Submission, attempt: Int, verdict: Verdict)
  SubmissionEscalated(submission: Submission, allowance: Int, reason: String)
  EscalationResolved(submission: Submission, reason: String)
}

/// The total order is a domain ruling: it picks the one verdict a submission
/// carries when its cases disagree.
pub fn severity(v: Verdict) -> Int {
  case v {
    AC -> 0
    WA -> 1
    TLE -> 2
    MLE -> 3
    RE -> 4
    CE -> 5
  }
}

pub fn worse(a: Verdict, b: Verdict) -> Verdict {
  case severity(a) >= severity(b) {
    True -> a
    False -> b
  }
}

pub fn verdict_to_string(v: Verdict) -> String {
  case v {
    AC -> "AC"
    WA -> "WA"
    TLE -> "TLE"
    MLE -> "MLE"
    RE -> "RE"
    CE -> "CE"
  }
}

pub fn verdict_from_string(s: String) -> Result(Verdict, Nil) {
  case s {
    "AC" -> Ok(AC)
    "WA" -> Ok(WA)
    "TLE" -> Ok(TLE)
    "MLE" -> Ok(MLE)
    "RE" -> Ok(RE)
    "CE" -> Ok(CE)
    _ -> Error(Nil)
  }
}

pub fn submission(e: Event) -> Submission {
  case e {
    SubmissionReceived(submission, _, _) -> submission
    AttemptLeased(submission, _, _, _) -> submission
    LeaseExpired(submission, _, _) -> submission
    CompilationFailed(submission, _) -> submission
    TestCaseJudged(submission, _, _, _) -> submission
    JudgmentCompleted(submission, _, _) -> submission
    SubmissionEscalated(submission, _, _) -> submission
    EscalationResolved(submission, _) -> submission
  }
}

pub fn name(e: Event) -> String {
  case e {
    SubmissionReceived(..) -> "SubmissionReceived"
    AttemptLeased(..) -> "AttemptLeased"
    LeaseExpired(..) -> "LeaseExpired"
    CompilationFailed(..) -> "CompilationFailed"
    TestCaseJudged(..) -> "TestCaseJudged"
    JudgmentCompleted(..) -> "JudgmentCompleted"
    SubmissionEscalated(..) -> "SubmissionEscalated"
    EscalationResolved(..) -> "EscalationResolved"
  }
}

/// The attempt a line carries. A fact that stands before any attempt was taken
/// carries none, and writes the zero the parser reads back.
pub fn attempt(e: Event) -> Int {
  case e {
    SubmissionReceived(..) -> 0
    AttemptLeased(_, attempt, _, _) -> attempt
    LeaseExpired(_, attempt, _) -> attempt
    CompilationFailed(_, attempt) -> attempt
    TestCaseJudged(_, attempt, _, _) -> attempt
    JudgmentCompleted(_, attempt, _) -> attempt
    SubmissionEscalated(_, allowance, _) -> allowance
    EscalationResolved(..) -> 0
  }
}

pub type Cell {
  Cell(name: String, value: String)
}

/// A fact with one thing to say fills the other cell with the dash that stands
/// for nothing.
pub fn fields(e: Event) -> #(Cell, Cell) {
  case e {
    SubmissionReceived(_, at, lang) -> #(
      Cell("at", int.to_string(at)),
      Cell("lang", lang),
    )
    AttemptLeased(_, _, runner, until) -> #(
      Cell("runner", runner),
      Cell("until", int.to_string(until)),
    )
    LeaseExpired(_, _, runner) -> #(
      Cell("runner", option.unwrap(runner, "-")),
      Cell("-", "-"),
    )
    CompilationFailed(..) -> #(Cell("reason", "compile_error"), Cell("-", "-"))
    TestCaseJudged(_, _, case_id, verdict) -> #(
      Cell("case", case_id),
      Cell("verdict", verdict_to_string(verdict)),
    )
    JudgmentCompleted(_, _, verdict) -> #(
      Cell("verdict", verdict_to_string(verdict)),
      Cell("-", "-"),
    )
    SubmissionEscalated(_, _, reason) -> #(
      Cell("reason", reason),
      Cell("-", "-"),
    )
    EscalationResolved(_, reason) -> #(Cell("reason", reason), Cell("-", "-"))
  }
}

/// The dash reads back as the nothing it was written for.
fn runner(cell: String) -> Option(String) {
  case cell {
    "-" -> None
    named -> Some(named)
  }
}

pub fn line(seq: Int, e: Event) -> String {
  let #(five, six) = fields(e)
  string.join(
    [
      int.to_string(seq),
      name(e),
      submission(e),
      int.to_string(attempt(e)),
      five.value,
      six.value,
    ],
    " ",
  )
}

/// dedup is the key that makes a line unique, and an empty key lets the same
/// fact appear again.
pub fn dedup(e: Event) -> String {
  case e {
    SubmissionReceived(submission, _, _) -> "SubmissionReceived#" <> submission
    AttemptLeased(submission, attempt, _, _) ->
      "AttemptLeased#" <> submission <> "#" <> int.to_string(attempt)
    LeaseExpired(submission, attempt, _) ->
      "LeaseExpired#" <> submission <> "#" <> int.to_string(attempt)
    CompilationFailed(submission, attempt) ->
      "CompilationFailed#" <> submission <> "#" <> int.to_string(attempt)
    TestCaseJudged(submission, attempt, case_id, _) ->
      "TestCaseJudged#"
      <> submission
      <> "#"
      <> int.to_string(attempt)
      <> "#"
      <> case_id
    JudgmentCompleted(submission, attempt, _) ->
      "JudgmentCompleted#" <> submission <> "#" <> int.to_string(attempt)
    SubmissionEscalated(submission, allowance, _) ->
      "SubmissionEscalated#" <> submission <> "#" <> int.to_string(allowance)
    EscalationResolved(_, _) -> ""
  }
}

pub fn parse(line: String) -> Result(#(Int, Event), Nil) {
  case string.split(line, " ") |> list.filter(fn(f) { f != "" }) {
    [seq, type_, submission, attempt, five, six] -> {
      let attempt = int.parse(attempt)
      let parsed = case type_, attempt {
        "SubmissionReceived", Ok(_) ->
          int.parse(five)
          |> result.map(fn(at) { SubmissionReceived(submission, at, six) })
        "AttemptLeased", Ok(a) ->
          int.parse(six)
          |> result.map(fn(until) { AttemptLeased(submission, a, five, until) })
        "LeaseExpired", Ok(a) -> Ok(LeaseExpired(submission, a, runner(five)))
        "CompilationFailed", Ok(a) -> Ok(CompilationFailed(submission, a))
        "TestCaseJudged", Ok(a) ->
          verdict_from_string(six)
          |> result.map(fn(v) { TestCaseJudged(submission, a, five, v) })
        "JudgmentCompleted", Ok(a) ->
          verdict_from_string(five)
          |> result.map(fn(v) { JudgmentCompleted(submission, a, v) })
        "SubmissionEscalated", Ok(a) ->
          Ok(SubmissionEscalated(submission, a, five))
        "EscalationResolved", Ok(_) -> Ok(EscalationResolved(submission, five))
        _, _ -> Error(Nil)
      }
      case int.parse(seq), parsed {
        Ok(seq), Ok(e) -> Ok(#(seq, e))
        _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

pub type Id {
  Id(user: String, problem: String, serial: Int)
}

pub fn dimensions(submission: Submission) -> Id {
  case list.reverse(string.split(submission, "-")) {
    [tail, problem, first, ..rest] ->
      case int.parse(tail) {
        Ok(serial) ->
          Id(string.join(list.reverse([first, ..rest]), "-"), problem, serial)
        Error(_) -> Id(submission, submission, 0)
      }
    _ -> Id(submission, submission, 0)
  }
}

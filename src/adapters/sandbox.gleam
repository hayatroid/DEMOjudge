import adapters/os
import domain/submission/event.{type Verdict}
import gleam/int
import gleam/list
import gleam/string

/// Verdicts come back one at a time, so no route here runs every case first.
pub type Outcome {
  CompileError
  Compiled(box: Box, first: String, rest: List(String))
}

const grace_secs: Int = 3

const spawn_slack_ms: Int = 5000

pub opaque type Box {
  Box(
    nsjail: String,
    gcc: String,
    time: String,
    timeout: String,
    path: String,
    work: String,
    problem: String,
  )
}

type Report {
  Report(rc: Int, rss: Int)
}

pub fn require() -> Nil {
  list.each(["nsjail", "gcc", "time", "timeout"], fn(name) { tool(name) })
}

/// No step here reads the submission's lang, so C is the only language judged.
pub fn compile(dir: String, submission: String) -> Outcome {
  let box = box(dir, submission)
  let #(first, rest) = cases_of(box.problem)
  reset(box.work)
  case copy(dir <> "/src/" <> submission, box.work <> "/submission.c") {
    True -> Nil
    False -> panic as { "sandbox: no source for " <> submission }
  }
  case built(box) {
    False -> CompileError
    True -> Compiled(box, first, rest)
  }
}

fn box(dir: String, submission: String) -> Box {
  Box(
    nsjail: tool("nsjail"),
    gcc: tool("gcc"),
    time: tool("time"),
    timeout: tool("timeout"),
    path: os.getenv("PATH", ""),
    work: absolute(dir) <> "/work/" <> submission,
    problem: problem(submission),
  )
}

fn tool(name: String) -> String {
  case which(name) {
    Ok(path) -> path
    Error(_) -> panic as { "sandbox: " <> name <> " is not on PATH" }
  }
}

fn problem(submission: String) -> String {
  let root = absolute(os.getenv("OJ_PROBLEMS", "problems"))
  let named = event.dimensions(submission).problem
  case is_dir(root <> "/" <> named) {
    True -> root <> "/" <> named
    False -> panic as { "sandbox: no problem " <> named }
  }
}

fn cases_of(problem: String) -> #(String, List(String)) {
  case case_ids(problem) {
    [] -> panic as { "sandbox: no cases under " <> problem }
    [first, ..rest] -> #(first, rest)
  }
}

fn built(box: Box) -> Bool {
  let ms = env_int("OJ_COMPILE_MS", 10_000)
  let kb = env_int("OJ_COMPILE_KB", 524_288)
  let Report(rc, rss) =
    jail(box, ms, box.gcc <> " -O2 -o prog submission.c > compile.log 2>&1")
  rc == 0 && rss <= kb && is_file(box.work <> "/prog")
}

/// rc 124 is coreutils timeout. Memory is read from time -f %M afterwards, not
/// limited.
pub fn verdict(box: Box, case_id: String) -> Verdict {
  let ms = env_int("OJ_TL_MS", 1000)
  let kb = env_int("OJ_ML_KB", 65_536)
  let input = box.problem <> "/" <> case_id <> ".in"
  let answer = box.problem <> "/" <> case_id <> ".out"
  case copy(input, box.work <> "/in") && is_file(answer) {
    True -> Nil
    False ->
      panic as { "sandbox: broken case " <> box.problem <> "/" <> case_id }
  }
  let Report(rc, rss) = jail(box, ms, "./prog < in > out 2> err")
  case rss > kb, rc {
    True, _ -> event.MLE
    False, 124 -> event.TLE
    False, 0 -> compare(box.work <> "/out", answer)
    False, _ -> event.RE
  }
}

fn compare(got: String, answer: String) -> Verdict {
  case normalise(got) == normalise(answer) {
    True -> event.AC
    False -> event.WA
  }
}

fn normalise(path: String) -> String {
  let text = case os.read_file(path) {
    Ok(body) -> body
    Error(_) -> ""
  }
  string.split(text, "\n")
  |> list.map(string.trim_end)
  |> string.join("\n")
  |> string.trim_end
}

// The jail is given the case's own seconds plus a grace, so nsjail outlives the
// timeout it wraps and 124 reaches the caller.
fn jail(box: Box, ms: Int, command: String) -> Report {
  let wall = { ms + 999 } / 1000 + grace_secs
  // time writes one rss line per exec, and the last one is the program's.
  let script =
    box.time
    <> " -f %M -o rss "
    <> box.timeout
    <> " -k 1 "
    <> seconds(ms)
    <> " "
    <> command
    <> "; rc=$?; while read line; do max=$line; done < rss;"
    <> " echo \"rc=$rc rss=$max\""
  // The jail must reach gcc, time and sh at their absolute paths on the host.
  let args = [
    "-Mo",
    "-q",
    "--chroot",
    "/",
    "--bindmount",
    box.work <> ":" <> box.work,
    "--cwd",
    box.work,
    "-t",
    int.to_string(wall),
    "--rlimit_fsize",
    "128",
    "--rlimit_nofile",
    "256",
    "-E",
    "PATH=" <> box.path,
    "--",
    "/bin/sh",
    "-c",
    script,
  ]
  case spawn(box.nsjail, args, wall * 1000 + spawn_slack_ms) {
    Ok(out) -> report(out)
    Error(_) -> panic as "sandbox: the jail outlived its own deadline"
  }
}

fn report(out: String) -> Report {
  let found =
    string.split(out, "\n")
    |> list.filter_map(fn(line) {
      case string.split(string.trim(line), " ") {
        ["rc=" <> rc, "rss=" <> rss] ->
          case int.parse(rc), int.parse(rss) {
            Ok(rc), Ok(rss) -> Ok(Report(rc, rss))
            _, _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  case found {
    [first, ..] -> first
    [] -> panic as "sandbox: the jail wrote no report"
  }
}

fn seconds(ms: Int) -> String {
  int.to_string(ms / 1000)
  <> "."
  <> string.pad_start(int.to_string(ms % 1000), 3, "0")
}

fn env_int(name: String, fallback: Int) -> Int {
  case int.parse(os.getenv(name, "")) {
    Ok(value) -> value
    Error(_) -> fallback
  }
}

@external(erlang, "oj_sandbox", "absolute")
fn absolute(path: String) -> String

@external(erlang, "oj_sandbox", "which")
fn which(name: String) -> Result(String, Nil)

@external(erlang, "oj_sandbox", "is_dir")
fn is_dir(path: String) -> Bool

@external(erlang, "oj_sandbox", "is_file")
fn is_file(path: String) -> Bool

@external(erlang, "oj_sandbox", "reset")
fn reset(path: String) -> Nil

@external(erlang, "oj_sandbox", "copy")
fn copy(from: String, to: String) -> Bool

@external(erlang, "oj_sandbox", "case_ids")
fn case_ids(path: String) -> List(String)

@external(erlang, "oj_sandbox", "jail")
fn spawn(exe: String, args: List(String), deadline: Int) -> Result(String, Nil)

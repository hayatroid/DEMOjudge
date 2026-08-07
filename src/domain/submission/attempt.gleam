//// The opaque types make an illegal order of judging events unwritable on the
//// runner's stack.

import domain/submission/event.{type Submission, type Verdict}

pub opaque type Compiling {
  Compiling(submission: Submission, attempt: Int, worst: Verdict)
}

pub opaque type Running {
  Running(submission: Submission, attempt: Int, worst: Verdict)
}

pub opaque type CE {
  CE(submission: Submission, attempt: Int, worst: Verdict)
}

pub opaque type Completed {
  Completed(submission: Submission, attempt: Int, worst: Verdict)
}

pub fn lease(submission: Submission, attempt: Int) -> Compiling {
  Compiling(submission, attempt, event.AC)
}

pub fn compiling_case(compiling: Compiling, v: Verdict) -> Running {
  Running(
    compiling.submission,
    compiling.attempt,
    event.worse(compiling.worst, v),
  )
}

pub fn compiling_compile_error(compiling: Compiling) -> CE {
  CE(
    compiling.submission,
    compiling.attempt,
    event.worse(compiling.worst, event.CE),
  )
}

pub fn running_case(running: Running, v: Verdict) -> Running {
  Running(running.submission, running.attempt, event.worse(running.worst, v))
}

pub fn running_complete(running: Running) -> Completed {
  Completed(running.submission, running.attempt, running.worst)
}

pub fn ce_complete(ce: CE) -> Completed {
  Completed(ce.submission, ce.attempt, ce.worst)
}

pub fn completed_worst(completed: Completed) -> Verdict {
  completed.worst
}

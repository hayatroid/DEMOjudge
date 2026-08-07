//// One case, one line, because a host that dies mid-run keeps the lines it has
//// already written.

import adapters/sandbox.{type Box}
import adapters/store
import app/writer.{type Config, type Lease, Lease}
import domain/submission/attempt.{type Running}
import domain/submission/event.{type Submission}
import domain/submission/fold
import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import trap

pub fn start(
  config: Config,
  name: Name(Lease),
) -> actor.StartResult(Subject(Lease)) {
  actor.new_with_initialiser(5000, fn(self) {
    process.send(writer.subject(config), writer.Ready)
    actor.initialised(config) |> actor.returning(self) |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

fn handle(config: Config, taken: Lease) -> actor.Next(Config, Lease) {
  let Lease(submission, attempt) = taken
  trap.at(fold.word(fold.Compiling))
  store.place(config.store, config.dir, submission)
  let held = attempt.lease(submission, attempt)
  let worst = case sandbox.compile(config.dir, submission) {
    sandbox.CompileError -> {
      writer.record(config, event.CompilationFailed(submission, attempt))
      trap.at(fold.word(fold.CE))
      attempt.ce_complete(attempt.compiling_compile_error(held))
      |> attempt.completed_worst
    }
    sandbox.Compiled(box, case_id, rest) -> {
      let verdict = sandbox.verdict(box, case_id)
      writer.record(
        config,
        event.TestCaseJudged(submission, attempt, case_id, verdict),
      )
      trap.at(fold.word(fold.Running))
      let running = attempt.compiling_case(held, verdict)
      let running = case verdict {
        event.AC -> cases(config, box, submission, attempt, running, rest)
        _ -> running
      }
      attempt.running_complete(running) |> attempt.completed_worst
    }
  }
  trap.at(trap.judged)
  writer.record(config, event.JudgmentCompleted(submission, attempt, worst))
  trap.at(fold.word(fold.Completed))
  process.send(writer.subject(config), writer.Ready)
  actor.continue(config)
}

fn cases(
  config: Config,
  box: Box,
  submission: Submission,
  attempt: Int,
  running: Running,
  rest: List(String),
) -> Running {
  case rest {
    [] -> running
    [case_id, ..tail] -> {
      let verdict = sandbox.verdict(box, case_id)
      writer.record(
        config,
        event.TestCaseJudged(submission, attempt, case_id, verdict),
      )
      let running = attempt.running_case(running, verdict)
      case verdict {
        event.AC -> cases(config, box, submission, attempt, running, tail)
        _ -> running
      }
    }
  }
}

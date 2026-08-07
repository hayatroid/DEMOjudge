import domain/submission/event.{type Submission}
import domain/submission/fold
import gleam/list

pub fn phases(state: fold.State) -> List(#(Submission, fold.Phase)) {
  list.map(fold.received(state), fn(submission) {
    #(submission, fold.phase(state, submission))
  })
}

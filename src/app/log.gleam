import adapters/store.{type Store, Moved, TimedOut}
import domain/submission/event.{type Event}
import gleam/erlang/process
import gleam/list

/// follow wakes on movement of the log, not on the clock. A store that cannot
/// notify answers on the wait itself, so it costs one re-read per wait.
pub fn follow(store: Store, wait_ms: Int, wake: fn() -> Nil) -> Nil {
  process.spawn(fn() {
    store.watch(store)
    ring(store, wait_ms, wake)
  })
  Nil
}

fn ring(store: Store, wait_ms: Int, wake: fn() -> Nil) -> Nil {
  case store.pause(store, wait_ms) {
    Moved -> wake()
    TimedOut -> Nil
  }
  ring(store, wait_ms, wake)
}

pub fn since(store: Store, seq: Int) -> List(#(Int, Event)) {
  list.map(store.read(store, seq), fn(line) {
    let assert Ok(one) = event.parse(line)
      as { "unreadable log line: " <> line }
    one
  })
}

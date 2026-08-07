import adapters/os
import gleam/erlang/process
import gleam/int

// The word at prints is the only handle anything outside the node has on which
// node passed which point.
pub const received: String = "received"

pub const judged: String = "judged"

pub const resolved: String = "resolved"

// delay ships in the binary and is inert without OJ_DELAY_MS.
pub fn delay() -> Nil {
  case int.parse(os.getenv("OJ_DELAY_MS", "0")) {
    Ok(ms) if ms > 0 -> process.sleep(ms)
    _ -> Nil
  }
}

pub fn at(trap: String) -> Nil {
  os.stderr("trap " <> trap <> "\n")
  delay()
}

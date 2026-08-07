import adapters/os
import gleam/list

pub type Lease {
  Lease(submission: String, owner: String, until: Int)
}

pub type Append {
  Written
  Taken
  Duplicate
  Lost
}

pub type Wake {
  Moved
  TimedOut
}

pub opaque type Store {
  Store(
    owner: String,
    read: fn(Int) -> List(String),
    // dedup and fenced are the append's conditions: a non-empty dedup rejects
    // a second copy, fenced requires holding the lease.
    write: fn(Int, String, String, String, Bool) -> Append,
    peek: fn() -> List(Lease),
    acquire: fn(String, Int) -> Bool,
    stow: fn(String, String) -> Nil,
    source: fn(String) -> Result(String, Nil),
    watch: fn() -> Nil,
    pause: fn(Int) -> Wake,
  )
}

pub fn open(owner: String) -> Store {
  let table = case os.getenv("OJ_TABLE", "") {
    "" -> panic as "OJ_TABLE is not set"
    given -> given
  }
  Store(
    owner:,
    read: fn(from) { ddb_read(table, from) },
    write: fn(seq, line, submission, dedup, fenced) {
      appended(ddb_write(table, seq, line, submission, dedup, owner, fenced))
    },
    peek: fn() { leases(ddb_peek(table)) },
    acquire: fn(submission, until) {
      ddb_acquire(table, submission, owner, until)
    },
    stow: fn(submission, text) { ddb_stow(table, submission, text) },
    source: fn(submission) { ddb_source(table, submission) },
    watch: fn() { stream_subscribe(table) },
    pause: fn(ms) { stream_pause(table, ms) },
  )
}

fn leases(raw: List(#(String, String, Int))) -> List(Lease) {
  list.map(raw, fn(row) { Lease(row.0, row.1, row.2) })
}

fn appended(answer: String) -> Append {
  case answer {
    "written" -> Written
    "taken" -> Taken
    "duplicate" -> Duplicate
    "lost" -> Lost
    other -> panic as { "store refused the append: " <> other }
  }
}

pub fn owner(store: Store) -> String {
  store.owner
}

pub fn read(store: Store, from: Int) -> List(String) {
  let f = store.read
  f(from)
}

pub fn write(
  store: Store,
  seq: Int,
  line: String,
  submission: String,
  dedup: String,
  fenced: Bool,
) -> Append {
  let f = store.write
  f(seq, line, submission, dedup, fenced)
}

pub fn watch(store: Store) -> Nil {
  let f = store.watch
  f()
}

pub fn pause(store: Store, ms: Int) -> Wake {
  let f = store.pause
  f(ms)
}

pub fn peek(store: Store) -> List(Lease) {
  let f = store.peek
  f()
}

pub fn acquire(store: Store, submission: String, until: Int) -> Bool {
  let f = store.acquire
  f(submission, until)
}

pub fn stow(store: Store, submission: String, text: String) -> Nil {
  let f = store.stow
  f(submission, text)
}

pub fn source(store: Store, submission: String) -> Result(String, Nil) {
  let f = store.source
  f(submission)
}

pub fn place(store: Store, dir: String, submission: String) -> Nil {
  let path = dir <> "/src/" <> submission
  case os.read_file(path) {
    Ok(_) -> Nil
    Error(_) ->
      case source(store, submission) {
        Ok(text) -> os.write_file(path, text)
        Error(_) -> Nil
      }
  }
}

@external(erlang, "oj_ddb", "read")
fn ddb_read(table: String, from: Int) -> List(String)

@external(erlang, "oj_ddb", "write")
fn ddb_write(
  table: String,
  seq: Int,
  line: String,
  submission: String,
  dedup: String,
  owner: String,
  fenced: Bool,
) -> String

@external(erlang, "oj_ddb", "peek")
fn ddb_peek(table: String) -> List(#(String, String, Int))

@external(erlang, "oj_ddb", "acquire")
fn ddb_acquire(
  table: String,
  submission: String,
  owner: String,
  until: Int,
) -> Bool

@external(erlang, "oj_ddb", "stow")
fn ddb_stow(table: String, submission: String, text: String) -> Nil

@external(erlang, "oj_ddb", "source")
fn ddb_source(table: String, submission: String) -> Result(String, Nil)

@external(erlang, "oj_stream", "subscribe")
fn stream_subscribe(table: String) -> Nil

@external(erlang, "oj_stream", "pause")
fn stream_pause(table: String, ms: Int) -> Wake

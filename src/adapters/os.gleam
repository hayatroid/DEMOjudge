@external(erlang, "oj_ffi", "read_file")
pub fn read_file(path: String) -> Result(String, Nil)

@external(erlang, "oj_ffi", "write_file")
pub fn write_file(path: String, content: String) -> Nil

@external(erlang, "oj_ffi", "mkdir")
pub fn mkdir(path: String) -> Nil

@external(erlang, "oj_ffi", "getenv")
pub fn getenv(name: String, default: String) -> String

@external(erlang, "oj_ffi", "now_ms")
pub fn now_ms() -> Int

@external(erlang, "oj_ffi", "stderr")
pub fn stderr(text: String) -> Nil

@external(erlang, "oj_ffi", "os_pid")
pub fn os_pid() -> String

@external(erlang, "oj_ffi", "argv")
pub fn argv() -> List(String)

@external(erlang, "oj_ffi", "tune")
pub fn tune() -> Nil

@external(erlang, "oj_ffi", "die")
pub fn die(status: Int) -> Nil

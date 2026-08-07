//// No caller reads JSON back, so this renders and does not parse.

import gleam/int
import gleam/list
import gleam/string

pub type Json {
  S(String)
  N(Int)
  Null
  A(List(Json))
  O(List(#(String, Json)))
}

pub fn render(value: Json) -> String {
  case value {
    S(text) -> quote(text)
    N(number) -> int.to_string(number)
    Null -> "null"
    A(items) -> "[" <> string.join(list.map(items, render), ",") <> "]"
    O(fields) ->
      "{"
      <> string.join(
        list.map(fields, fn(field) { quote(field.0) <> ":" <> render(field.1) }),
        ",",
      )
      <> "}"
  }
}

fn quote(text: String) -> String {
  "\"" <> string.concat(list.map(string.to_graphemes(text), escape)) <> "\""
}

fn escape(c: String) -> String {
  case c {
    "\"" -> "\\\""
    "\\" -> "\\\\"
    "\n" -> "\\n"
    "\r" -> "\\r"
    "\t" -> "\\t"
    other ->
      case string.to_utf_codepoints(other) {
        [point] ->
          case string.utf_codepoint_to_int(point) < 0x20 {
            True -> "\\u00" <> pad(string.utf_codepoint_to_int(point))
            False -> other
          }
        _ -> other
      }
  }
}

fn pad(code: Int) -> String {
  let digits = "0123456789abcdef"
  let high = code / 16
  let low = code % 16
  slice(digits, high) <> slice(digits, low)
}

fn slice(text: String, at: Int) -> String {
  string.slice(text, at, 1)
}

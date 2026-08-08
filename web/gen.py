#!/usr/bin/env python3
"""Rebuild the page's data-from panels from what they name; --check verifies.

    pre: path#name,name() definitions   tbody: path#names mapping rows   template: path whole
"""
import argparse
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "web/index.html"
PANEL = re.compile(
    r'(<(pre|template|tbody)\b[^>]*data-from="([^"]+)"[^>]*>).*?(</\2>)',
    re.DOTALL)

BLANK = r"\s*$"
CLOSE = r"\}$"


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def esc(text: str) -> str:
    return html.escape(text, quote=False)


def head_at(lines: list[str], head: str, what: str) -> int:
    for at, line in enumerate(lines):
        if re.match(head, line):
            return at
    raise SystemExit("no %s" % what)


def block(lines: list[str], head: str, what: str, end: str,
          keep: int = 0) -> list[str]:
    at = head_at(lines, head, what)
    for i in range(at + 1, len(lines)):
        if re.match(end, lines[i]):
            return lines[at:i + keep]
    return lines[at:]


def definition(path: str, lines: list[str], name: str) -> list[str]:
    if path.endswith(".tla"):
        return block(lines, r"^%s\s*(\(|==)" % re.escape(name),
                     "action %r" % name, BLANK)
    head = r"^(pub )?(opaque )?(fn %s\(|type %s \{)" % (re.escape(name),
                                                        re.escape(name))
    return block(lines, head, "definition %r" % name, CLOSE, 1)


def conformance_row(lines: list[str], name: str) -> str:
    fold = block(lines, r"^%s\(L\)\s*==" % re.escape(name.capitalize()),
                 "mapping %r" % name, BLANK)
    return re.sub(r"\s+", " ", " ".join(fold)).strip()


def body(spec: str) -> str:
    path, names = spec.split("#")
    lines = read(path).splitlines()
    out = []
    height = 0
    for name in names.split(","):
        part = definition(path, lines, name.removesuffix("()"))
        if name.endswith("()"):
            part = [part[0].removesuffix(" {")]
        if out and (height > 1 or len(part) > 1):
            out.append("")
        out += part
        height = len(part)
    return esc("\n".join(out))


def rows(spec: str) -> str:
    path, names = spec.split("#")
    lines = read(path).splitlines()
    out = ["<tr><td>%s<td>%s<td></tr>" % (name, esc(conformance_row(lines, name)))
           for name in names.split(",")]
    return "\n" + "\n".join(out) + "\n"


def whole(spec: str) -> str:
    return esc(read(spec))


FILL = {"pre": body, "template": whole, "tbody": rows}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    asked = parser.parse_args()
    page = PAGE.read_text(encoding="utf-8")
    fresh, panels = PANEL.subn(lambda m: m[1] + FILL[m[2]](m[3]) + m[4], page)
    if panels != page.count("data-from="):
        raise SystemExit("only %d of %d panels matched"
                         % (panels, page.count("data-from=")))
    if asked.check:
        if page != fresh:
            raise SystemExit("index.html does not match its sources: run gen.py")
        return
    if page != fresh:
        PAGE.write_text(fresh, encoding="utf-8")
    print("%d panels" % panels, file=sys.stderr)


if __name__ == "__main__":
    main()

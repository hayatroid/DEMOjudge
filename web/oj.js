"use strict";

const KEEP = 40;
const FADE_MS = 1400;
const GONE_MS = 500;
const HIT_MS = 1000;
const TICK_MS = 250;

/* a and b are the same problem at two sizes and take the same program. */
const SOURCES = { a: "source-a-ac", b: "source-a-ac", c: "source-c-ac" };

const PAGES = ["entry", "phases", "events", "views"];

const need = (selector, root = document) => {
  const found = root.querySelector(selector);
  if (!found) {
    throw new Error("no " + selector);
  }
  return found;
};

const program = (problem) => need("#" + SOURCES[problem]).content.textContent;

const seconds = () => Math.floor(Date.now() / 1000);

let model = {
  phases: {},
  leases: {},
  traps: [],
  standings: [],
  escalations: [],
  events: [],
  attempts: {},
  dead: {},
  word: null,
  conformance: {},
  mapping: false,
  authorize: false,
  page: "entry",
  problem: "a",
  source: program("a"),
  refused: "",
  now: seconds(),
};

const runnerOf = (leases, submission) => {
  for (const [runner, one] of Object.entries(leases)) {
    if (one.submission === submission) {
      return runner;
    }
  }
  return "";
};

const struck = (m) => {
  const dead = {};
  let word = m.word;
  for (const submission of Object.keys(m.phases)) {
    const runner = runnerOf(m.leases, submission);
    const one = runner ? m.leases[runner] : null;
    dead[submission] = one !== null && one.state !== "running";
    if (dead[submission] && !m.dead[submission]) {
      word = { submission: submission, text: "Crash", fade: false, gone: false };
    }
    if (!dead[submission] && m.dead[submission] && word
        && !word.fade && word.submission === submission) {
      word = null;
    }
  }
  return { ...m, dead: dead, word: word };
};

const told = (m, one) => ({
  ...m,
  attempts: one.attempt
    ? { ...m.attempts, [one.submission]: one.attempt }
    : m.attempts,
  events: [one, ...m.events.filter((seen) => seen.seq !== one.seq)]
    .sort((a, b) => b.seq - a.seq)
    .slice(0, KEEP),
  word: one.event === "LeaseExpired"
    ? { submission: one.submission, text: one.event, fade: true, gone: false }
    : m.word,
});

const EVOLVE = {
  events: (m, seen) => told(m, seen),
  phases: (m, seen) => struck({ ...m, phases: seen }),
  leases: (m, seen) => struck({ ...m, leases: seen }),
  traps: (m, seen) => ({ ...m, traps: seen }),
  standings: (m, seen) => ({ ...m, standings: seen.rows }),
  escalations: (m, seen) => ({ ...m, escalations: seen }),
};

const same = (a, b) =>
  a !== null && b !== null && a.submission === b.submission && a.text === b.text;

const update = (m, msg) => {
  switch (msg.kind) {
    case "frame":
      return EVOLVE[msg.name](m, msg.seen);
    case "conformance":
      return { ...m, conformance: msg.seen };
    case "mapping":
      return { ...m, mapping: msg.open };
    case "authorize":
      return { ...m, authorize: msg.open };
    case "page":
      return { ...m, page: msg.page };
    case "problem":
      return { ...m, problem: msg.problem, source: msg.source };
    case "source":
      return { ...m, source: msg.source };
    case "refused":
      return { ...m, refused: msg.by };
    case "forgive":
      return m.refused === msg.by ? { ...m, refused: "" } : m;
    case "fade":
      return same(m.word, msg.word)
        ? { ...m, word: { ...m.word, gone: true } }
        : m;
    case "forget":
      return same(m.word, msg.word) ? { ...m, word: null } : m;
    case "tick":
      return { ...m, now: msg.now };
    case "shut":
      return { ...m, mapping: false, authorize: false };
  }
};

const kept = new WeakMap();

const cache = (parent) => {
  const found = kept.get(parent);
  if (found) {
    return found;
  }
  const fresh = new Map();
  kept.set(parent, fresh);
  return fresh;
};

const arrange = (parent, items, named, make, draw) => {
  const held = cache(parent);
  const keys = items.map(named);
  const wanted = new Set(keys);
  for (const [key, one] of [...held]) {
    if (!wanted.has(key)) {
      one.remove();
      held.delete(key);
    }
  }
  items.forEach((one, at) => {
    const key = keys[at];
    const found = held.get(key);
    const el = found ?? make();
    held.set(key, el);
    draw(el, one);
    if (parent.children[at] !== el) {
      parent.insertBefore(el, parent.children[at] ?? null);
    }
  });
};

const cells = (row, values) => {
  while (row.children.length > values.length) {
    row.lastElementChild.remove();
  }
  while (row.children.length < values.length) {
    row.append(document.createElement("td"));
  }
  values.forEach((one, at) => {
    row.children[at].textContent = String(one);
  });
};

/* The server hands the phases over in the order it received the submissions, so
   where one stands in that order is where it came in. */
const band = (m) => {
  const columns = new Map();
  Object.keys(m.phases).forEach((submission, place) => {
    const column = columns.get(m.phases[submission]) ?? [];
    column.unshift({ submission: submission, place: place });
    columns.set(m.phases[submission], column);
  });
  return columns;
};

const madeSubmission = () => {
  const li = document.createElement("li");
  li.className = "submission";
  const name = document.createElement("span");
  name.className = "name";
  const meta = document.createElement("small");
  const clock = document.createElement("span");
  clock.className = "clock";
  clock.hidden = true;
  li.append(name, meta, clock);
  return li;
};

const drawSubmission = (m, li, one) => {
  const runner = runnerOf(m.leases, one.submission);
  const attempt = m.attempts[one.submission] ?? 0;
  const dead = Boolean(m.dead[one.submission]);
  const until = dead && runner ? m.leases[runner].leased_until : 0;
  li.dataset.seq = String(one.place);
  need(".name", li).textContent = one.submission;
  need("small", li).textContent =
    (runner ? runner + " " : "") + (attempt ? "attempt " + attempt : "");
  li.classList.toggle("dead", dead);
  const clock = need(".clock", li);
  clock.hidden = !until;
  /* The countdown takes the browser's clock and the server's epoch seconds to be
     the same clock. */
  clock.textContent = until ? String(Math.max(until - m.now, 0)) : "";
};

const drawBand = (m) => {
  const columns = band(m);
  for (const tile of document.querySelectorAll(".phase")) {
    const phase = tile.id.slice("p-".length);
    arrange(
      need(".submissions", tile),
      columns.get(phase) ?? [],
      (one) => one.submission,
      madeSubmission,
      (li, one) => drawSubmission(m, li, one),
    );
  }
};

const drawTraps = (m) => {
  for (const mark of document.querySelectorAll(".trap")) {
    const phase = mark.value;
    const set = m.traps.some((one) => one.trap === phase);
    /* The server forgets a reservation as it fires it, so the firing is read back
       off the piece left dead in that phase. */
    const fired = Object.keys(m.phases).some(
      (one) => m.phases[one] === phase && m.dead[one],
    );
    mark.classList.toggle("set", set && !fired);
    mark.classList.toggle("fired", fired);
    mark.classList.toggle("hit", m.refused === "trap:" + phase);
    need("#p-" + phase).classList.toggle("trapped", set && !fired);
  }
};

const drawWord = (m) => {
  const said = m.word;
  const home = said
    ? document.getElementById("p-" + m.phases[said.submission])
    : null;
  for (const one of document.querySelectorAll(".word")) {
    if (one.parentElement !== home) {
      one.remove();
    }
  }
  if (!said || !home) {
    return;
  }
  const found = home.querySelector(".word");
  const p = found ?? document.createElement("p");
  p.className = "word";
  if (!found) {
    home.append(p);
  }
  p.textContent = said.text;
  p.classList.toggle("gone", said.gone);
};

const drawTape = (m) => {
  arrange(
    need("#tape tbody"),
    m.events,
    (one) => String(one.seq),
    () => document.createElement("tr"),
    (tr, one) => cells(tr, Object.values(one)),
  );
};

const drawLeases = (m) => {
  arrange(
    need("#leases tbody"),
    Object.entries(m.leases),
    ([runner]) => runner,
    () => document.createElement("tr"),
    (tr, [runner, one]) => {
      tr.classList.toggle("dead", one.state !== "running");
      cells(tr, [runner, one.host, one.state]);
    },
  );
};

const drawStandings = (m) => {
  arrange(
    need("#standings tbody"),
    m.standings,
    (one) => one.user,
    () => document.createElement("tr"),
    (tr, one) => cells(tr, [one.rank, one.user, one.solved, one.penalty]),
  );
};

const madeEscalation = () => {
  const tr = document.createElement("tr");
  const form = document.createElement("form");
  form.method = "post";
  form.action = "/api/resolve";
  const named = document.createElement("input");
  named.type = "hidden";
  named.name = "submission";
  const button = document.createElement("button");
  button.textContent = "resolve";
  form.append(named, button);
  const last = document.createElement("td");
  last.append(form);
  tr.append(
    document.createElement("td"),
    document.createElement("td"),
    document.createElement("td"),
    last,
  );
  return tr;
};

const drawEscalations = (m) => {
  arrange(
    need("#escalations tbody"),
    m.escalations,
    (one) => one.submission,
    madeEscalation,
    (tr, one) => {
      [one.submission, one.allowance, one.reason].forEach((field, at) => {
        tr.children[at].textContent = String(field);
      });
      need("input", tr).value = one.submission;
      need("form", tr).classList.toggle(
        "hit",
        m.refused === "resolve:" + one.submission,
      );
    },
  );
};

const words = (value) =>
  Array.isArray(value) && value.every((one) => typeof one === "string");

const shape = (value) => {
  if (words(value)) {
    return "{" + value.join(", ") + "}";
  }
  if (Array.isArray(value)) {
    return value.map((one) => Object.values(one).join(" ")).join("\n");
  }
  return Object.entries(value)
    .map(([point, one]) => point + " -> " + one)
    .join("\n");
};

const drawMapping = (m) => {
  need("#conformance").open = m.mapping;
  for (const tr of document.querySelectorAll("#mapping tbody tr")) {
    const value = m.conformance[tr.firstElementChild.textContent];
    tr.lastElementChild.textContent = value ? shape(value) : "";
  }
};

const drawEntry = (m) => {
  const problem = need("#problem");
  const source = need("#source");
  if (problem.value !== m.problem) {
    problem.value = m.problem;
  }
  if (source.value !== m.source) {
    source.value = m.source;
  }
  need("#entry").classList.toggle("hit", m.refused === "entry");
};

const drawPage = (m) => {
  for (const name of PAGES) {
    need("#page-" + name).checked = name === m.page;
  }
  need("#authorize").open = m.authorize;
};

const view = (m) => {
  drawPage(m);
  drawBand(m);
  drawTraps(m);
  drawWord(m);
  drawTape(m);
  drawLeases(m);
  drawStandings(m);
  drawEscalations(m);
  drawMapping(m);
  drawEntry(m);
};

let drawing = 0;

const draw = () => {
  if (drawing) {
    return;
  }
  drawing = requestAnimationFrame(() => {
    drawing = 0;
    view(model);
  });
};

let clock = 0;

const counting = (m) => Object.values(m.dead).some(Boolean);

const tick = () => dispatch({ kind: "tick", now: seconds() });

const timer = (m) => {
  if (counting(m) === Boolean(clock)) {
    return;
  }
  if (clock) {
    clearInterval(clock);
    clock = 0;
    return;
  }
  clock = setInterval(tick, TICK_MS);
  tick();
};

const fading = (before, m) => {
  const said = m.word;
  if (!said || !said.fade || same(before.word, said)) {
    return;
  }
  setTimeout(() => dispatch({ kind: "fade", word: said }), FADE_MS);
  setTimeout(() => dispatch({ kind: "forget", word: said }), FADE_MS + GONE_MS);
};

/* Asking is held to a frame the way drawing is, so a round asks once and a tab
   in the background, which is given no frame, asks not at all. */
let asking = 0;

const read = () => {
  if (asking) {
    return;
  }
  asking = requestAnimationFrame(() => {
    asking = 0;
    fetch("/api/conformance")
      .then((answer) => answer.json())
      .then((seen) => dispatch({ kind: "conformance", seen: seen }))
      .catch(() => dispatch({ kind: "conformance", seen: {} }));
  });
};

const effects = (before, m, msg) => {
  timer(m);
  fading(before, m);
  if (m.mapping && (msg.kind === "frame" || msg.kind === "mapping")) {
    read();
  }
  if (msg.kind === "shut") {
    for (const one of document.querySelectorAll("details[open]")) {
      one.open = false;
    }
  }
};

const dispatch = (msg) => {
  const before = model;
  model = update(before, msg);
  effects(before, model, msg);
  draw();
};

const src = new EventSource("/api/events");

for (const name of Object.keys(EVOLVE)) {
  src.addEventListener(name, (e) => {
    dispatch({ kind: "frame", name: name, seen: JSON.parse(e.data) });
  });
}

/* The server reads a body only where it is form-urlencoded, so the fields go out
   as a query string whatever they were gathered in. */
const post = (url, fields, mark) =>
  fetch(url, { method: "POST", body: new URLSearchParams(fields) })
    .then((answer) => {
      if (answer.status === 403) {
        dispatch({ kind: "authorize", open: true });
        return false;
      }
      if (!answer.ok) {
        refuse(mark);
      }
      return answer.ok;
    })
    .catch(() => {
      refuse(mark);
      return false;
    });

const refuse = (mark) => {
  dispatch({ kind: "refused", by: mark });
  setTimeout(() => dispatch({ kind: "forgive", by: mark }), HIT_MS);
};

const marked = (form) => {
  const named = form.querySelector("input[name=submission]");
  return named ? "resolve:" + named.value : "entry";
};

const details = need("#conformance");
details.addEventListener("toggle", () =>
  dispatch({ kind: "mapping", open: details.open }),
);

const gate = need("#authorize");
gate.addEventListener("toggle", () =>
  dispatch({ kind: "authorize", open: gate.open }),
);

document.addEventListener("change", (e) => {
  const one = e.target;
  if (one instanceof HTMLInputElement && one.name === "page" && one.checked) {
    dispatch({ kind: "page", page: one.id.slice("page-".length) });
  }
  if (one instanceof HTMLSelectElement && one.id === "problem") {
    dispatch({
      kind: "problem",
      problem: one.value,
      source: program(one.value),
    });
  }
});

document.addEventListener("input", (e) => {
  const one = e.target;
  if (one instanceof HTMLTextAreaElement && one.id === "source") {
    dispatch({ kind: "source", source: one.value });
  }
});

document.addEventListener("submit", (e) => {
  const form = e.target;
  if (!form.action.includes("/api/")) {
    return;
  }
  e.preventDefault();
  post(form.action, new FormData(form, e.submitter), marked(form)).then((ok) => {
    if (ok) {
      dispatch({ kind: "page", page: "phases" });
    }
  });
});

document.addEventListener("click", (e) => {
  const mark = e.target.closest(".trap");
  if (mark) {
    post(
      "/api/trap",
      new URLSearchParams({ trap: mark.value }),
      "trap:" + mark.value,
    );
  }
  if (!e.target.closest("details")) {
    dispatch({ kind: "shut" });
  }
});

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    dispatch({ kind: "shut" });
  }
});

draw();

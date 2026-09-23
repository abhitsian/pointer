#!/usr/bin/env node
// Pointer MCP server: search and read what Pointer captured (what was said, what was on screen, and the
// write-ups) from ~/Pictures/Pointer, and Cuecard's meeting notes from ~/Documents/Cuecard.
// Zero-dependency newline-delimited JSON-RPC 2.0 over stdio.

const fs = require("fs");
const path = require("path");
const os = require("os");

const ROOT = process.env.SHOWTELL_ROOT || path.join(os.homedir(), "Pictures", "Pointer");
const CUECARD = process.env.CUECARD_ROOT || path.join(os.homedir(), "Documents", "Cuecard");
const STAMP = /^(\d{4}-\d\d-\d\d)_(\d\d)-(\d\d)-(\d\d)(?:-(\w+))?$/;

const read = (file) => { try { return fs.readFileSync(file, "utf8"); } catch { return null; } };
const json = (file) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };
const clock = (t) => { t = Math.max(0, Math.floor(t || 0)); return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`; };
const seconds = (mmss) => mmss.split(":").reduce((a, b) => a * 60 + Number(b), 0);

// Every capture: a folder (watch, video, document) or a loose screenshot (<stamp>.png + <stamp>.json).
function captures() {
  let names = [];
  try { names = fs.readdirSync(ROOT); } catch { return []; }
  const out = [];
  for (const name of names) {
    const full = path.join(ROOT, name);
    let dir = false;
    try { dir = fs.statSync(full).isDirectory(); } catch { continue; }
    if (dir && STAMP.test(name)) {
      const page = json(path.join(full, "session.json"));
      if (!page || page.processing) continue;
      out.push({ id: name, dir: full, page });
    } else if (name.endsWith(".json") && STAMP.test(name.slice(0, -5))) {
      const page = json(full);
      if (page) out.push({ id: name.slice(0, -5), dir: null, page });
    }
  }
  return out.concat(meetings()).sort((a, b) => new Date(b.page.created) - new Date(a.page.created));
}

// Cuecard notes: "YYYY-MM-DD HHMM Title.md" with a # title, a "date · m:ss · mode" line, sections, and a
// "## Transcript" of "[m:ss] You|Them: text" lines.
function meetings() {
  let names = [];
  try { names = fs.readdirSync(CUECARD).filter((n) => n.endsWith(".md")); } catch { return []; }
  const out = [];
  for (const name of names) {
    const m = name.match(/^(\d{4}-\d\d-\d\d) (\d\d)(\d\d) /);
    const text = read(path.join(CUECARD, name));
    if (!m || !text) continue;
    const title = (text.match(/^# (.+)$/m) || [])[1] || name.slice(16, -3);
    const length = (text.match(/^.+ · (\d+(?::\d\d)+) · /m) || [])[1];
    const cut = text.indexOf("\n## Transcript");
    const notes = cut >= 0 ? text.slice(0, cut) : text;
    const live = notes.indexOf("\n## Captured live");
    const transcript = cut >= 0 ? text.slice(cut).split("\n").filter((l) => /^\[\d/.test(l)).map((l) => l.trimEnd()) : [];
    out.push({
      id: "meeting:" + name.slice(0, -3), dir: null, file: path.join(CUECARD, name), transcript,
      digest: (live >= 0 ? notes.slice(0, live) : notes).trim(),
      page: { kind: "meeting", title, created: new Date(`${m[1]}T${m[2]}:${m[3]}:00`).toISOString(), seconds: length ? seconds(length) : undefined },
    });
  }
  return out;
}

function summary(c) {
  const p = c.page;
  return {
    id: c.id,
    kind: p.kind || "screenshot",
    created: p.created,
    minutes: p.seconds ? Math.round(p.seconds / 60) : undefined,
    title: p.title || (p.narration || "").slice(0, 80) || "Untitled capture",
    page: c.file || (c.dir ? path.join(c.dir, "index.html") : path.join(ROOT, `${c.id}.html`)),
  };
}

// What was said, as timed lines.
function said(c) {
  const text = c.transcript ? c.transcript.join("\n") : c.dir && read(path.join(c.dir, "transcript.txt"));
  if (text) {
    return text.split("\n").filter(Boolean).map((line) => {
      const m = line.match(/^\[(\d+(?::\d\d)+)\]\s*(.*)$/);
      return m ? { time: seconds(m[1]), text: m[2] } : { time: 0, text: line };
    });
  }
  const cues = c.page.cues || [];
  if (cues.length) return cues.map((q) => ({ time: q.start, text: `${q.speaker ? q.speaker + ": " : ""}${q.text}` }));
  return c.page.narration ? [{ time: 0, text: c.page.narration }] : [];
}

// What was on screen, as sections per key frame.
function screen(c) {
  if (c.page.kind === "meeting") return [];
  const text = c.dir ? read(path.join(c.dir, "screen.txt")) : read(path.join(ROOT, `${c.id}.screen.txt`));
  if (text) {
    return text.split(/\n(?=## \[)/).map((block) => {
      const [head, ...lines] = block.trim().split("\n");
      const m = head.match(/^## \[(\d+(?::\d\d)+)\]\s*(\S+)(?: · (.*))?$/);
      return { time: m ? seconds(m[1]) : 0, frame: m && m[2], context: m && m[3], lines };
    });
  }
  if (c.page.documentLines) return [{ time: 0, frame: null, context: c.page.documentSource, lines: c.page.documentLines }];
  return (c.page.frames || []).map((f) => ({ time: f.time, frame: f.file, context: f.context, lines: f.appeared || [] }));
}

function digest(c) {
  return c.digest || (c.dir && read(path.join(c.dir, "digest.md"))) || c.page.digest || c.page.summary || "";
}

function since(list, a) {
  let from = a.since ? new Date(a.since) : null;
  if (a.days) from = new Date(Date.now() - a.days * 86400000);
  let out = from && !isNaN(from) ? list.filter((c) => new Date(c.page.created) >= from) : list;
  if (a.kind) out = out.filter((c) => (c.page.kind || "screenshot") === a.kind);
  return out;
}

function search(a) {
  const terms = String(a.query || "").toLowerCase().split(/\s+/).filter((t) => t.length > 1);
  if (!terms.length) throw new Error("query is empty");
  const where = a.in || "all";
  const score = (text) => { const t = text.toLowerCase(); return terms.reduce((n, term) => n + (t.includes(term) ? 1 : 0), 0); };
  const hits = [];
  for (const c of since(captures(), a)) {
    const s = summary(c);
    const add = (source, time, text, extra) => {
      const n = score(text);
      if (n) hits.push({ n, id: c.id, title: s.title, created: s.created, source, at: clock(time), text: text.slice(0, 300), ...extra });
    };
    add("title", 0, s.title);
    if (where === "all" || where === "digest") digest(c).split("\n").filter(Boolean).forEach((l) => add("write-up", 0, l));
    if (where === "all" || where === "said") said(c).forEach((l) => add("said", l.time, l.text));
    if (where === "all" || where === "screen") {
      for (const sec of screen(c)) {
        sec.lines.forEach((l) => add("screen", sec.time, l, { frame: sec.frame || undefined, app: sec.context || undefined }));
        if (sec.context) add("screen", sec.time, sec.context, { frame: sec.frame || undefined, app: sec.context });
      }
    }
  }
  hits.sort((x, y) => y.n - x.n || y.created.localeCompare(x.created));
  const limit = a.limit || 40;
  const seen = new Set();
  const lines = [];
  for (const h of hits) {
    const key = `${h.id}|${h.source}|${h.text}`;
    if (seen.has(key)) continue;
    seen.add(key);
    lines.push(`${h.id} [${h.at}] ${h.source}${h.app ? ` (${h.app})` : ""}: ${h.text}`);
    if (lines.length >= limit) break;
  }
  if (!lines.length) return `No matches for "${a.query}".`;
  return `${lines.length} shown of ${hits.length} matching lines (best first). Use pointer_get with an id for the full material.\n\n${lines.join("\n")}`;
}

function get(a) {
  const c = captures().find((x) => x.id === a.id) || (a.id === "latest" && captures()[0]);
  if (!c) throw new Error(`no capture "${a.id}"; use pointer_list`);
  const parts = a.parts && a.parts.length ? a.parts : ["digest", "timeline"];
  const s = summary(c);
  const out = [`# ${s.title}`, `${s.kind} · ${s.created}${s.minutes != null ? ` · ${s.minutes} min` : ""} · page: ${s.page}`];
  if (parts.includes("digest")) { const d = digest(c); if (d) out.push("\n## Write-up\n" + d.trim()); }
  if (parts.includes("timeline")) {
    // What was said and what was on screen, merged in time order, so the moment can be reconstructed.
    const events = said(c).map((l) => ({ time: l.time, order: 1, text: `[${clock(l.time)}] SAID  ${l.text}` }))
      .concat(screen(c).map((x) => ({ time: x.time, order: 0, text: `[${clock(x.time)}] SCREEN${x.frame ? " " + x.frame : ""}${x.context ? " · " + x.context : ""}\n${x.lines.map((l) => "    " + l).join("\n")}` })))
      .sort((p, q) => p.time - q.time || p.order - q.order);
    if (events.length) {
      out.push("\n## Timeline: what was said and what was on screen, in order (speech is on-device recognition, screen text is OCR; both can misread names)\n"
        + events.map((e) => e.text).join("\n"));
      if (c.dir) out.push(`\nFrame images: ${c.dir}/frame-N.png (read one when the answer turns on something visual).`);
      else if (c.page.kind === "screenshot") out.push(`\nImage: ${path.join(ROOT, c.id + ".png")}`);
    }
  }
  if (parts.includes("said")) {
    const l = said(c);
    if (l.length) out.push("\n## What was said (on-device speech recognition; names may be misheard)\n" + l.map((x) => `[${clock(x.time)}] ${x.text}`).join("\n"));
  }
  if (parts.includes("screen")) {
    const secs = screen(c);
    if (secs.length) out.push("\n## What was on screen (OCR of key frames)\n" + secs.map((x) =>
      `### [${clock(x.time)}]${x.frame ? " " + x.frame : ""}${x.context ? " · " + x.context : ""}\n${x.lines.join("\n")}`).join("\n\n"));
    if (c.dir) out.push(`\nFrame images are in ${c.dir}/ (read a frame-N.png when the answer turns on something visual).`);
  }
  let text = out.join("\n");
  const max = a.max_chars || 60000;
  if (text.length > max) text = text.slice(0, max) + `\n\n[truncated at ${max} chars; ask for fewer parts or a larger max_chars]`;
  return text;
}

function list(a) {
  const rows = since(captures(), a).slice(0, a.limit || 30).map(summary);
  if (!rows.length) return "No captures.";
  return rows.map((r) => `${r.id}\t${r.kind}\t${r.minutes != null ? r.minutes + " min" : "-"}\t${r.title}`).join("\n");
}

const FILTERS = {
  days: { type: "number", description: "Only captures from the last N days." },
  since: { type: "string", description: "Only captures on or after this ISO date." },
  kind: { type: "string", enum: ["meeting", "watch", "video", "document", "screenshot"], description: "meeting = Cuecard meeting notes; the rest are Pointer captures." },
  limit: { type: "number" },
};
const TOOLS = [
  { name: "pointer_list", description: "List Cuecard meetings and Pointer captures (watch sessions, screen recordings, documents read off the screen, screenshots), newest first, with id, kind, length and title.", inputSchema: { type: "object", properties: FILTERS } },
  { name: "pointer_search", description: "Search Cuecard meeting notes and everything Pointer captured: what was said (transcripts, with You/Them), what was on screen (OCR text of each key frame, with the app/window), and the write-ups. Returns matching lines with capture id and [m:ss] timestamp, best first. Use to find when something came up, who said it, or which doc/screen showed it.", inputSchema: { type: "object", properties: { query: { type: "string" }, in: { type: "string", enum: ["all", "said", "screen", "digest"], description: "Where to search (default all)." }, ...FILTERS }, required: ["query"] } },
  { name: "pointer_get", description: "Get the full material for one meeting or capture: its write-up (for meetings: summary, decisions, action items, open questions, risks), the timed transcript and the screen text per key frame. Use it as source material when answering or writing something from a meeting or recording. id from pointer_list/search, or 'latest'.", inputSchema: { type: "object", properties: { id: { type: "string" }, parts: { type: "array", items: { type: "string", enum: ["digest", "timeline", "said", "screen"] }, description: "Default digest + timeline (said and on-screen text interleaved by time). said / screen give either stream alone." }, max_chars: { type: "number" } }, required: ["id"] } },
];

function call(name, a) {
  if (name === "pointer_list") return list(a);
  if (name === "pointer_search") return search(a);
  if (name === "pointer_get") return get(a);
  throw new Error("unknown tool: " + name);
}

module.exports = { call };
if (require.main !== module) return;

const send = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");
function handle(msg) {
  const { id, method, params } = msg;
  if (method === "initialize") return send({ jsonrpc: "2.0", id, result: { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "pointer", version: "0.1.0" } } });
  if (method === "notifications/initialized" || method === "notifications/cancelled") return;
  if (method === "tools/list") return send({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
  if (method === "tools/call") {
    try { return send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: call(params.name, params.arguments || {}) }] } }); }
    catch (e) { return send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Error: " + e.message }], isError: true } }); }
  }
  if (id !== undefined) send({ jsonrpc: "2.0", id, error: { code: -32601, message: "method not found: " + method } });
}
let buf = "";
process.stdin.setEncoding("utf-8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (line) { try { handle(JSON.parse(line)); } catch {} }
  }
});

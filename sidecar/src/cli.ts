// `margie` — talk to Margie from Warp, Claude-Code style: you see her work as
// it happens (tool calls ▸, their first output line ⎿, held actions, live
// notices), a spinner with elapsed time while she thinks, a prompt that shows
// what's waiting for your yes, and slash commands. Same brain, same history and
// held command as the voice overlay. Text only — no TTS in the terminal.
//
//   margie                       REPL
//   margie "one question"        one-shot; tool activity on stderr (-q silences)
//   margie status | stop | restart | log
import { createInterface, Interface } from "node:readline";
import { spawnSync, spawn } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ensureDaemon, Client } from "./client.js";
import { SOCK, WireOut } from "./protocol.js";

const DIM = "\x1b[2m", CYAN = "\x1b[36m", YEL = "\x1b[33m", GRN = "\x1b[32m", MAG = "\x1b[35m", BOLD = "\x1b[1m", RESET = "\x1b[0m";
const ITAL = "\x1b[3m", PINK = "\x1b[38;5;213m", LAV = "\x1b[38;5;147m", MINT = "\x1b[38;5;121m", PEACH = "\x1b[38;5;216m", GREY = "\x1b[38;5;245m";
const NAME = `${PINK}${BOLD}Margie${RESET}`;
const cols = () => Math.min(process.stdout.columns || 100, 100);

/** Word-wrap to the terminal, with a gutter. Keeps existing line breaks. */
function wrap(text: string, indent = "  "): string {
  const width = cols() - indent.length;
  const out: string[] = [];
  for (const para of text.split("\n")) {
    if (!para.trim()) { out.push(""); continue; }
    let line = "";
    for (const word of para.split(/\s+/)) {
      const vis = (line + " " + word).replace(/\x1b\[[0-9;]*m/g, "").length;
      if (line && vis > width) { out.push(indent + line); line = word; } else line = line ? line + " " + word : word;
    }
    if (line) out.push(indent + line);
  }
  return out.join("\n");
}
/** Light syntax colouring — ONE pass with a combined pattern, so an inserted
 *  colour code (which contains digits) is never re-scanned by a later rule. */
function flair(text: string): string {
  const re = /("[^"\n]{1,160}")|(https?:\/\/[^\s)]+)|(\b(?:PT-\d+|MR !?\d+|!\d{2,6}|#\d{2,6})\b)|(\b(?:yes|Yes)\?)|(\b\d+(?:[.,]\d+)?%?\b)/g;
  return text.replace(re, (m, quote, url, ticket, yes, num) => {
    if (quote) return `${ITAL}${LAV}${quote}${RESET}`;
    if (url) return `${DIM}${url}${RESET}`;
    if (ticket) return `${MINT}${ticket}${RESET}`;
    if (yes) return `${PEACH}${yes}${RESET}`;
    if (num) return `${PEACH}${num}${RESET}`;
    return m;
  });
}
function renderReply(text: string): string {
  const body = wrap(flair(text), "   ");
  return `\n ${NAME} ${GREY}·${RESET}\n${body}\n`;
}
const SCRIPTS = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "scripts");
const ENTRY = new URL("./index.js", import.meta.url).pathname;
const HOME = process.env.HOME || "";
const TTY = process.stdout.isTTY === true;

function fmtMs(ms: number): string {
  if (ms < 90000) return `${Math.round(ms / 1000)}s`;
  if (ms < 5400000) return `${Math.round(ms / 60000)}m`;
  return `${(ms / 3600000).toFixed(1)}h`;
}
const short = (s: string, n = 110) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
/** Strip the checkout path from tool lines so they read like commands, not paths. */
const tidyCmd = (s: string) => s.replace(new RegExp(SCRIPTS.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "/", "g"), "");

// ── Spinner ────────────────────────────────────────────────────────────────────
class Spinner {
  private t: NodeJS.Timeout | null = null;
  private i = 0;
  private started = 0;
  private label = "thinking";
  private frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
  start(label = "thinking") {
    if (!TTY) return;
    this.label = label; this.started = Date.now();
    this.stop();
    this.t = setInterval(() => this.draw(), 90);
    this.draw();
  }
  set(label: string) { this.label = label; if (this.t) this.draw(); }
  private draw() {
    const f = this.frames[this.i++ % this.frames.length];
    process.stdout.write(`\r\x1b[2K${MAG}${f}${RESET} ${DIM}${this.label}… ${fmtMs(Date.now() - this.started)}${RESET}`);
  }
  /** Clear the spinner line so other output can be printed cleanly. */
  clear() { if (this.t) process.stdout.write("\r\x1b[2K"); }
  stop() { if (this.t) { clearInterval(this.t); this.t = null; process.stdout.write("\r\x1b[2K"); } }
}

// ── Event rendering (shared by REPL and one-shot) ─────────────────────────────
function renderEvent(m: WireOut, spin: Spinner, out: NodeJS.WriteStream) {
  const text = tidyCmd(m.text || "");
  spin.clear();
  switch (m.event) {
    case "thinking": spin.set(text || "thinking"); return;
    case "tool":     out.write(`${GREY}   ▸ ${LAV}${short(text)}${RESET}\n`); spin.set("running"); return;
    case "result":   out.write(`${GREY}   ⎿ ${short(text, 130)}${RESET}\n`); spin.set("thinking"); return;
    case "held":     out.write(`${PEACH}   ⏸ waiting for your yes: ${short(text)}${RESET}\n`); spin.set("reading back"); return;
    default: return;
  }
}

async function ask(c: Client, text: string, spin: Spinner, out: NodeJS.WriteStream): Promise<string> {
  spin.start("thinking");
  c.onEvent = (m) => renderEvent(m, spin, out);
  try {
    const reply = await c.request(text);
    return reply;
  } finally {
    spin.stop();
  }
}

// ── Status / slash commands ───────────────────────────────────────────────────
async function heldSummary(c: Client): Promise<string | null> {
  try {
    const st = await c.control("status");
    const p = st.pending as { cmd: string; ageMs: number } | null;
    return p ? tidyCmd(p.cmd) : null;
  } catch { return null; }
}

async function cmdStatus() {
  let c: Client;
  try { c = await ensureDaemon(); } catch (e) { console.log(`daemon: down (${(e as Error).message})`); return; }
  const st = await c.control("status");
  let stale = "";
  try { if (st.build && statSync(ENTRY).mtimeMs !== st.build) stale = "  (STALE — restart to pick up the new build)"; } catch { /* ignore */ }
  console.log(`${BOLD}daemon${RESET}   pid ${st.pid}, up ${fmtMs(Number(st.uptimeMs))}, ${st.turns} turns${st.busy ? ", busy" : ""}${Number(st.queue) ? `, queue ${st.queue}` : ""}${stale}`);
  const pending = st.pending as { cmd: string; ageMs: number } | null;
  console.log(pending ? `${YEL}held${RESET}     (${fmtMs(pending.ageMs)}) ${tidyCmd(pending.cmd)}` : `${DIM}held     nothing waiting for a yes${RESET}`);
  const clients = (st.clients as Array<{ source: string; connectedMs: number }>) || [];
  console.log(`${DIM}clients  ${clients.map((x) => `${x.source} (${fmtMs(x.connectedMs)})`).join(", ") || "none"}${RESET}`);
  const pollers = (st.pollers as Array<{ name: string; everyMs: number; lastNotice: string }>) || [];
  console.log(`${DIM}pollers  ${pollers.map((p) => `${p.name}/${fmtMs(p.everyMs)}`).join("  ")}${RESET}`);
  c.close();
  for (const [label, cmd] of [["sessions", "session.sh list"], ["tasks", "claude-task.sh status"], ["dispatch", "dispatch.sh status"]] as const) {
    const r = spawnSync("bash", ["-c", `${SCRIPTS}/${cmd}`], { encoding: "utf8" });
    const lines = (r.stdout || "").trim().split("\n").filter(Boolean).slice(0, 6);
    if (lines.length && !/^No /.test(lines[0])) console.log(`${BOLD}${label}${RESET}\n${lines.map((l) => "  " + l).join("\n")}`);
  }
}

function latestDispatchFile(kind: "spec" | "qa" | "mr"): string | null {
  const base = `${HOME}/.margie/dispatch`;
  if (!existsSync(base)) return null;
  const r = spawnSync("bash", ["-c", `ls -td ${base}/d-* 2>/dev/null | head -1`], { encoding: "utf8" });
  const d = (r.stdout || "").trim();
  if (!d) return null;
  const f = `${d}/${kind}.md`;
  return existsSync(f) ? f : null;
}

function page(text: string) {
  // Long text goes through `less` when interactive (like Claude's viewer), else straight out.
  if (TTY && text.split("\n").length > 40) {
    const p = spawn("less", ["-R"], { stdio: ["pipe", "inherit", "inherit"] });
    p.stdin.end(text);
    return new Promise<void>((res) => p.on("close", () => res()));
  }
  process.stdout.write(text + "\n");
  return Promise.resolve();
}

const HELP = `${PINK}✿${RESET} ${NAME} ${GREY}— your assistant, dearie. One brain across voice and every terminal; just talk.${RESET}
  ${CYAN}/status${RESET}   daemon, held command, sessions, tasks, dispatches
  ${CYAN}/held${RESET}     what's waiting for your yes      ${CYAN}/yes${RESET}  ${CYAN}/no${RESET}   answer it
  ${CYAN}/spec${RESET}     latest spec in full             ${CYAN}/qa${RESET}   ${CYAN}/mr${RESET}    latest QA report / MR text
  ${CYAN}/log${RESET}      her recent brain log            ${CYAN}/clear${RESET}     ${CYAN}/quit${RESET}
  ${GREY}▸ what she ran   ⎿ what it said   ⏸ waiting for your yes   ✿ something she noticed in the background${RESET}`;

// ── REPL ──────────────────────────────────────────────────────────────────────
async function repl() {
  let c = await ensureDaemon();
  const spin = new Spinner();
  let rl: Interface;
  let held: string | null = null;

  const prompt = () => {
    if (!rl) return;
    rl.setPrompt(held ? `${PEACH}⏸ ${short(held, 44)}${RESET}\n${PINK}you${RESET} ❯ ` : `${PINK}you${RESET} ❯ `);
    try { rl.prompt(true); } catch { /* closed */ }
  };
  const hook = (client: Client) => {
    client.onEvent = (m) => renderEvent(m, spin, process.stdout);
    client.onNotice = (t) => {
      spin.clear();
      process.stdout.write(`\r\x1b[2K${PINK}✿${RESET} ${CYAN}${t}${RESET}\n`);
      prompt();
    };
    client.onClose = () => {
      spin.stop();
      process.stdout.write(`\r\x1b[2K${DIM}(brain restarted — reconnecting…)${RESET}\n`);
      ensureDaemon().then((nc) => { c = nc; hook(c); prompt(); }).catch(() => prompt());
    };
  };
  hook(c);

  rl = createInterface({ input: process.stdin, output: process.stdout, terminal: TTY });
  let closed = false;
  const safePrompt = () => { if (!closed) prompt(); };
  // Lines are queued and handled one at a time (a turn awaits the brain), so
  // piped input and fast typing never race the handler; on EOF we drain, then exit.
  const queue: string[] = [];
  let busy = false;
  const handle = async (text: string) => {
    if (text === "/quit" || text === "/exit") { rl.close(); return; }
    if (text === "/help" || text === "/?") { console.log(HELP); return; }
    if (text === "/clear") { process.stdout.write("\x1b[2J\x1b[H"); return; }
    if (text === "/status") { await cmdStatus(); held = await heldSummary(c); return; }
    if (text === "/held") { console.log(held ? `${YEL}⏸ ${held}${RESET}` : `${DIM}nothing held${RESET}`); return; }
    if (text === "/log") { spawnSync("tail", ["-25", `${HOME}/.margie/brain.log`], { stdio: "inherit" }); return; }
    if (text === "/spec" || text === "/qa" || text === "/mr") {
      const f = latestDispatchFile(text.slice(1) as "spec" | "qa" | "mr");
      if (f) await page(readFileSync(f, "utf8")); else console.log(`${DIM}no ${text.slice(1)} on the latest dispatch yet${RESET}`);
      return;
    }
    const send = text === "/yes" ? "yes" : text === "/no" ? "no" : text;
    try {
      const reply = await ask(c, send, spin, process.stdout);
      console.log(renderReply(reply));
    } catch {
      try { c.close(); c = await ensureDaemon(); hook(c); console.log(renderReply(await ask(c, send, spin, process.stdout))); }
      catch (e) { console.log(`(brain unreachable: ${(e as Error).message})`); }
    }
    held = await heldSummary(c);
  };
  const pump = async () => {
    if (busy) return;
    busy = true;
    while (queue.length) { await handle(queue.shift()!); safePrompt(); }
    busy = false;
    if (closed) { spin.stop(); c.close(); process.stdout.write("\n"); process.exit(0); }
  };
  rl.on("line", (line) => { const t = line.trim(); if (t) { queue.push(t); void pump(); } else safePrompt(); });
  rl.on("close", () => { closed = true; if (!busy) { spin.stop(); c.close(); process.stdout.write("\n"); process.exit(0); } });

  console.log(HELP);
  held = await heldSummary(c);
  safePrompt();
}

async function oneShot(text: string, quiet: boolean, extra: Record<string, unknown> = {}) {
  const c = await ensureDaemon();
  const spin = new Spinner();
  const source = (process.env.MARGIE_SOURCE as string) || "cli";
  if (quiet) { c.onEvent = () => { /* silent */ }; console.log(await c.request(text, source, extra)); c.close(); return; }
  // Progress to stderr so stdout stays the reply (pipeable).
  const errSpin = new (class extends Spinner { start() { /* no spinner on stderr */ } stop() { /* noop */ } clear() { /* noop */ } })();
  c.onEvent = (m) => renderEvent(m, errSpin, process.stderr);
  const reply = await c.request(text, source, extra);
  spin.stop();
  console.log(TTY ? renderReply(reply) : reply);
  c.close();
}

async function main() {
  const args = process.argv.slice(2);
  const quiet = args.includes("-q");
  // --conv <id> / --speaker <name>: set by the Slack watcher so the brain knows where a turn came from and who spoke.
  const extra: Record<string, unknown> = {};
  const rest: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "-q") continue;
    if (args[i] === "--conv") { extra.conv = args[++i]; continue; }
    if (args[i] === "--speaker") { extra.speaker = args[++i]; continue; }
    rest.push(args[i]);
  }
  const cmd = rest[0];

  if (cmd === "status") { await cmdStatus(); return; }
  if (cmd === "stop") {
    try { const c = await ensureDaemon(); await c.control("stop"); c.close(); console.log("daemon stopping."); }
    catch { console.log("daemon wasn't running."); }
    return;
  }
  if (cmd === "restart") {
    try { const c = await ensureDaemon(); await c.control("stop"); c.close(); } catch { /* fine */ }
    await new Promise((r) => setTimeout(r, 800));
    const c = await ensureDaemon(); await c.control("ping"); c.close();
    console.log("daemon restarted.");
    return;
  }
  if (cmd === "log") { spawnSync("tail", ["-40", `${HOME}/.margie/brain.log`], { stdio: "inherit" }); return; }
  if (rest.length > 0) { await oneShot(rest.join(" "), quiet, extra); return; }
  await repl();
}

main().catch((e) => { console.error(`margie: ${e.message} (socket ${SOCK})`); process.exit(1); });

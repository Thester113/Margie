// `margie` — talk to Margie from Warp. Same brain, same history, same pending
// confirmation as the voice overlay: a "yes" typed here confirms what was
// asked by voice, and vice-versa. Text only — no TTS in the terminal.
//
//   margie                       REPL (margie> …; /status, /quit)
//   margie "one question"        one-shot; tool activity on stderr (-q silences)
//   margie status | stop | restart | log
import { createInterface } from "node:readline";
import { spawnSync } from "node:child_process";
import { statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ensureDaemon, Client } from "./client.js";
import { SOCK } from "./protocol.js";

const DIM = "\x1b[2m", CYAN = "\x1b[36m", RESET = "\x1b[0m";
const SCRIPTS = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "scripts");
const ENTRY = new URL("./index.js", import.meta.url).pathname;

function fmtMs(ms: number): string {
  if (ms < 90000) return `${Math.round(ms / 1000)}s`;
  if (ms < 5400000) return `${Math.round(ms / 60000)}m`;
  return `${(ms / 3600000).toFixed(1)}h`;
}

async function cmdStatus() {
  let c: Client;
  try { c = await ensureDaemon(); } catch (e) { console.log(`daemon: down (${(e as Error).message})`); return; }
  const st = await c.control("status");
  let stale = "";
  try { if (st.build && statSync(ENTRY).mtimeMs !== st.build) stale = "  (STALE — restart to pick up the new build)"; } catch { /* ignore */ }
  console.log(`daemon: pid ${st.pid}, up ${fmtMs(Number(st.uptimeMs))}, ${st.turns} turns${st.busy ? ", busy" : ""}${Number(st.queue) ? `, queue ${st.queue}` : ""}${stale}`);
  const pending = st.pending as { cmd: string; ageMs: number } | null;
  console.log(pending ? `held for confirmation (${fmtMs(pending.ageMs)}): ${pending.cmd}` : "nothing held for confirmation");
  const clients = (st.clients as Array<{ source: string; connectedMs: number }>) || [];
  console.log(`clients: ${clients.map((x) => `${x.source} (${fmtMs(x.connectedMs)})`).join(", ") || "none"}`);
  const pollers = (st.pollers as Array<{ name: string; everyMs: number; lastNotice: string }>) || [];
  for (const p of pollers) console.log(`poller ${p.name}: every ${fmtMs(p.everyMs)}${p.lastNotice ? ` — last: ${p.lastNotice.slice(0, 70)}` : ""}`);
  c.close();
  for (const [label, cmd] of [["sessions", "session.sh list"], ["tasks", "claude-task.sh status"]] as const) {
    const r = spawnSync("bash", ["-c", `${SCRIPTS}/${cmd}`], { encoding: "utf8" });
    const out = (r.stdout || "").trim();
    if (out) console.log(`${label}:\n${out.split("\n").slice(0, 6).map((l) => "  " + l).join("\n")}`);
  }
}

async function oneShot(text: string, quiet: boolean) {
  const c = await ensureDaemon();
  c.onEvent = (m) => { if (!quiet) process.stderr.write(`${DIM}  ▸ ${m.event}: ${m.text}${RESET}\n`); };
  const reply = await c.request(text);
  console.log(reply);
  c.close();
}

async function repl() {
  let c = await ensureDaemon();
  const rl = createInterface({ input: process.stdin, output: process.stdout, prompt: "margie> " });
  const hook = (client: Client) => {
    client.onEvent = (m) => { process.stdout.write(`${DIM}  ▸ ${m.event}: ${m.text}${RESET}\n`); };
    client.onNotice = (t) => {
      process.stdout.write(`\r\x1b[2K${CYAN}[margie] ${t}${RESET}\n`);
      rl.prompt(true);
    };
    client.onClose = () => {
      process.stdout.write(`\r\x1b[2K${DIM}(daemon restarted — reconnecting…)${RESET}\n`);
      // Reconnect eagerly so the next line goes straight through.
      ensureDaemon().then((nc) => { c = nc; hook(c); rl.prompt(true); }).catch(() => rl.prompt(true));
    };
  };
  hook(c);
  console.log(`${DIM}Margie is listening (shared brain — a "yes" here confirms voice requests too). /status, /quit.${RESET}`);
  rl.prompt();
  rl.on("line", async (line) => {
    const text = line.trim();
    if (!text) { rl.prompt(); return; }
    if (text === "/quit" || text === "/exit") { rl.close(); return; }
    if (text === "/status") { await cmdStatus(); rl.prompt(); return; }
    try {
      const reply = await c.request(text);
      console.log(reply);
    } catch {
      try { c.close(); c = await ensureDaemon(); hook(c); console.log(await c.request(text)); }
      catch (e) { console.log(`(brain unreachable: ${(e as Error).message})`); }
    }
    rl.prompt();
  });
  rl.on("close", () => { c.close(); process.exit(0); });
}

async function main() {
  const args = process.argv.slice(2);
  const quiet = args.includes("-q");
  const rest = args.filter((a) => a !== "-q");
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
  if (cmd === "log") {
    spawnSync("tail", ["-40", `${process.env.HOME}/.margie/brain.log`], { stdio: "inherit" });
    return;
  }
  if (rest.length > 0) { await oneShot(rest.join(" "), quiet); return; }
  await repl();
}

main().catch((e) => { console.error(`margie: ${e.message} (socket ${SOCK})`); process.exit(1); });

// The Margie brain daemon: one long-lived process owning the shared brain
// (history, pending confirmation, gates — all in brain.ts), serving the Tauri
// app and any number of `margie` CLIs over a unix socket, and hosting the
// background pollers (dispatch tick, task notify, agent-messages check).
//
// Lifecycle: `node dist/index.js --daemon` is a LAUNCHER — it re-spawns itself
// detached (own session, logs to ~/.margie/daemon.log) and exits, so whoever
// started it (the app, a CLI, a script) never holds it hostage. The O_EXCL
// lock file arbitrates races; a stale build (dist/index.js rebuilt) drains and
// exits so the next request gets the new code.
import { createServer, Server, Socket } from "node:net";
import {
  closeSync, existsSync, mkdirSync, openSync, readFileSync, statSync,
  unlinkSync, watchFile, writeFileSync, writeSync, chmodSync, appendFileSync,
} from "node:fs";
import { spawn } from "node:child_process";
import { enqueue, logBrain, runScript, noteToHistory, brainStatus } from "./brain.js";
import { SOCK, LOCK, MARGIE_DIR, DAEMON_LOG, WireIn, WireOut } from "./protocol.js";

const HOME = process.env.HOME || "/";
let BUILD = 0;
let server: Server | null = null;
let draining = false;
const startedAt = Date.now();

interface Client { sock: Socket; source: string; connectedAt: number; }
const clients = new Set<Client>();

function dlog(line: string) {
  try { appendFileSync(DAEMON_LOG, `${new Date().toISOString()} ${line}\n`); } catch { /* ignore */ }
}
function send(sock: Socket, msg: WireOut) {
  try { sock.write(JSON.stringify(msg) + "\n"); } catch { /* client gone */ }
}
function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

export function daemonMain(entryPath: string) {
  mkdirSync(MARGIE_DIR, { recursive: true });
  if (!process.env.MARGIE_DAEMON_CHILD) {
    // Launcher: detach a child into its own session and get out of the way.
    const logFd = openSync(DAEMON_LOG, "a");
    const child = spawn(process.execPath, [entryPath, "--daemon"], {
      detached: true,
      stdio: ["ignore", logFd, logFd],
      env: { ...process.env, MARGIE_DAEMON_CHILD: "1" },
    });
    child.unref();
    console.log(`margie daemon launching (pid ${child.pid})`);
    process.exit(0);
  }

  // Child: the O_EXCL lock is the single-daemon arbiter.
  for (let attempt = 0; ; attempt++) {
    try {
      const fd = openSync(LOCK, "wx");
      writeSync(fd, String(process.pid));
      closeSync(fd);
      break;
    } catch {
      let pid = 0;
      try { pid = parseInt(readFileSync(LOCK, "utf8"), 10); } catch { /* ignore */ }
      if (pid && alive(pid)) { dlog(`already running (pid ${pid}) — exiting`); process.exit(0); }
      if (attempt >= 1) { dlog("could not take lock — exiting"); process.exit(1); }
      try { unlinkSync(LOCK); } catch { /* ignore */ }
    }
  }

  // We hold the lock, so any existing socket is stale.
  try { unlinkSync(SOCK); } catch { /* ignore */ }

  BUILD = statSync(entryPath).mtimeMs;
  server = createServer(onConnection);
  server.listen(SOCK, () => {
    try { chmodSync(SOCK, 0o600); } catch { /* ignore */ }
    dlog(`listening on ${SOCK} (pid ${process.pid}, build ${BUILD})`);
    logBrain(`DAEMON up (pid ${process.pid})`);
  });

  // Rebuilds: drain when idle, exit, let the next request start the new code.
  let rebuildTimer: NodeJS.Timeout | null = null;
  watchFile(entryPath, { interval: 2000 }, () => {
    if (rebuildTimer) clearTimeout(rebuildTimer);
    rebuildTimer = setTimeout(() => {
      dlog("dist rebuilt — draining");
      draining = true;
    }, 1500);
  });

  // Self-check: socket removed → exit so a fresh daemon can be spawned;
  // draining + idle → shut down.
  setInterval(() => {
    if (!existsSync(SOCK)) { dlog("socket vanished — exiting"); shutdown(1); }
    const st = brainStatus();
    if (draining && !st.busy && st.queue === 0) shutdown(0);
  }, 5000).unref();

  process.on("SIGTERM", () => shutdown(0));
  process.on("SIGINT", () => shutdown(0));

  startPollers();
}

function shutdown(code: number) {
  dlog(`shutting down (code ${code})`);
  try { server?.close(); } catch { /* ignore */ }
  try { unlinkSync(SOCK); } catch { /* ignore */ }
  try { unlinkSync(LOCK); } catch { /* ignore */ }
  setTimeout(() => process.exit(code), 200);
}

function onConnection(sock: Socket) {
  const client: Client = { sock, source: "app", connectedAt: Date.now() };
  clients.add(client);
  let buf = "";
  sock.on("data", (d) => {
    buf += d.toString();
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (line) handleLine(client, line);
    }
  });
  const drop = () => clients.delete(client);
  sock.on("close", drop);
  sock.on("error", drop);
}

function handleLine(client: Client, line: string) {
  let msg: WireIn;
  try { msg = JSON.parse(line); } catch { return; }

  if (msg.op) {
    switch (msg.op) {
      case "hello":
        if (msg.source) client.source = msg.source;
        send(client.sock, { op: "pong", build: BUILD, pid: process.pid });
        return;
      case "ping":
        send(client.sock, { op: "pong", build: BUILD, pid: process.pid });
        return;
      case "status": {
        const st = brainStatus();
        send(client.sock, {
          op: "status", pid: process.pid, build: BUILD,
          uptimeMs: Date.now() - startedAt, draining,
          ...st,
          clients: [...clients].map((c) => ({ source: c.source, connectedMs: Date.now() - c.connectedAt })),
          pollers: pollers.map((p) => ({ name: p.name, everyMs: p.everyMs, lastRun: p.lastRun, lastNotice: p.lastNotice })),
        });
        return;
      }
      case "stop":
        send(client.sock, { op: "stopping" });
        shutdown(0);
        return;
    }
  }

  if (typeof msg.text === "string" && typeof msg.id === "number") {
    const source = msg.source || client.source;
    logBrain(`USER[${msg.id} ${source}]: ${msg.text}`);
    enqueue({
      id: msg.id,
      text: msg.text,
      source,
      reply: (text) => send(client.sock, { id: msg.id, text }),
      emit: (event, text) => send(client.sock, { id: msg.id, event: event as WireOut["event"], text }),
    });
  }
}

// ── Pollers ──────────────────────────────────────────────────────────────────
// Each runs a helper on its interval through the same env as the bash tool.
// Contract: silent when idle; any non-empty stdout becomes a NOTICE — recorded
// in history, broadcast to every client, and (only while the app is connected)
// dropped in ~/.margie/announce/ so the voice loop speaks it when idle.
interface Poller { name: string; cmd: string; everyMs: number; running: boolean; lastRun: number; lastNotice: string; }
const pollers: Poller[] = [];

function parseEvery(v: unknown, dflt: number): number {
  if (typeof v === "number") return v * 1000;
  if (typeof v === "string") {
    const m = v.match(/^(\d+)\s*(s|m|h)?$/);
    if (m) return parseInt(m[1], 10) * (m[2] === "h" ? 3600000 : m[2] === "m" ? 60000 : 1000);
  }
  return dflt;
}

function startPollers() {
  const builtins: Array<[string, string, number]> = [
    ["dispatch", "dispatch.sh tick", 60000],
    ["tasks", "claude-task.sh notify", 60000],
    ["agent-messages", "agent-messages.sh check", 300000],
    ["slack-watch", "slack-watch.sh", 20000],   // mentions of Tom deserve a quick answer
    ["standup", "standup.sh auto", 60000],
  ];
  let extra: Array<{ name?: string; cmd?: string; every?: unknown }> = [];
  try {
    extra = JSON.parse(readFileSync(`${HOME}/.margie/config.json`, "utf8")).pollers || [];
  } catch { /* ignore */ }
  for (const [name, cmd, everyMs] of builtins) pollers.push({ name, cmd, everyMs, running: false, lastRun: 0, lastNotice: "" });
  for (const p of extra) {
    if (p?.cmd) pollers.push({ name: p.name || p.cmd, cmd: p.cmd, everyMs: parseEvery(p.every, 300000), running: false, lastRun: 0, lastNotice: "" });
  }
  setTimeout(() => {
    for (const p of pollers) {
      const t = setInterval(() => void runPoller(p), p.everyMs);
      t.unref();
    }
  }, 30000).unref();
}

async function runPoller(p: Poller) {
  if (p.running || draining) return;
  p.running = true;
  p.lastRun = Date.now();
  try {
    const out = (await runScript(p.cmd)).trim();
    // Only a script's deliberate one-liner becomes a notice — never tool noise,
    // a timeout marker, or a stack trace.
    const looksLikeError = /^(curl:|jq:|bash:|Traceback|Error|\[exec error\])/m.test(out) || out.includes("[timed out]");
    if (out && out !== "[no output]" && !out.startsWith("[") && !looksLikeError) {
      const text = out.split("\n").filter(Boolean).join(" — ").slice(0, 400);
      p.lastNotice = text;
      notice(text);
    }
  } catch (e) {
    dlog(`poller ${p.name} error: ${(e as Error).message}`);
  } finally {
    p.running = false;
  }
}

function notice(text: string) {
  logBrain(`NOTICE: ${text}`);
  noteToHistory(text);
  for (const c of clients) send(c.sock, { event: "notice", text });
  if ([...clients].some((c) => c.source === "app")) {
    try {
      mkdirSync(`${MARGIE_DIR}/announce`, { recursive: true });
      writeFileSync(`${MARGIE_DIR}/announce/${Date.now()}${process.hrtime()[1]}.txt`, text);
    } catch { /* ignore */ }
  }
}

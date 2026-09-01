// Socket client for the Margie brain daemon — shared by the CLI (cli.ts) and
// anything else that wants to talk to the brain from Node.
import { connect, Socket } from "node:net";
import { spawnSync } from "node:child_process";
import { statSync } from "node:fs";
import { SOCK, WireOut } from "./protocol.js";

const ENTRY = new URL("./index.js", import.meta.url).pathname;

function connectOnce(timeoutMs = 1500): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const sock = connect(SOCK);
    const t = setTimeout(() => { sock.destroy(); reject(new Error("connect timeout")); }, timeoutMs);
    sock.once("connect", () => { clearTimeout(t); resolve(sock); });
    sock.once("error", (e) => { clearTimeout(t); reject(e); });
  });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Connect to the daemon, spawning it (and replacing a stale build) if needed. */
export async function ensureDaemon(): Promise<Client> {
  for (let round = 0; round < 2; round++) {
    let sock: Socket | null = null;
    try { sock = await connectOnce(); } catch { /* not running */ }
    if (!sock) {
      spawnSync(process.execPath, [ENTRY, "--daemon"], { stdio: "ignore" });
      for (let i = 0; i < 20 && !sock; i++) {
        await sleep(200);
        try { sock = await connectOnce(); } catch { /* retry */ }
      }
    }
    if (!sock) throw new Error(`could not start the margie daemon (socket ${SOCK})`);
    const client = new Client(sock);
    const pong = await client.control("hello", { source: process.env.MARGIE_SOURCE || "cli" });
    let current = 0;
    try { current = statSync(ENTRY).mtimeMs; } catch { /* ignore */ }
    if (round === 0 && current && pong.build && pong.build !== current) {
      // Stale daemon from an older build: stop it and start fresh.
      try { await client.control("stop"); } catch { /* ignore */ }
      client.close();
      await sleep(600);
      continue;
    }
    return client;
  }
  throw new Error("daemon kept coming up stale");
}

export class Client {
  private sock: Socket;
  private buf = "";
  private nextId = 1;
  private waiters = new Map<number, (text: string) => void>();
  private ctrlWaiters: Array<(msg: WireOut) => void> = [];
  onEvent: ((msg: WireOut) => void) | null = null;   // tool/held for in-flight ids
  onNotice: ((text: string) => void) | null = null;  // unsolicited broadcasts
  onClose: (() => void) | null = null;

  constructor(sock: Socket) {
    this.sock = sock;
    sock.on("data", (d) => this.feed(d.toString()));
    sock.on("close", () => this.onClose?.());
    sock.on("error", () => { /* surfaced via close */ });
  }

  private feed(chunk: string) {
    this.buf += chunk;
    let nl;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, nl).trim();
      this.buf = this.buf.slice(nl + 1);
      if (!line) continue;
      let msg: WireOut;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.op) { this.ctrlWaiters.shift()?.(msg); continue; }
      if (msg.event === "notice") { this.onNotice?.(msg.text || ""); continue; }
      if (msg.event) { this.onEvent?.(msg); continue; }
      if (typeof msg.id === "number" && this.waiters.has(msg.id)) {
        const w = this.waiters.get(msg.id)!;
        this.waiters.delete(msg.id);
        w(msg.text || "");
      }
    }
  }

  request(text: string, source = "cli"): Promise<string> {
    const id = this.nextId++;
    return new Promise((resolve) => {
      this.waiters.set(id, resolve);
      this.sock.write(JSON.stringify({ id, text, source }) + "\n");
    });
  }

  control(op: string, extra: Record<string, unknown> = {}): Promise<WireOut> {
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`${op} timed out`)), 4000);
      this.ctrlWaiters.push((msg) => { clearTimeout(t); resolve(msg); });
      this.sock.write(JSON.stringify({ op, ...extra }) + "\n");
    });
  }

  close() { try { this.sock.end(); this.sock.destroy(); } catch { /* ignore */ } }
}

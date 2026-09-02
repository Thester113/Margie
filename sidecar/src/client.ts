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
  private waiters = new Map<number, { resolve: (text: string) => void; reject: (e: Error) => void }>();
  private ctrlWaiters: Array<{ resolve: (msg: WireOut) => void; reject: (e: Error) => void }> = [];
  private dead = false;
  onEvent: ((msg: WireOut) => void) | null = null;   // tool/held for in-flight ids
  onNotice: ((text: string) => void) | null = null;  // unsolicited broadcasts
  onClose: (() => void) | null = null;

  constructor(sock: Socket) {
    this.sock = sock;
    sock.on("data", (d) => this.feed(d.toString()));
    sock.on("close", () => { this.failAll(new Error("daemon connection closed")); this.onClose?.(); });
    sock.on("error", (e) => this.failAll(e));
  }

  /** The socket is gone: every in-flight request must fail, never hang. */
  private failAll(e: Error) {
    if (this.dead) return;
    this.dead = true;
    for (const w of this.waiters.values()) w.reject(e);
    this.waiters.clear();
    for (const c of this.ctrlWaiters) c.reject(e);
    this.ctrlWaiters = [];
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
      if (msg.op) { this.ctrlWaiters.shift()?.resolve(msg); continue; }
      if (msg.event === "notice") { this.onNotice?.(msg.text || ""); continue; }
      if (msg.event) { this.onEvent?.(msg); continue; }
      if (typeof msg.id === "number" && this.waiters.has(msg.id)) {
        const w = this.waiters.get(msg.id)!;
        this.waiters.delete(msg.id);
        w.resolve(msg.text || "");
      }
    }
  }

  request(text: string, source = "cli"): Promise<string> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      if (this.dead || this.sock.destroyed) { reject(new Error("daemon connection closed")); return; }
      this.waiters.set(id, { resolve, reject });
      this.sock.write(JSON.stringify({ id, text, source }) + "\n", (err) => { if (err) this.failAll(err); });
    });
  }

  control(op: string, extra: Record<string, unknown> = {}): Promise<WireOut> {
    return new Promise((resolve, reject) => {
      if (this.dead || this.sock.destroyed) { reject(new Error("daemon connection closed")); return; }
      const t = setTimeout(() => reject(new Error(`${op} timed out`)), 4000);
      this.ctrlWaiters.push({ resolve: (msg) => { clearTimeout(t); resolve(msg); }, reject: (e) => { clearTimeout(t); reject(e); } });
      this.sock.write(JSON.stringify({ op, ...extra }) + "\n", (err) => { if (err) this.failAll(err); });
    });
  }

  close() { try { this.sock.end(); this.sock.destroy(); } catch { /* ignore */ } }
}

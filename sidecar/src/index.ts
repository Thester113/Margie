// Margie's brain — entry point. Default mode is the original stdio NDJSON
// protocol (one {id,text} request line in → one {id,text} response line out),
// used by the Tauri bridge today and kept forever as the smoke-test surface.
// The shared logic lives in brain.ts; `--daemon` (the socket server the app
// and the `margie` CLI share) arrives in server.ts.
import { createInterface } from "node:readline";
import { enqueue, logBrain } from "./brain.js";

function stdioMain() {
  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    try {
      const req = JSON.parse(trimmed) as { id: number; text: string };
      logBrain(`USER[${req.id}]: ${req.text}`);
      enqueue({
        id: req.id,
        text: req.text,
        source: "stdio",
        reply: (text) => process.stdout.write(JSON.stringify({ id: req.id, text }) + "\n"),
      });
    } catch {
      // ignore malformed line
    }
  });
  rl.on("close", () => process.exit(0));
}

if (process.argv.includes("--daemon")) {
  const entry = new URL(import.meta.url).pathname;
  import("./server.js").then((m) => m.daemonMain(entry));
} else {
  stdioMain();
}

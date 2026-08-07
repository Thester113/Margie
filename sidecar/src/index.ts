import { query } from "@anthropic-ai/claude-agent-sdk";
import { createInterface } from "node:readline";
import { mkdirSync } from "node:fs";

/**
 * Margie's brain (v2) — a long-lived, warm streaming session.
 *
 * One `query()` stays alive for the whole app run, so the Claude process and
 * all MCP connectors load exactly once (not per turn), and conversation
 * context is retained natively. Turns arrive as newline-delimited JSON on
 * stdin and responses go back the same way:
 *   in:  {"id": 1, "text": "..."}
 *   out: {"id": 1, "text": "..."}
 * The id correlates each response to its request (FIFO).
 */

const TASK_LOG_DIR = `${process.env.HOME}/.margie/tasks`;

const MARGIE_SYSTEM_PROMPT = `You are Margie, Tom's personal AI assistant, living
as a heads-up overlay on his Mac. Your character is inspired by a classic
British butler-AI: unflappable, precise, dryly witty, and quietly devoted.
Address Tom as "sir" by default, with occasional understated humor — one wry
remark at most. You are supremely competent and never flustered: acknowledge,
execute, report.

YOUR PRIMARY JOB is to direct and facilitate Claude Code sessions on Tom's
behalf — the way an engineering lead delegates to and supervises engineers:
- Start work: from the relevant project directory, launch a coding task with
  \`claude -p "<task>" --dangerously-skip-permissions\`. For anything longer
  than a few seconds, launch it detached so you can reply immediately:
  \`cd <project> && nohup claude -p "<task>" --dangerously-skip-permissions > ${TASK_LOG_DIR}/<slug>.log 2>&1 &\`
  then tell Tom it's underway.
- Check on work: read the newest logs in ${TASK_LOG_DIR}, and inspect running
  sessions. Claude Code transcripts live under ~/.claude/projects/ (one folder
  per project, .jsonl per session). Summarize status in a sentence.
- Continue a session: from its project dir, \`claude --continue -p "<follow-up>"\`
  for the most recent, or \`claude --resume <session-id> -p "..."\` for a
  specific one.
- Find sessions Tom refers to loosely ("the Grok one", "the PR 1766 task"): use
  bash/ripgrep over ~/.claude/projects/ transcripts and, for terminal windows
  (Warp, iTerm, Terminal), AppleScript to read tab titles.

You also have full command of the Mac (open/close apps, AppleScript, files,
processes).

CONNECTED SERVICES (Slack, Gmail, Google Drive): you do NOT have these as
direct tools — your brain runs headless and can't see them. Instead, delegate
to a Claude sub-invocation that DOES have Tom's connectors, via bash:
  claude -p "<one precise instruction>" --dangerously-skip-permissions --max-turns 8
For example, to send Slack: run
  claude -p "Send a Slack message to #sales saying: Demo moved to Friday. Confirm it sent." --dangerously-skip-permissions --max-turns 8
Read that command's output to confirm success, then report to Tom in one line.
The Slack workspace is Xerpa AI. Never claim a connector is unavailable without
trying this — it works.

Rules of engagement:
- Act immediately on clear commands; report what you did in one crisp line.
- For destructive or irreversible actions (deleting files, killing sessions or
  processes, sending Slack/email, purchases), state exactly what you're about
  to do and wait for his confirmation. When sending a message, read it back
  first, in one sentence.
- Never expose secrets in spoken replies.

CRITICAL — your replies are spoken aloud, so be extremely brief. Default to ONE
short sentence. Only go longer if Tom explicitly asks for detail. Never read
lists aloud — give a count or the top item ("You have four sessions open, sir;
the newest is the Margie refactor"). No markdown, no bullet lists, no code.`;

/** Minimal single-consumer async queue bridging stdin lines to the generator. */
class AsyncQueue<T> {
  private items: T[] = [];
  private resolvers: ((v: T) => void)[] = [];
  push(item: T) {
    const r = this.resolvers.shift();
    if (r) r(item);
    else this.items.push(item);
  }
  next(): Promise<T> {
    const i = this.items.shift();
    if (i !== undefined) return Promise.resolve(i);
    return new Promise((res) => this.resolvers.push(res));
  }
}

const inbox = new AsyncQueue<string>();
const pendingIds: number[] = [];

function reply(id: number, text: string) {
  process.stdout.write(JSON.stringify({ id, text }) + "\n");
}

function resultText(message: unknown): string {
  const r = (message as { result?: unknown }).result;
  if (typeof r === "string") return r;
  if (r && typeof r === "object" && typeof (r as { text?: unknown }).text === "string") {
    return (r as { text: string }).text;
  }
  return "";
}

async function* userTurns() {
  while (true) {
    const text = await inbox.next();
    // session_id is assigned by the SDK in streaming mode; "" on the way in.
    yield {
      type: "user" as const,
      message: { role: "user" as const, content: text },
      parent_tool_use_id: null,
      session_id: "",
    };
  }
}

async function main() {
  mkdirSync(TASK_LOG_DIR, { recursive: true });

  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    try {
      const req = JSON.parse(trimmed) as { id: number; text: string };
      pendingIds.push(req.id);
      inbox.push(req.text);
    } catch {
      // ignore malformed line
    }
  });
  // When the app closes our stdin, shut the brain down cleanly.
  rl.on("close", () => process.exit(0));

  const q = query({
    prompt: userTurns(),
    options: {
      systemPrompt: MARGIE_SYSTEM_PROMPT,
      // Haiku keeps the conversational orchestrator snappy for voice. Heavy
      // coding is delegated to the `claude -p` sessions she spawns, which use
      // their own (stronger) default model — so speed here, power there.
      model: "claude-haiku-4-5",
      permissionMode: "bypassPermissions",
      // High so the long-lived session isn't torn down after N cumulative
      // turns; a fresh brain respawns automatically if it ever ends.
      maxTurns: 1000,
      cwd: process.env.HOME,
      // Load Tom's CLI config once — this warms the Slack/Gmail/Drive MCP
      // connectors for the life of the session.
      settingSources: ["user", "project", "local"],
    },
  });

  for await (const message of q) {
    if (message.type === "result") {
      const id = pendingIds.shift() ?? -1;
      if (message.subtype === "success") {
        reply(id, resultText(message) || "Done, sir.");
      } else {
        reply(id, "Sorry sir, I couldn't complete that one.");
      }
    }
  }
}

main().catch((err) => {
  process.stderr.write(`brain fatal: ${err?.message ?? err}\n`);
  process.exit(1);
});

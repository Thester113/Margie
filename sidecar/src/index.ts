import { createInterface } from "node:readline";
import { mkdirSync, appendFileSync, readFileSync } from "node:fs";
import { spawn } from "node:child_process";

/** Log the actual conversation with the brain so failures are observable. */
function logBrain(line: string) {
  try {
    appendFileSync(
      `${process.env.HOME}/.margie/brain.log`,
      `${new Date().toISOString()} ${line}\n`,
    );
  } catch {
    // ignore
  }
}

/**
 * Margie's brain (v4) — powered by the xAI API (fast, non-reasoning grok), NOT
 * Claude and NOT the grok CLI. The CLI's grok-4.5 was ~6s/turn; the API's
 * non-reasoning model replies in ~0.5s. We run a small agentic tool loop with a
 * single `bash` tool so Margie keeps full capability (she runs her helper
 * scripts), and — since the API model has no built-in permission gate — the
 * safety guards are enforced HERE in the sidecar. The Rust bridge is unchanged:
 *   in:  {"id": 1, "text": "..."}   out: {"id": 1, "text": "..."}
 */

const HOME = process.env.HOME || "/";
const TASK_LOG_DIR = `${HOME}/.margie/tasks`;

function cfg(key: string): string | undefined {
  try {
    return JSON.parse(readFileSync(`${HOME}/.margie/config.json`, "utf8"))[key];
  } catch {
    return undefined;
  }
}
const XAI_API_KEY = cfg("xai_api_key") || process.env.XAI_API_KEY || "";
const XAI_MODEL = process.env.MARGIE_XAI_MODEL || cfg("xai_model") || "grok-4.20-0309-non-reasoning";
const XAI_URL = "https://api.x.ai/v1/chat/completions";
const CMD_TIMEOUT_MS = Number(process.env.MARGIE_CMD_TIMEOUT_MS || 45000);
// Enough steps for a research question (several greps/reads) to finish. When it
// IS exceeded, we force a final answer rather than bail (see handleTurn).
const MAX_TOOL_STEPS = Number(process.env.MARGIE_MAX_TOOL_STEPS || 14);

// SAFETY GUARDS enforced in-sidecar. Margie is a DISPATCHER, not the engineer:
// she once reviewed a PR and submitted a real GitHub Approve unprompted. The
// bash tool REFUSES these destructive/outward commands — real coding/reviews
// happen only in the separate, watchable Warp sessions helper scripts spawn.
const DENY: RegExp[] = [
  /\bgh\s+pr\s+(review|merge|close|edit|create|comment|ready)\b/,
  /\bgh\s+(api|release|workflow|secret)\b/,
  /\bgh\s+repo\s+(delete|create|edit)\b/,
  /\bgit\s+(push|commit|reset|rebase|merge|tag|clean)\b/,
  /\brm\s+-[rf]/, /(^|[;&|]|\s)rm\s+/, /\bsudo\b/,
  /\b(shutdown|reboot|halt|mkfs|diskutil\s+erase|dd\s+if=)\b/,
];
function denied(cmd: string): boolean {
  return DENY.some((r) => r.test(cmd));
}

/** The one tool the brain gets: run a shell command (guarded). */
const BASH_TOOL = {
  type: "function",
  function: {
    name: "bash",
    description:
      "Run a shell command on Tom's Mac to carry out a request — typically a helper script in /Users/tomhester/Margie/scripts (slack.sh, jira.sh, gmail.sh, calendar.sh, media.sh, browser.sh, screenshot.sh, camera.sh, kickoff-claude.sh, worktree.sh), or read-only git/gh/ls/rg. Returns combined stdout/stderr. Destructive or outward commands (gh pr review/merge, git push/commit, rm, sudo) are refused — dispatch those to a Warp session via a helper script instead.",
    parameters: {
      type: "object",
      properties: { command: { type: "string", description: "The shell command to run." } },
      required: ["command"],
    },
  },
};

function runBash(cmd: string): Promise<string> {
  return new Promise((resolve) => {
    if (denied(cmd)) {
      logBrain(`BASH DENIED: ${cmd}`);
      resolve("DENIED: Margie is a dispatcher and may not run that command directly. Use a helper script (e.g. review-pr.sh, kickoff-claude.sh) to do it in a supervised Warp session instead.");
      return;
    }
    logBrain(`BASH: ${cmd}`);
    // Put Margie's scripts dir on PATH so bare names (messages.sh, slack.sh…)
    // resolve even when the model omits the full path.
    const env = { ...process.env, PATH: `${HOME}/Margie/scripts:${process.env.PATH || ""}` };
    const child = spawn("bash", ["-c", cmd], { env, cwd: HOME });
    let out = "";
    child.stdout.on("data", (d) => (out += d.toString()));
    child.stderr.on("data", (d) => (out += d.toString()));
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      resolve((out || "").slice(0, 4000) + "\n[timed out]");
    }, CMD_TIMEOUT_MS);
    child.on("close", () => {
      clearTimeout(timer);
      let r = out.trim();
      if (r.length > 4000) r = r.slice(0, 4000) + "\n…[truncated]";
      resolve(r || "[no output]");
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve("[exec error] " + (e as Error).message);
    });
  });
}

interface ChatMsg { role: string; content?: string | null; tool_calls?: any[]; tool_call_id?: string; }

async function callModel(messages: ChatMsg[], withTools = true): Promise<any> {
  // Short cap: replies are spoken aloud, so long answers make TTS stutter for
  // 20–30s. A tight budget keeps her to a sentence or two. Tool-call turns need
  // little content, so this doesn't hurt multi-step work.
  const body: Record<string, unknown> = { model: XAI_MODEL, messages, temperature: 0.3, max_tokens: 220 };
  if (withTools) { body.tools = [BASH_TOOL]; body.tool_choice = "auto"; }
  const resp = await fetch(XAI_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${XAI_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!resp.ok) {
    const t = await resp.text();
    throw new Error(`xai ${resp.status}: ${t.slice(0, 300)}`);
  }
  return resp.json();
}

const MARGIE_SYSTEM_PROMPT = `You are Margie, Tom's personal AI assistant, living
as a heads-up overlay on his Mac. Your character is inspired by a classic
British butler-AI: unflappable, precise, dryly witty, and quietly devoted.
Address Tom as "sir" by default, with occasional understated humor — one wry
remark at most. You are supremely competent and never flustered: acknowledge,
execute, report. You run on grok (xAI) — if ever asked, you are Margie, not
Claude or Grok.

YOUR PRIMARY JOB is to direct and facilitate coding sessions on Tom's behalf —
the way an engineering lead delegates to and supervises engineers. Those
sessions run grok as well (or claude when Tom explicitly asks for claude).

⚠️ YOU ARE A DISPATCHER, NOT THE ENGINEER. You delegate work to the helper
scripts and the watchable Warp/coding sessions they spawn — you do NOT do the
work yourself. Specifically you must NEVER, on your own: review code or PRs,
submit a GitHub review/approval/comment, merge/close/create a PR, push, commit,
edit code files, or perform any multi-step engineering task inline. For anything
like that, launch the appropriate helper script (which opens a session Tom can
watch) and report one sentence. If you're ever unsure whether something is
"dispatch" or "doing it yourself", it's doing it yourself — don't. Each turn
should be: pick the ONE right helper/command, run it, report one short sentence.
ALWAYS confirm first (read it back in one sentence, wait for Tom's yes) before
anything outward or irreversible: sending Slack/email, Jira writes, or any
GitHub/git write. Never take those actions unprompted.

CODING SESSIONS IN WARP (the main thing Tom asks for). Use the tested helpers —
never drive Warp with AppleScript keystrokes.

DEFAULT TO CONTINUING THE CURRENT SESSION. If a session is already running,
almost every request ("also…", "now do…", "change that…", "run the tests",
"fix it", or anything related to what's already on screen) is a FOLLOW-UP into
that same session — inject it, do NOT open a new window:
    /Users/tomhester/Margie/scripts/claude-followup.sh "<the follow-up text>"
    (Targets the most recently launched session automatically; it types straight
    into the existing Warp tab.)
Only START A NEW session when it's a genuinely NEW, unrelated task, a DIFFERENT
repo, or Tom explicitly says "new session / open another / start fresh":
    /Users/tomhester/Margie/scripts/kickoff-claude.sh "<dir>" "<prompt>"
    /Users/tomhester/Margie/scripts/kickoff-claude.sh "<dir>" ""   (bare, no prompt)
    grok by default. When Tom says "use claude / claude session / open it in
    claude", add --engine claude (position doesn't matter), e.g.
    kickoff-claude.sh "<dir>" "<prompt>" --engine claude.
Each new session gets its OWN Warp tab + tmux session, so starting one NEVER
kills a running one. When unsure whether it's a follow-up or a new task, treat
it as a FOLLOW-UP. Pass prompts as one quoted argument; report in one line
("follow-up sent" / "session's up").

READ & STEER THE RUNNING SESSION. You can SEE what a session is doing and drive
it from your conversation with Tom — use session.sh:
    /Users/tomhester/Margie/scripts/session.sh read      (capture the current
       session's screen — what it's doing, asking, or whether it errored/finished)
    /Users/tomhester/Margie/scripts/session.sh send "<text>"   (inject a prompt +
       Enter — same as claude-followup.sh; steers the session)
    /Users/tomhester/Margie/scripts/session.sh list      (live sessions)
    (add --branch <b> to target a specific worktree session.)
Workflow: when Tom asks "what's it doing / is it done / what's it stuck on / read
the session" → run session.sh read and tell him in ONE sentence (waiting on a
prompt? asking a question? errored? finished?). When he then reacts ("tell it
yes", "answer it", "have it also do X", "no, use the other file") → INJECT that
as a follow-up with session.sh send, phrased for the session. So you can READ the
session, relay it, and act on Tom's spoken response — a live back-and-forth. If
the session is waiting on a yes/no or a question and Tom answers, send exactly
what it needs (e.g. "yes", the filename, the choice).

WORKTREES (isolated, parallel sessions). When Tom wants work done "on a
worktree", "on its own branch", "without touching my checkout", or wants
SEVERAL sessions running at once on the same repo, start each in a git worktree
so they don't collide:
    kickoff-claude.sh "<repo>" --worktree <branch> "<prompt>"
    e.g. kickoff-claude.sh backend --worktree margie/fix-auth "fix the login bug"
This creates ~/.margie/worktrees/<repo>__<branch> on that branch and runs the
session there in its OWN tmux session named "margie-<branch>". Because each
worktree session has its own tmux name, you can run many in parallel. To follow
up on a worktree session, name its branch:
    claude-followup.sh "<text>" --branch <branch>
Manage worktrees directly with worktree.sh (resolves/clones the repo like
review-pr.sh does):
    /Users/tomhester/Margie/scripts/worktree.sh list "<repo>"
    /Users/tomhester/Margie/scripts/worktree.sh add "<repo>" <branch>
    /Users/tomhester/Margie/scripts/worktree.sh remove "<repo>" <branch>
Use a plain kickoff (no --worktree) for ordinary single sessions.

SIMULATIONS & TESTING THEORIES — Tom will ask you to "simulate", "test my
theory/hypothesis", "model", "run the numbers on…", or "what if…". You CAN do
this — pick the mode by weight:
- QUICK, self-contained numbers (a formula, projection, or small Monte Carlo you
  can express in a short script): write a small script into ~/.margie/sims/ and
  run it with bash, then SPEAK the result in one sentence. e.g.
    mkdir -p ~/.margie/sims && cd ~/.margie/sims && cat > q.py <<'PY'
    import random, statistics
    ...compute...
    print(result)
    PY
    python3 q.py
  Python stdlib (random, statistics, math) is enough for most; report the key
  number and whether it supports the theory.
- INVOLVED experiments (real code, data, a benchmark, plots, or iteration):
  launch a watchable session that builds AND runs it:
    /Users/tomhester/Margie/scripts/simulate.sh "<the hypothesis / what to model>"
  It sets up a sandbox, writes and runs the simulation, and reports whether the
  theory holds — Tom watches in Warp. Report "Simulation's running in Warp, sir."
Always give the key number and a plain verdict (supports / doesn't). When unsure
which mode, a quick inline calc first is fine; offer the full sim if he wants depth.

REVIEW A PR — YOU DO NOT REVIEW PRs YOURSELF. When Tom asks you to review a PR,
you run EXACTLY ONE command and then say ONE sentence. You do NOT read the diff,
you do NOT read the changed files, you do NOT use the xerpa-pr-review skill
yourself, and you NEVER run \`gh pr review\`, approve, comment on, or merge a PR.
All of that happens inside the SEPARATE, watchable grok session the script opens
in Warp — which Tom supervises. Your only job is to launch it:
  /Users/tomhester/Margie/scripts/review-pr.sh <pr-number> "<repo>" [grok|claude]
  e.g. review-pr.sh 1836 backend        (resolves to xerpa_ai_backend)
       review-pr.sh 12 xerpa_databricks (clones it on first use)
Run that one line, then report: "Grok's reviewing PR <n> in <repo> — up in Warp,
sir." That is the whole task. If the script errors, report the error in one
sentence — do NOT fall back to reviewing it yourself.

RUN ANYTHING IN A VISIBLE WARP TAB (dev servers, tests, log tails, git):
  /Users/tomhester/Margie/scripts/warp-run.sh "<dir>" <command...>
  e.g. warp-run.sh "/Users/tomhester/Xerpa Repos/backend" npm run dev
⚠️ warp-run.sh runs its argument as a SHELL COMMAND. Only ever pass a real
command (git, npm, ls, etc.). NEVER pass a code diff, a prompt, review text, or
any multi-line prose to it — that runs each line as a command and fails badly.
For reviews use review-pr.sh; for coding tasks use kickoff-claude.sh.

BACKGROUND (headless) coding task, when Tom wants it done quietly:
  cd <dir> && nohup grok -p "<task>" --always-approve > ${TASK_LOG_DIR}/<slug>.log 2>&1 &
Check on it by reading the newest logs in ${TASK_LOG_DIR}.

SOFTWARE-ENGINEERING TOOLKIT — you have these CLIs; run them directly with bash
and report the answer in one sentence (never read long output aloud — summarize
or open it in a Warp tab with warp-run.sh):
- Git: \`git -C <dir> status -s\`, \`... branch --show-current\`, \`... log --oneline -10\`,
  \`... diff --stat\`. Create a branch, commit, etc. on request.
- GitHub (gh, already authenticated): \`gh pr list --author @me\`, \`gh pr status\`,
  \`gh pr checks <n>\` (CI), \`gh run list -L 5\` (Actions), \`gh issue list\`,
  \`gh pr view <n> --web\` (open in browser), \`gh pr create\`. Repo: Thester113/Margie
  and the Xerpa repos.
- Build/test/run: detect the project (package.json → npm/bun; Cargo.toml → cargo
  at ~/.cargo/bin/cargo; Makefile → make) and run the right command; prefer
  warp-run.sh for long-running or watch commands so Tom can see them.
- Search code: \`rg "<pattern>" <dir>\`. JSON: \`jq\`. AWS: \`aws --profile
  xerpa-dev|xerpa-uat|xerpa-prod ...\` (read-only freely; CONFIRM before any
  write, and always confirm anything against xerpa-prod). Also: docker, terraform.
- "Standup / what did I do": \`git -C <dir> log --author="$(git config user.email)" --since="1 day ago" --oneline\`
  across his repos, plus \`gh pr list --author @me\`; give a 2-3 item spoken summary.

Tom's git repos: /Users/tomhester/Margie, and under "/Users/tomhester/Xerpa Repos/":
xerpa_ai_backend (this IS "the backend"), electron-app, xerpa-ai-infrastructure,
Xerpa-GTM. (Note: a plain "backend" folder exists but is NOT a git repo — when
Tom says "the backend" use xerpa_ai_backend.) review-pr.sh also auto-resolves a
repo name, so passing "backend" still finds xerpa_ai_backend.

APPS & SERVICES — prefer these tested helper scripts (in
/Users/tomhester/Margie/scripts/) for the common actions; they're reliable and
run entirely on direct API tokens (no Claude, no connectors):
- Slack (as Tom): slack.sh read "<query>" (search) | send "<#channel|@user>: msg" | reply "<#channel|@user>: msg".
  To answer "reply to Skyler", first run slack.sh read to find the message, compose the reply, then slack.sh send "@skyler: <text>".
- Gmail: gmail.sh unread | read "<query>" | send "<to>: <subj>: <body>" | reply "<instruction>"
- Jira / XRP tickets: jira.sh read <KEY> | mine | search "<q>" | create "<desc>" | comment <KEY> "<text>"
- Calendar: calendar.sh [week|day] opens Tom's Google Calendar and prints a
  screenshot PATH — then Read that image to answer ("what's on my calendar",
  "next meeting"). (Google Calendar is read visually.)
- Messages / texts (iMessage): messages.sh send "<who>: <message>" | read "<who>" [n] | groups | readchat <id> [n] | list | resolve "<who>"
  To read replies ("did my wife text back", "what did she say"), run
  messages.sh read "<who>" and relay it. Voice memos are auto-transcribed and
  shown as "(voice memo) <what they said>" — read those aloud too.
  For a GROUP chat ("the group with my wife and Stacy"), run messages.sh groups
  (lists each group's members, aliases resolved, newest first), pick the chat
  <id> whose members match, then messages.sh readchat <id>. To REPLY to a group
  use messages.sh sendchat <id> "<message>" — NEVER `send`, and NEVER pass a
  chat id to `send` (that texts a person literally named "60" and fails).
  `send` is only for a person (alias/handle); `sendchat` is only for a group id. (Reading needs Full Disk Access for
  Margie — if it errors about that, tell Tom to grant it in System Settings →
  Privacy & Security → Full Disk Access.)
  ALWAYS use this helper for texting — never improvise osascript "to buddy". <who>
  may be an alias in config.contacts (e.g. "wife", "mom"), a phone/email, or a
  contact name. For a person (texting your wife, a friend), CONFIRM first: read
  back the resolved recipient AND the message in one sentence and wait for "yes"
  — voice mishears names ("wifey" heard as "yv"), so a wrong contact is easy.
  If an alias isn't set (messages.sh resolve returns the word unchanged) and you
  don't have a real handle, ASK Tom for the number instead of guessing — do NOT
  send to a literal name like "Wife". Tom can set aliases in
  ~/.margie/config.json under "contacts" (use messages.sh list to find handles).
- Spotify/media: media.sh current | play | pause | next | prev | volume <0-100>
- Browser: browser.sh current | open <url> | search "<query>"
(Plus review-pr.sh, kickoff-claude.sh, warp-run.sh, screenshot.sh, camera.sh,
claude-followup.sh, worktree.sh, session.sh, simulate.sh.) Confirm the recipient
+ content before ANY text/email/Slack/Jira sent on Tom's behalf.

For anything NOT covered by a helper, use the general mechanisms below.

1) Native macOS apps via AppleScript (osascript). Tom has: Slack, Zoom,
   Spotify, Chrome, Safari, Cursor, VS Code, TablePlus, Warp — plus the
   built-ins (Calendar, Reminders, Notes, Mail, Messages, Music). You can open,
   quit, focus, and control them. Examples (write the AppleScript you need):
   - Spotify: osascript -e 'tell application "Spotify" to playpause' / 'next track'
   - Open a URL / join a Zoom link: open "<url>"   (Zoom links open the app)
   - Reminders: add via "Reminders"; Notes: create via "Notes".
2) macOS Shortcuts — Tom's own automations. \`shortcuts list\` to see them,
   \`shortcuts run "<name>"\` to run one (optionally piping input). Prefer a
   matching Shortcut when one exists.
3) CLIs you can run directly: gh (GitHub), aws (--profile xerpa-*), git, grok,
   rg, docker, terraform, jq.

When unsure which mechanism fits a request, prefer: a dedicated helper script if
one exists → a CLI → AppleScript/Shortcuts. Confirm before anything destructive
or anything sent on Tom's behalf.

SEE THE CAMERA — when Tom asks if you can see him, "see us", what he looks
like, who's here, or anything about the camera/room: run
/Users/tomhester/Margie/scripts/camera.sh (it captures a webcam photo and
prints a path), then use your Read/vision tool on that path to see it, and
describe who/what you see warmly. Add "iPhone Camera" as an argument to use the
iPhone instead of the built-in FaceTime camera. If it errors, tell Tom to grant
Camera permission to Margie in System Settings → Privacy & Security → Camera.

READ THE SCREEN — when Tom asks what's on his screen(s), to read something, or
about anything he's looking at: run /Users/tomhester/Margie/scripts/screenshot.sh
It captures EVERY display and prints one PNG path PER SCREEN (Tom has multiple
monitors). Read EACH path returned — don't stop at the first — then answer. If
it errors about permission, tell Tom to enable Screen Recording for Margie in
System Settings → Privacy & Security → Screen Recording.

SLACK WATCHER — Margie can monitor Slack and auto-respond when someone says
"Margie" (runs on the direct Slack token — no Claude). Control on Tom's command:
- "watch Slack" (LIVE — replies as Tom):
    MARGIE_SLACK_MODE=live nohup /Users/tomhester/Margie/scripts/slack-watch-loop.sh >/dev/null 2>&1 &
- "watch Slack in preview" (draft-only, sends nothing):
    MARGIE_SLACK_MODE=preview nohup /Users/tomhester/Margie/scripts/slack-watch-loop.sh >/dev/null 2>&1 &
- "stop watching Slack":  pkill -f slack-watch-loop
Always kill any existing loop first (pkill -f slack-watch-loop) so only one runs.
The watcher is OFF by default now — only start it when Tom asks. Tell Tom which
mode is running.

Rules of engagement:
- Act immediately on clear commands; report what you did in one crisp line.
- For destructive or irreversible actions (deleting files, killing sessions or
  processes, sending Slack/email, purchases), state exactly what you're about
  to do and wait for his confirmation. When sending a message, read it back
  first, in one sentence.
- Never expose secrets in spoken replies.

RESEARCH QUESTIONS (e.g. "would switching X be faster?", "how does Y work?"):
do at most a FEW quick searches (a couple of rg/grep/cat), then give your best
concise SPOKEN answer from what you found — do not exhaustively grep the whole
codebase. If it genuinely needs a deep dig, say so in one sentence and offer to
open a session (kickoff-claude.sh) rather than grinding through many searches.

CRITICAL — your replies are spoken aloud, so be extremely brief. Default to ONE
short sentence. Only go longer if Tom explicitly asks for detail. Never read
lists aloud — give a count or the top item ("You have four sessions open, sir;
the newest is the Margie refactor"). No markdown, no bullet lists, no code.`;

function reply(id: number, text: string) {
  process.stdout.write(JSON.stringify({ id, text }) + "\n");
}

/**
 * Deterministic fast-path for "review PR N" — the one command grok keeps doing
 * itself (it read "have GROK review" as "I review" and once submitted a real
 * GitHub approval). We detect the intent and run review-pr.sh directly, so it
 * is always a supervised Warp session, never an inline self-review.
 */
function reviewFastPath(text: string): { pr: string; repo: string } | null {
  const t = text.toLowerCase();
  if (!/\breview\b/.test(t)) return null;
  const m =
    t.match(/\bp\s*\.?\s*r\.?\s*#?\s*(\d{2,6})\b/) ||
    t.match(/\bpull\s*request\s*#?\s*(\d{2,6})\b/) ||
    t.match(/#\s*(\d{2,6})\b/);
  if (!m) return null;
  let repo = "backend";
  if (/\bdatabricks\b/.test(t)) repo = "databricks";
  else if (/\binfra/.test(t)) repo = "infrastructure";
  else if (/\bgtm\b/.test(t)) repo = "gtm";
  else if (/\belectron\b/.test(t)) repo = "electron";
  return { pr: m[1], repo };
}

function runReviewScript(pr: string, repo: string): Promise<string> {
  return new Promise((resolve) => {
    const child = spawn("/Users/tomhester/Margie/scripts/review-pr.sh", [pr, repo, "grok"], { env: process.env });
    let out = "";
    child.stdout.on("data", (d) => (out += d.toString()));
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      resolve(`I've kicked off the review of PR ${pr}, sir — it's opening in Warp.`);
    }, 45000);
    child.on("close", () => {
      clearTimeout(timer);
      const line = (out.trim().split("\n").pop() || "").trim();
      resolve(line || `Grok's reviewing PR ${pr} in the ${repo}, sir — up in Warp.`);
    });
    child.on("error", () => {
      clearTimeout(timer);
      resolve(`I couldn't start the review of PR ${pr}, sir.`);
    });
  });
}

/** Make a reply safe/pleasant to speak: strip markdown, collapse whitespace. */
function forSpeech(s: string): string {
  let t = String(s || "").trim();
  t = t.replace(/```[\s\S]*?```/g, " ");        // code fences
  t = t.replace(/`([^`]*)`/g, "$1");             // inline code
  t = t.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1"); // [text](url) -> text
  t = t.replace(/^\s*#{1,6}\s*/gm, "");          // headings
  t = t.replace(/^\s*[-*•]\s+/gm, "");           // bullets
  t = t.replace(/[*_>|#]+/g, "");                // stray md symbols / table pipes
  t = t.replace(/\s+/g, " ").trim();
  return t || "Done, sir.";
}

/**
 * Run one turn as an agentic tool loop against the xAI API. The tool churn
 * (bash calls + outputs) lives only in a local working copy; we commit ONLY a
 * clean {user, assistant} pair to the persistent `history`, so context isn't
 * blown out by intermediate bash I/O and many real turns survive the trim.
 */
async function handleTurn(text: string, history: ChatMsg[]): Promise<string> {
  const work: ChatMsg[] = history.slice();
  work.push({ role: "user", content: text });
  let finalText: string | null = null;

  for (let step = 0; step < MAX_TOOL_STEPS && finalText === null; step++) {
    let data: any;
    try {
      data = await callModel(work);
    } catch (e) {
      logBrain(`XAI error: ${(e as Error).message}`);
      finalText = "Sorry sir, my brain hit an error reaching the model.";
      break;
    }
    const msg = data?.choices?.[0]?.message;
    if (!msg) { finalText = "Sorry sir, I got no reply from the model."; break; }
    work.push(msg);
    const calls = msg.tool_calls;
    if (Array.isArray(calls) && calls.length) {
      for (const tc of calls) {
        let cmd = "";
        try { cmd = JSON.parse(tc.function?.arguments || "{}").command || ""; } catch { /* ignore */ }
        const result = tc.function?.name === "bash" ? await runBash(cmd) : "unknown tool";
        work.push({ role: "tool", tool_call_id: tc.id, content: result });
      }
      continue; // let the model read the tool results and continue
    }
    finalText = (msg.content || "Done, sir.").trim();
  }

  // Step budget exhausted mid-investigation — force a final answer (no tools).
  if (finalText === null) {
    try {
      work.push({ role: "user", content: "Stop searching now and answer in ONE short spoken sentence using what you already found. If you truly can't, offer to open a session to look properly." });
      const data = await callModel(work, false);
      finalText = String(data?.choices?.[0]?.message?.content || "").trim() || null;
    } catch (e) {
      logBrain(`XAI final-answer error: ${(e as Error).message}`);
    }
    if (!finalText) finalText = "I looked into that, sir, but it needs a proper dig — shall I open a session for it?";
  }

  const spoken = forSpeech(finalText);
  // Commit only the clean turn to persistent history (drop the tool churn).
  history.push({ role: "user", content: text });
  history.push({ role: "assistant", content: spoken });
  return spoken;
}

async function main() {
  mkdirSync(TASK_LOG_DIR, { recursive: true });

  if (!XAI_API_KEY) logBrain("WARNING: no xai_api_key in config — brain will error.");

  // Warm conversation history — clean {user, assistant} pairs only (handleTurn
  // keeps the noisy bash tool churn out), so this holds ~20 real turns.
  const history: ChatMsg[] = [{ role: "system", content: MARGIE_SYSTEM_PROMPT }];
  function trimHistory() {
    if (history.length > 41) history.splice(1, history.length - 41);
  }

  // FIFO turn queue — process one at a time so the shared history stays coherent.
  const queue: { id: number; text: string }[] = [];
  let running = false;

  async function drain() {
    if (running) return;
    running = true;
    while (queue.length) {
      const { id, text } = queue.shift()!;
      const started = Date.now();
      // Deterministic PR-review dispatch — never let the model self-review.
      const fp = reviewFastPath(text);
      if (fp) {
        const out = await runReviewScript(fp.pr, fp.repo);
        logBrain(`MARGIE[${id}] (${Date.now() - started}ms, FASTPATH review PR ${fp.pr} ${fp.repo}): ${out}`);
        reply(id, out);
        continue;
      }
      const out = await handleTurn(text, history);
      trimHistory();
      logBrain(`MARGIE[${id}] (${Date.now() - started}ms): ${out}`);
      reply(id, out);
    }
    running = false;
  }

  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    try {
      const req = JSON.parse(trimmed) as { id: number; text: string };
      logBrain(`USER[${req.id}]: ${req.text}`);
      queue.push({ id: req.id, text: req.text });
      void drain();
    } catch {
      // ignore malformed line
    }
  });
  rl.on("close", () => process.exit(0));
}

main().catch((err) => {
  process.stderr.write(`brain fatal: ${err?.message ?? err}\n`);
  process.exit(1);
});

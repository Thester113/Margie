import { mkdirSync, appendFileSync, readFileSync, readdirSync, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { query, tool, createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

/** Log the actual conversation with the brain so failures are observable. */
export function logBrain(line: string) {
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
 * Margie's brain (v4) — the conversational dispatcher. It runs on the xAI chat
 * API (fast, non-reasoning grok: ~0.5s/turn, which matters for a voice loop)
 * and dispatches all real work to Claude Code: interactive sessions in Warp
 * (kickoff-claude.sh / session.sh), headless background tasks (claude-task.sh),
 * and MR/PR reviews (review-pr.sh). It has a single `bash` tool for running the
 * helper scripts; since the API model has no built-in permission gate, the
 * safety guards are enforced HERE in the sidecar. The Rust bridge is unchanged:
 *   in:  {"id": 1, "text": "..."}   out: {"id": 1, "text": "..."}
 */

const HOME = process.env.HOME || "/";
// Margie's checkout. MARGIE_HOME overrides; otherwise derive it from this file
// (sidecar/dist/index.js → repo root) so nothing depends on a hardcoded user path.
const MARGIE_HOME =
  process.env.MARGIE_HOME || resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SCRIPTS = `${MARGIE_HOME}/scripts`;
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
// Which CLI coding sessions run in (kickoff-claude.sh --engine). Claude Code
// unless config.json sets "engine" or MARGIE_ENGINE is exported.
const ENGINE = (process.env.MARGIE_ENGINE || cfg("engine") || "claude").toLowerCase();
const ENGINE_NAME = ENGINE.startsWith("grok") ? "Grok" : "Claude Code";
// Where Tom's repos live (resolve-repo.sh clones there too), which forge they're
// on (gitlab | github — picks the CLI, vocabulary and guards), and the GitLab
// group / GitHub org bare repo names resolve against. Company-agnostic: all config.
const REPOS_DIR = (process.env.MARGIE_REPOS_DIR || cfg("repos_dir") || `${HOME}/repos`).replace(/^~/, HOME);
const FORGE = (process.env.MARGIE_FORGE || cfg("forge") || "github").toLowerCase();
const GL = FORGE === "gitlab";
const SITE = GL ? "GitLab" : "GitHub";           // "submit a GitLab review"
const FORGE_CLI = GL ? "glab" : "gh";
const NOUN = GL ? "MR" : "PR";                   // merge request vs pull request
const REF = GL ? "!" : "#";
const ORG = process.env.MARGIE_ORG || cfg("org") || "";
const DEFAULT_REPO = cfg("default_repo") || "";
/** Names of the git repos under REPOS_DIR, so the prompt lists what actually exists. */
function listRepos(): string[] {
  try {
    return readdirSync(REPOS_DIR).filter((n) => existsSync(`${REPOS_DIR}/${n}/.git`)).sort();
  } catch {
    return [];
  }
}
// Which model thinks for Margie, per channel. Voice needs grok's ~0.7s turns;
// the terminal and Slack get Claude on Tom's plan (via the Agent SDK — no API key).
const BRAIN_VOICE = (cfg("brain_voice_backend") || "xai").toLowerCase();      // app
const BRAIN_TEXT = (cfg("brain_backend") || "claude").toLowerCase();          // cli, slack, stdio
const BRAIN_CLAUDE_MODEL = cfg("brain_claude_model") || "sonnet";
const CMD_TIMEOUT_MS = Number(process.env.MARGIE_CMD_TIMEOUT_MS || 45000);
// Enough steps for a research question (several greps/reads) to finish. When it
// IS exceeded, we force a final answer rather than bail (see handleTurn).
const MAX_TOOL_STEPS = Number(process.env.MARGIE_MAX_TOOL_STEPS || 14);

// SAFETY GUARDS enforced in-sidecar. Margie is a DISPATCHER, not the engineer:
// she once reviewed a PR and submitted a real forge Approve unprompted. The
// bash tool REFUSES these destructive/outward commands — real coding/reviews
// happen only in the separate, watchable Warp sessions helper scripts spawn.
const DENY: RegExp[] = [
  /\bgh\s+pr\s+(review|merge|close|edit|create|comment|ready)\b/,
  /\bgh\s+(api|release|workflow|secret)\b/,
  /\bgh\s+repo\s+(delete|create|edit)\b/,
  /\bglab\s+mr\s+(approve|revoke|merge|close|reopen|update|create|note|rebase|delete|todo|subscribe)\b/,
  /\bglab\s+(api|release|variable|deploy-key|ssh-key)\b/,
  /\bglab\s+repo\s+(delete|create|archive|transfer|mirror)\b/,
  /\bgit\s+(push|commit|reset|rebase|merge|tag|clean)\b/,
  /\brm\s+-[rf]/, /(^|[;&|]|\s)rm\s+/, /\bsudo\b/,
  /\b(shutdown|reboot|halt|mkfs|diskutil\s+erase|dd\s+if=)\b/,
];
function denied(cmd: string): boolean {
  return DENY.some((r) => r.test(cmd));
}

// CONFIRM-FIRST GATE, enforced deterministically. Anything that sends on Tom's
// behalf is HELD on first request: the model must read it back, and only a short
// affirmative from Tom on the very next turn executes the held command verbatim.
// (The prompt already says "confirm first"; the small model skipped it for a
// self-DM, so — like DENY — the rule lives here, not in the model's discretion.)
const OUTWARD: RegExp[] = [
  /\bslack\.sh\s+(send|reply|dm)\b/,
  /\bgmail\.sh\s+(send|reply)\b/,
  /\bmessages\.sh\s+(send|sendchat)\b/,
  /\bjira\.sh\s+(create|comment)\b/,
  /\bnotion\.sh\s+(create|append)\b/,
  /\bnotion\.sh\s+(ticket\s+(create|status|comment|append)|testcase\s+(add|status)|page\s+(create|append))\b/,
  /\bdispatch\.sh\s+(file|go|close)\b/,
  /\bagent-messages\.sh\s+(send|reply|ack)\b/,
  /\bmr\.sh\s+(create|update)\b/,
  /\bstandup\.sh\s+post\b/,
];
const PENDING_TTL_MS = 3 * 60 * 1000;
let pending: { cmd: string; at: number } | null = null;
// Progress sink for the turn currently draining (daemon clients see tool/held
// events; stdio and the app ignore them). Set by drain(), used by runBash*.
let currentEmit: ((event: string, text: string) => void) | null = null;
function outward(cmd: string): boolean {
  return OUTWARD.some((r) => r.test(cmd));
}
/** A short, clear refusal of the held command — handled deterministically, no model call. */
function isNegative(text: string): boolean {
  const t = text.trim().toLowerCase().replace(/[.!,]+$/, "");
  if (t.split(/\s+/).length > 7) return false;
  return /^(no|nope|nah|don'?t|do not|cancel|cancel (that|it)|never ?mind|stop|abort|hold off|not now|scratch that|forget it)\b/.test(t);
}
function isAffirmative(text: string): boolean {
  const t = text.trim().toLowerCase().replace(/[.!,]+$/, "");
  if (t.split(/\s+/).length > 6) return false;
  return /^(yes|yep|yeah|yup|ok|okay|sure|confirm(ed)?|affirmative|go ahead|send it|do it|proceed|please do|that's right|correct)\b/.test(t);
}

/** The one tool the brain gets: run a shell command (guarded). */
const BASH_TOOL = {
  type: "function",
  function: {
    name: "bash",
    description:
      `Run a shell command on Tom's Mac to carry out a request — typically a helper script in ${SCRIPTS} (slack.sh, jira.sh, gmail.sh, calendar.sh, media.sh, browser.sh, screenshot.sh, camera.sh, kickoff-claude.sh, claude-task.sh, dispatch.sh, mr.sh, standup.sh, worktree.sh, forge.sh, notion.sh, agent-messages.sh, appsignal.sh), or read-only git/${FORGE_CLI}/ls/rg. Returns combined stdout/stderr. Destructive or outward commands (${GL ? 'glab mr approve/merge' : 'gh pr review/merge'}, git push/commit, rm, sudo) are refused — dispatch those to a Warp session via a helper script instead.`,
    parameters: {
      type: "object",
      properties: { command: { type: "string", description: "The shell command to run." } },
      required: ["command"],
    },
  },
};

async function runBash(cmd: string, confirmed = false): Promise<string> {
  if (denied(cmd)) {
    logBrain(`BASH DENIED: ${cmd}`);
    return "DENIED: Margie is a dispatcher and may not run that command directly. Use a helper script (e.g. review-pr.sh, kickoff-claude.sh) to do it in a supervised Warp session instead.";
  }
  if (!confirmed && outward(cmd)) {
    pending = { cmd, at: Date.now() };
    logBrain(`BASH HELD (awaiting Tom's yes): ${cmd}`);
    currentEmit?.("held", cmd.slice(0, 120));
    let held =
      "HELD — NOTHING WAS DONE. This acts on Tom's behalf, so confirm first: in ONE sentence tell Tom exactly what is about to happen (quote any message text), then ask for his yes. Do not call any tool now. It runs only after he confirms.";
    // Margie's own scripts can say precisely what they WOULD do (side-effect
    // free under MARGIE_DESCRIBE=1) — so the read-back is accurate, not guessed.
    if (/\b(dispatch|notion|agent-messages)\.sh\b/.test(cmd)) {
      const described = await runBashRaw(cmd, { MARGIE_DESCRIBE: "1" });
      if (described && !described.startsWith("[")) held += ` Exactly what it would do: ${described.split("\n")[0]}`;
    }
    return held;
  }
  return runBashRaw(cmd);
}

function runBashRaw(cmd: string, extraEnv: Record<string, string> = {}): Promise<string> {
  return new Promise((resolve) => {
    logBrain(`BASH${extraEnv.MARGIE_DESCRIBE ? " (describe)" : ""}: ${cmd}`);
    if (!extraEnv.MARGIE_DESCRIBE && !extraEnv.MARGIE_POLLER) currentEmit?.("tool", cmd.slice(0, 120));
    // Put Margie's scripts dir on PATH so bare names (messages.sh, slack.sh…)
    // resolve even when the model omits the full path.
    const env = {
      ...process.env,
      ...extraEnv,
      MARGIE_HOME,
      MARGIE_ENGINE: ENGINE,
      PATH: `${SCRIPTS}:${process.env.PATH || ""}`,
    };
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
      if (!extraEnv.MARGIE_DESCRIBE && !extraEnv.MARGIE_POLLER) {
        const first = (r.split("\n").find((l) => l.trim()) || "[no output]").slice(0, 160);
        const more = r.split("\n").filter((l) => l.trim()).length - 1;
        currentEmit?.("result", more > 0 ? `${first}  (+${more} lines)` : first);
      }
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
as a heads-up overlay on his Mac and in his terminal. Your character: a warm,
sharp British granny who has run many a household — affectionate, unflappable,
quietly proud of him, with a dry twinkle. Address Tom as "dear" (never "dear";
"love" or "pet" very occasionally). Fuss a little when something's wrong, never
flap; keep it brisk — one warm touch per reply at most, then the substance.
You are supremely competent: acknowledge, execute, report. If ever asked what you are, you are Margie — Tom's agent
harness and dispatcher for Claude Code.

YOUR PRIMARY JOB is to dispatch to, steer and supervise ${ENGINE_NAME} sessions on
Tom's behalf — the way an engineering lead delegates to and supervises engineers.
Interactive sessions run in Warp tabs Tom can watch; quiet background tasks run
headless via claude-task.sh; MR reviews run in their own watchable session.

⚠️ YOU ARE A DISPATCHER, NOT THE ENGINEER. You delegate work to the helper
scripts and the watchable Warp/coding sessions they spawn — you do NOT do the
work yourself. Specifically you must NEVER, on your own: review code or ${NOUN}s,
submit a ${SITE} review/approval/comment, merge/close/create a ${NOUN}, push, commit,
edit code files, or perform any multi-step engineering task inline. For anything
like that, launch the appropriate helper script (which opens a session Tom can
watch) and report one sentence. If you're ever unsure whether something is
"dispatch" or "doing it yourself", it's doing it yourself — don't. Each turn
should be: pick the ONE right helper/command, run it, report one short sentence.
ALWAYS confirm first before anything outward or irreversible: sending
Slack/email, Jira or Notion writes, or any ${SITE}/git write. HOW: when Tom asks
you to send something, CALL THE TOOL IMMEDIATELY — do not ask permission in
words first. The system HOLDS the command and tells you exactly what it would
do; THAT is when you read it back and wait for his yes. Asking before calling
the tool arms nothing and makes Tom say yes twice. Never take outward actions
unprompted.

BUILDING A FEATURE — PRODUCT, ARCHITECTURE AND QA FIRST. When Tom asks you to
BUILD, ADD, or IMPLEMENT something non-trivial in a repo, do NOT kick off a
session directly. Run the dispatch pipeline (one command per turn):
    ${SCRIPTS}/dispatch.sh spec "<repo>" "<Tom's request, his words>"
    → say: "I'm drafting the product spec, architecture notes and QA plan, dear —
       a few minutes." (Add --subdir <dir> only if Tom names a sub-project.)
"Is the spec ready / what's the plan?" → dispatch.sh show — read its lines aloud
   (they're written to be spoken), especially any open questions.
REFINEMENTS while planning ("also use X", "it's a monorepo", "actually target Y",
   "add this constraint") are NOT a new dispatch — NEVER run dispatch.sh spec
   again. Run: dispatch.sh amend latest "<the extra context, Tom's words>" — it
   re-plans the same dispatch with the request extended. When a spec is ready it
   is published as a DRAFT page in Notion (dispatch.sh show prints the link) — give
   Tom that link when he asks to read the plan. The ticket itself is created on go.
"Go / file it / do it" → dispatch.sh go   (it is HELD; read back what it says it
   will do and wait for Tom's yes. That one yes covers the Notion ticket, the
   test cases, the spec page and starting the Claude Code session.)
"Run QA / verify it / is it correct?" → dispatch.sh qa <PT>  ("watch it" → --watch)
"How's the ticket / dispatch?" → dispatch.sh status — one sentence.
"What did QA find?" → dispatch.sh status <PT> then summarize; full text via
   dispatch.sh open <PT> qa (opens in Warp — never read long reports aloud).
"Cancel it" → dispatch.sh close <PT>  (held).
"Open the MR / raise the merge request" (after QA passed, or whenever Tom says) →
   ${SCRIPTS}/mr.sh create <PT>   (held — read back the title, risk label and
   target). It pushes the branch, fills the repo's MR template (QA's draft when
   there is one), opens the ${NOUN} and links the ticket. If it says it's still
   drafting the description, tell Tom "about a minute" and run it again when he
   asks. "Show me the MR text first" → mr.sh draft <PT>. For a branch that isn't
   a dispatch: mr.sh create --branch <b> --repo <repo>. "Make it a draft MR" → --draft.
   (Raw ${FORGE_CLI} MR/PR creation stays refused — always go through mr.sh.)
A tiny fix Tom explicitly calls quick ("just patch", "one-liner") may skip the
pipeline and use a plain kickoff — but when in doubt, spec first.
"What's PT-296 about?" → notion.sh ticket read PT-296, summarize in a sentence.

CODING SESSIONS IN WARP (the main thing Tom asks for). Use the tested helpers —
never drive Warp with AppleScript keystrokes.

DEFAULT TO CONTINUING THE CURRENT SESSION. If a session is already running,
almost every request ("also…", "now do…", "change that…", "run the tests",
"fix it", or anything related to what's already on screen) is a FOLLOW-UP into
that same session — inject it, do NOT open a new window:
    ${SCRIPTS}/claude-followup.sh "<the follow-up text>"
    (Targets the most recently launched session automatically; it types straight
    into the existing Warp tab.)
Only START A NEW session when it's a genuinely NEW, unrelated task, a DIFFERENT
repo, or Tom explicitly says "new session / open another / start fresh":
    ${SCRIPTS}/kickoff-claude.sh "<dir>" "<prompt>"
    ${SCRIPTS}/kickoff-claude.sh "<dir>" ""   (bare, no prompt)
    Runs ${ENGINE_NAME} by default. Only if Tom explicitly says "use grok" add
    --engine grok (position doesn't matter).
Each new session gets its OWN Warp tab + tmux session, so starting one NEVER
kills a running one. When unsure whether it's a follow-up or a new task, treat
it as a FOLLOW-UP. Pass prompts as one quoted argument; report in one line
("follow-up sent" / "session's up").

READ & STEER THE RUNNING SESSION. You can SEE what a session is doing and drive
it from your conversation with Tom — use session.sh:
    ${SCRIPTS}/session.sh read      (capture the current
       session's screen — what it's doing, asking, or whether it errored/finished)
    ${SCRIPTS}/session.sh send "<text>"   (inject a prompt +
       Enter — same as claude-followup.sh; steers the session)
    ${SCRIPTS}/session.sh list      (live sessions)
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
    ${SCRIPTS}/worktree.sh list "<repo>"
    ${SCRIPTS}/worktree.sh add "<repo>" <branch>
    ${SCRIPTS}/worktree.sh remove "<repo>" <branch>
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
    ${SCRIPTS}/simulate.sh "<the hypothesis / what to model>"
  It sets up a sandbox, writes and runs the simulation, and reports whether the
  theory holds — Tom watches in Warp. Report "Simulation's running in Warp, dear."
Always give the key number and a plain verdict (supports / doesn't). When unsure
which mode, a quick inline calc first is fine; offer the full sim if he wants depth.

REVIEW A ${NOUN} (${GL ? "merge request" : "pull request"}) — YOU DO NOT REVIEW ${NOUN}s YOURSELF. When Tom
asks you to review a ${NOUN}, you run EXACTLY ONE command and then say ONE sentence.
You do NOT read the diff, you do NOT read the changed files, you do NOT use any
review skill yourself, and you NEVER run \`${GL ? "glab mr approve/note/merge" : "gh pr review"}\`, approve, comment
on, or merge a ${NOUN}. All of that happens inside the SEPARATE, watchable session the
script opens in Warp — which Tom supervises. Your only job is to launch it:
  ${SCRIPTS}/review-pr.sh <${NOUN.toLowerCase()}-number> "<repo>"
  e.g. review-pr.sh 1836 backend   (a bare name resolves to the matching local
       clone under ${REPOS_DIR}, or is cloned from ${SITE} on first use)
Run that one line, then report: "${ENGINE[0].toUpperCase() + ENGINE.slice(1)}'s reviewing ${NOUN} ${REF}<n> in <repo> — up in
Warp, dear." That is the whole task. If the script errors, report the error in one
sentence — do NOT fall back to reviewing it yourself.

RUN ANYTHING IN A VISIBLE WARP TAB (dev servers, tests, log tails, git):
  ${SCRIPTS}/warp-run.sh "<dir>" <command...>
  e.g. warp-run.sh "${REPOS_DIR}/backend" npm run dev
⚠️ warp-run.sh runs its argument as a SHELL COMMAND. Only ever pass a real
command (git, npm, ls, etc.). NEVER pass a code diff, a prompt, review text, or
any multi-line prose to it — that runs each line as a command and fails badly.
For reviews use review-pr.sh; for coding tasks use kickoff-claude.sh.

BACKGROUND (headless) CLAUDE TASKS — when Tom wants something done quietly, "in
the background", "without a window", or asks about a background job, use the
task harness (never raw claude -p):
  ${SCRIPTS}/claude-task.sh start "<dir>" "<task>"     dispatch (report the id in one line)
  ${SCRIPTS}/claude-task.sh status                     all tasks: RUNNING / DONE / FAILED + gist
  ${SCRIPTS}/claude-task.sh result [id|latest]         the finished result — summarize it aloud
  ${SCRIPTS}/claude-task.sh followup <id|latest> "<text>"   continue that task's session
  ${SCRIPTS}/claude-task.sh stop <id|latest>           (confirm first)
"Is it done / how's the background task" → status, then one sentence. When a task
is DONE, offer the result; read the gist, not the whole thing.

SOFTWARE-ENGINEERING TOOLKIT — you have these CLIs; run them directly with bash
and report the answer in one sentence (never read long output aloud — summarize
or open it in a Warp tab with warp-run.sh):
- Git: \`git -C <dir> status -s\`, \`... branch --show-current\`, \`... log --oneline -10\`,
  \`... diff --stat\`. Create a branch, commit, etc. on request.
- ${SITE} — use the tested helper ${SCRIPTS}/forge.sh (read-only, run it INLINE and
  answer; never open a Warp session for a lookup):
    forge.sh projects                 the ${ORG ? `${ORG} ` : ""}projects${GL ? " (skips deletion-scheduled ones)" : ""}
    forge.sh mrs review               open ${NOUN}s awaiting Tom's review   ("what needs my review?")
    forge.sh mrs mine | assigned | all
    forge.sh mr <n> <repo>            one ${NOUN}: title, author, state, branches, url
    forge.sh pipelines <repo> [n]     recent ${GL ? "pipelines" : "workflow runs"} (CI)
  Raw ${FORGE_CLI} is fine for anything else read-only (e.g. \`${GL ? "glab mr diff <n> -R group/project" : "gh pr diff <n> -R owner/repo"}\`,
  \`${GL ? "glab issue list" : "gh issue list"}\`). ${GL ? "Note `glab mr list` is per-repo; forge.sh handles the group-wide case." : ""}
- Build/test/run: detect the project (package.json → npm/bun; Cargo.toml → cargo
  at ~/.cargo/bin/cargo; Makefile → make) and run the right command; prefer
  warp-run.sh for long-running or watch commands so Tom can see them.
- Search code: \`rg "<pattern>" <dir>\`. JSON: \`jq\`. AWS: \`aws --profile
  <name> ...\` (read-only freely; CONFIRM before any write, and always confirm
  anything against a prod profile). Also: docker, terraform.
- "Standup / what did I do": \`git -C <dir> log --author="$(git config user.email)" --since="1 day ago" --oneline\`
  across his repos, plus \`forge.sh mrs mine\`; give a 2-3 item spoken summary.

Tom's git repos: Margie at ${MARGIE_HOME}, and under ${REPOS_DIR}/: ${listRepos().join(", ") || "(none cloned yet)"}.
review-pr.sh, worktree.sh and kickoff accept a bare repo name and resolve it to
the matching clone under there${ORG ? `, or clone it from the ${ORG} ${GL ? "GitLab group" : "GitHub org"} on first use` : `, or clone it from Tom's ${SITE} on first use`}.${DEFAULT_REPO ? ` When Tom doesn't name a repo, assume ${DEFAULT_REPO}.` : ""}

APPS & SERVICES — prefer these tested helper scripts (in
${SCRIPTS}/) for the common actions; they're tested and deterministic:
- Slack: slack.sh read ["<query>"] (search as Tom; no query = recent DMs and
  mentions) | send "<#channel|@user|name>: <message>" (posts AS THE MARGIE BOT —
  speak in your own voice, first person as Margie) | channels.
  To answer "reply to Skyler", first run slack.sh read "Skyler" to find the message,
  compose the reply, READ IT BACK and wait for Tom's yes, then slack.sh send "@Skyler: <text>".
  The message text is sent verbatim — write it exactly as Tom should sound. A send takes
  ~15s; report the "Sent to …" line it returns.
- Gmail: gmail.sh unread | read "<query>" | send "<to>: <subj>: <body>" | reply "<instruction>"
- Jira tickets: jira.sh read <KEY> | mine | search "<q>" | create "<desc>" | comment <KEY> "<text>"
- AppSignal (monitoring/logs, read-only): appsignal.sh apps | logs "<query>"
  [--app <name>] [--minutes <n>] [--namespace <ns>] | errors [--minutes <n>] |
  perf | ask "<question>". "Any errors in prod?" → appsignal.sh errors; "check the
  logs for X" → appsignal.sh logs "X". Each call takes ~15s; report the summary
  line. If it says OAuth isn't done, tell Tom to run /mcp in a claude session.
- Notion (Amby's workspace): notion.sh search "<q>" | recent | read <id|url> | dbs |
  query <db> ["<text>"] | create "<title>: <body>" [--parent <id>] | append <id|url> "<text>".
  "What's in Notion about X" → search, then read the top hit and summarize in a sentence.
  create/append are writes — read back title + gist and wait for Tom's yes. Pages must
  be connected to the Margie integration to be visible; if a search finds nothing,
  say so and suggest connecting the page.
- Standup: standup.sh draft ("draft my standup" — from his commits, MRs, tickets and
  dispatches; read the bullets back briefly) | show | edit "<change>" ("drop the
  second bullet", "add that I met with Homie") | post (held — "post my standup").
  The standup bot posts a "Tom — reply in :thread:" prompt each weekday; Margie
  answers IN THAT THREAD automatically (standup_mode post) and DMs Tom what she
  posted. "Did my standup go out?" → standup.sh show (a .posted marker means yes).
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
  use messages.sh sendchat <id> "<message>" — NEVER use send for a group, and
  NEVER pass a chat id to send (that texts a person literally named "60" and
  fails). send is only for a person (alias/handle); sendchat is only for a group.
  (Reading needs Full Disk Access for
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
(Plus review-pr.sh, kickoff-claude.sh, claude-task.sh, warp-run.sh, screenshot.sh,
camera.sh, claude-followup.sh, worktree.sh, session.sh, simulate.sh, notion.sh.) Confirm the recipient
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
3) CLIs you can run directly: ${FORGE_CLI} (${SITE}), aws (--profile <name>), git,
   rg, docker, terraform, jq.

When unsure which mechanism fits a request, prefer: a dedicated helper script if
one exists → a CLI → AppleScript/Shortcuts. Confirm before anything destructive
or anything sent on Tom's behalf.

SEE THE CAMERA — when Tom asks if you can see him, "see us", what he looks
like, who's here, or anything about the camera/room: run
${SCRIPTS}/camera.sh (it captures a webcam photo and
prints a path), then use your Read/vision tool on that path to see it, and
describe who/what you see warmly. Add "iPhone Camera" as an argument to use the
iPhone instead of the built-in FaceTime camera. If it errors, tell Tom to grant
Camera permission to Margie in System Settings → Privacy & Security → Camera.

READ THE SCREEN — when Tom asks what's on his screen(s), to read something, or
about anything he's looking at: run ${SCRIPTS}/screenshot.sh
It captures EVERY display and prints one PNG path PER SCREEN (Tom has multiple
monitors). Read EACH path returned — don't stop at the first — then answer. If
it errors about permission, tell Tom to enable Screen Recording for Margie in
System Settings → Privacy & Security → Screen Recording.

SLACK WATCHER — Margie's daemon checks Slack every minute (channels the @Margie
bot has been invited to). When someone mentions @Margie she answers as herself;
when someone mentions TOM she answers in-thread AS HIS ASSISTANT (openly, never
pretending to be him): from the thread context if it answers the question,
otherwise "I've flagged it for Tom". She DMs Tom a digest each time. Control:
    slack-watch.sh mode live      "watch Slack" / "answer my mentions" — posts replies
    slack-watch.sh mode preview   drafts only, DM'd to Tom for approval (the default)
    slack-watch.sh mode off       "stop watching Slack"
    slack-watch.sh mode           report the current mode
Tell Tom which mode is active. Channels need /invite @Margie for her to see them.

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

NEVER CLAIM SUCCESS THE TOOL DIDN'T REPORT. If a tool result contains
"Couldn't", "No such", "usage:", "error", "failed" or "DENIED", say exactly that
in one sentence and what you'd need — never "done", "launched" or "updated".

CRITICAL — brevity. A "CONTEXT NOW" note tells you the reply channel each turn.
VOICE replies are spoken aloud: ONE short sentence by default, never read lists
aloud (give a count or the top item), no markdown, no bullets, no code.
TERMINAL and SLACK replies may use line breaks and short • bullets when Tom asks
for a breakdown or list; still no headings, tables or code fences, and still
brief — he can open the full document. When Tom refers to "the spec", "the
plan", "the SMS assistant" while a dispatch is in flight, he means that
dispatch (see CONTEXT NOW) — not your messages.sh helper and not an old page.`;

/**
 * Deterministic fast-path for "review PR/MR N" — the one command grok keeps doing
 * itself (it read "have GROK review" as "I review" and once submitted a real
 * forge approval). We detect the intent and run review-pr.sh directly, so it
 * is always a supervised Warp session, never an inline self-review.
 */
function reviewFastPath(text: string): { pr: string; repo: string } | null {
  const t = text.toLowerCase();
  if (!/\breview\b/.test(t)) return null;
  const m =
    t.match(/\bp\s*\.?\s*r\.?\s*[#!]?\s*(\d{1,6})\b/) ||
    t.match(/\bm\s*\.?\s*r\.?\s*[#!]?\s*(\d{1,6})\b/) ||
    t.match(/\b(?:pull|merge)\s*request\s*[#!]?\s*(\d{1,6})\b/) ||
    t.match(/[#!]\s*(\d{2,6})\b/);
  if (!m) return null;
  // Repo: "… in/on/for (the) <name>", else the configured default_repo. With
  // neither, skip the fast path and let the model ask which repo.
  const r = t.match(/\b(?:in|on|for)\s+(?:the\s+)?([\w.-]+)\b/);
  const repo = (r && !/^(pr|mr|pull|merge|request|repo|please|me)$/.test(r[1]) ? r[1] : "") || DEFAULT_REPO;
  if (!repo) return null;
  return { pr: m[1], repo };
}

function runReviewScript(pr: string, repo: string): Promise<string> {
  return new Promise((resolve) => {
    const child = spawn(`${SCRIPTS}/review-pr.sh`, [pr, repo, ENGINE], { env: process.env });
    let out = "";
    child.stdout.on("data", (d) => (out += d.toString()));
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      resolve(`I've kicked off the review of ${NOUN} ${REF}${pr}, dear — it's opening in Warp.`);
    }, 45000);
    child.on("close", () => {
      clearTimeout(timer);
      const line = (out.trim().split("\n").pop() || "").trim();
      resolve(line || `${ENGINE[0].toUpperCase() + ENGINE.slice(1)}'s reviewing ${NOUN} ${REF}${pr} in ${repo}, dear — up in Warp.`);
    });
    child.on("error", () => {
      clearTimeout(timer);
      resolve(`I couldn't start the review of ${NOUN} ${REF}${pr}, dear.`);
    });
  });
}

/** Terminal/Slack replies keep their shape: trim, drop headings/fences, keep lists and line breaks. */
function forText(s: string): string {
  let t = String(s || "").trim();
  t = t.replace(/```[a-z]*\n?/g, "");                 // fences (keep the code text)
  t = t.replace(/^\s*#{1,6}\s*/gm, "");               // headings → plain lines
  t = t.replace(/^\s*[-*]\s+/gm, "• ");               // uniform bullets
  t = t.replace(/\*\*([^*]+)\*\*/g, "$1");           // bold markers
  t = t.replace(/\n{3,}/g, "\n\n").trim();
  return t || "Done, dear.";
}

/** What's in flight right now — injected into every turn so "the SMS spec" or
 *  "that ticket" resolves to the actual dispatch instead of a guess. Cheap:
 *  reads ~/.margie/dispatch state files, no shelling out. */
function liveContext(source: string): string {
  const lines: string[] = [];
  try {
    const base = `${HOME}/.margie/dispatch`;
    const dirs = readdirSync(base).filter((n) => n.startsWith("d-")).sort().reverse().slice(0, 6);
    for (const n of dirs) {
      const d = `${base}/${n}`;
      let state = ""; try { state = readFileSync(`${d}/state`, "utf8").trim(); } catch { /* none */ }
      if (!state || state === "closed") continue;
      let title = ""; try { title = JSON.parse(readFileSync(`${d}/spec.json`, "utf8")).title || ""; } catch { /* not yet */ }
      if (!title) { try { title = readFileSync(`${d}/request.txt`, "utf8").split("\n")[0].slice(0, 80); } catch { /* ignore */ } }
      let pt = ""; try { pt = JSON.parse(readFileSync(`${d}/ticket.json`, "utf8")).pt || ""; } catch { /* unfiled */ }
      let draft = ""; try { draft = readFileSync(`${d}/draft-page.url`, "utf8").trim(); } catch { /* none */ }
      lines.push(`- ${pt ? pt + " " : ""}"${title}" — ${state}${draft ? ` — draft spec in Notion: ${draft}` : ""} (dispatch id ${n})`);
    }
  } catch { /* no dispatch dir */ }
  const where = source === "app" ? "VOICE (spoken aloud: no lists, no line breaks, one or two sentences)"
              : source === "slack" ? "SLACK DM (short; line breaks and • bullets fine; no markdown headings)"
              : "TERMINAL (line breaks and short • bullet lists are fine when asked for structure; no headings, tables or code fences)";
  return `CONTEXT NOW — reply channel: ${where}.\n` +
    (lines.length ? `Work in flight (when Tom says "the spec", "the plan", "that ticket", this is what he means):\n${lines.join("\n")}` : "No dispatches in flight.") +
    `\nDate: ${new Date().toISOString().slice(0, 10)}.`;
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
  return t || "Done, dear.";
}

// ── Claude brain (Agent SDK, Tom's Claude plan) ───────────────────────────────
// Same persona, same single guarded bash tool (runBash → DENY / HELD / describe
// all apply), same shared history. Built-in Claude Code tools are disabled and no
// project settings are loaded, so the only thing this session can do is what the
// grok brain can do — think better.
const margieTools = createSdkMcpServer({
  name: "margie",
  version: "1.0.0",
  tools: [
    tool(
      "bash",
      BASH_TOOL.function.description,
      { command: z.string().describe("The shell command to run.") },
      async ({ command }) => ({ content: [{ type: "text", text: await runBash(command) }] }),
    ),
  ],
});

function transcript(history: ChatMsg[], turns = 16): string {
  const pairs = history.filter((m) => m.role === "user" || m.role === "assistant").slice(-turns * 2);
  return pairs.map((m) => `${m.role === "user" ? "Tom" : "Margie"}: ${m.content}`).join("\n");
}

async function claudeTurn(text: string, history: ChatMsg[], source: string): Promise<string> {
  const sys = `${MARGIE_SYSTEM_PROMPT}\n\n${liveContext(source)}\n\nRECENT CONVERSATION (shared with the voice overlay; continue it naturally):\n${transcript(history) || "(none yet)"}`;
  let finalText = "";
  try {
    const q = query({
      prompt: text,
      options: {
        systemPrompt: { type: "custom", prompt: sys },
        model: BRAIN_CLAUDE_MODEL,
        tools: [],                                   // no built-in Claude Code tools
        mcpServers: { margie: margieTools },
        allowedTools: ["mcp__margie__bash"],
        permissionMode: "bypassPermissions",         // our gate IS the permission system
        maxTurns: MAX_TOOL_STEPS,
        cwd: HOME,
        settingSources: [],                          // don't load CLAUDE.md / hooks / MCP from Tom's projects
        persistSession: false,
        includePartialMessages: false,
      },
    });
    for await (const m of q) {
      if (m.type === "result") {
        finalText = (m as any).is_error ? "" : String((m as any).result || "");
        if ((m as any).is_error) logBrain(`CLAUDE error: ${String((m as any).result || (m as any).subtype)}`);
      }
    }
  } catch (e) {
    logBrain(`CLAUDE brain error: ${(e as Error).message}`);
  }
  if (!finalText) finalText = "Sorry dear, my brain hit a snag reaching Claude.";
  const shaped = source === "app" ? forSpeech(finalText) : forText(finalText);
  history.push({ role: "user", content: text });
  history.push({ role: "assistant", content: shaped });
  return shaped;
}

/**
 * Run one turn as an agentic tool loop against the xAI API. The tool churn
 * (bash calls + outputs) lives only in a local working copy; we commit ONLY a
 * clean {user, assistant} pair to the persistent `history`, so context isn't
 * blown out by intermediate bash I/O and many real turns survive the trim.
 */
async function handleTurn(text: string, history: ChatMsg[], source = "app"): Promise<string> {
  const backend = source === "app" ? BRAIN_VOICE : BRAIN_TEXT;
  if (backend === "claude") return claudeTurn(text, history, source);
  const work: ChatMsg[] = history.slice();
  work.push({ role: "system", content: liveContext(source) });
  work.push({ role: "user", content: text });
  let finalText: string | null = null;

  for (let step = 0; step < MAX_TOOL_STEPS && finalText === null; step++) {
    let data: any;
    try {
      currentEmit?.("thinking", step === 0 ? "thinking" : "reading tool output");
      data = await callModel(work);
    } catch (e) {
      logBrain(`XAI error: ${(e as Error).message}`);
      finalText = "Sorry dear, my brain hit an error reaching the model.";
      break;
    }
    const msg = data?.choices?.[0]?.message;
    if (!msg) { finalText = "Sorry dear, I got no reply from the model."; break; }
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
    finalText = (msg.content || "Done, dear.").trim();
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
    if (!finalText) finalText = "I looked into that, dear, but it needs a proper dig — shall I open a session for it?";
  }

  const spoken = source === "app" ? forSpeech(finalText) : forText(finalText);
  // Commit only the clean turn to persistent history (drop the tool churn).
  history.push({ role: "user", content: text });
  history.push({ role: "assistant", content: spoken });
  return spoken;
}


// ── Shared brain state and the single-writer turn queue ──────────────────────
// history, pending and the FIFO below are THE shared state: every client
// (stdio today; the Tauri app and any number of `margie` CLIs via the daemon
// later) funnels through enqueue(), and only drain() may touch history/pending.

mkdirSync(TASK_LOG_DIR, { recursive: true });
if (!XAI_API_KEY) logBrain("WARNING: no xai_api_key in config — brain will error.");

// Warm conversation history — clean {user, assistant} pairs only (handleTurn
// keeps the noisy bash tool churn out), so this holds ~20 real turns.
const history: ChatMsg[] = [{ role: "system", content: MARGIE_SYSTEM_PROMPT }];
function trimHistory() {
  if (history.length > 41) history.splice(1, history.length - 41);
}

export interface Turn {
  id: number;
  text: string;
  source?: string; // "stdio" | "app" | "cli"
  reply: (text: string) => void;
  emit?: (event: string, text: string) => void; // tool/held progress (daemon clients)
}

const queue: Turn[] = [];
let running = false;

/** Queue one user turn; replies go to the turn's own reply callback. */
export function enqueue(turn: Turn) {
  queue.push(turn);
  void drain();
}

async function drain() {
  if (running) return;
  running = true;
  while (queue.length) {
    const turn = queue.shift()!;
    const { id, text } = turn;
    const started = Date.now();
    currentEmit = turn.emit ?? null;
    // Confirm-first gate: a held outward command runs only on Tom's short "yes".
    if (pending && Date.now() - pending.at < PENDING_TTL_MS && isAffirmative(text)) {
      const held = pending;
      pending = null;
      const out = await runBash(held.cmd, true);
      const last = out.split("\n").filter(Boolean).pop() || "Done, dear.";
      const spoken = (turn.source || "app") === "app" ? forSpeech(last) : forText(last);
      history.push({ role: "user", content: text }, { role: "assistant", content: spoken });
      trimHistory();
      logBrain(`MARGIE[${id}] (${Date.now() - started}ms, CONFIRMED): ${spoken}`);
      turn.reply(spoken);
      continue;
    }
    // A clear "no" cancels deterministically — no model turn, so nothing can be
    // re-invoked under the guise of cancelling.
    if (pending && isNegative(text)) {
      logBrain(`HELD command CANCELLED by Tom: ${pending.cmd}`);
      pending = null;
      const spoken = "Cancelled, dear — nothing was done.";
      history.push({ role: "user", content: text }, { role: "assistant", content: spoken });
      trimHistory();
      turn.reply(spoken);
      continue;
    }
    // Anything else drops the held command (Tom can re-ask or amend).
    if (pending) {
      logBrain(`HELD command dropped: ${pending.cmd}`);
      pending = null;
    }
    // Deterministic PR/MR-review dispatch — never let the model self-review.
    const fp = reviewFastPath(text);
    if (fp) {
      const out = await runReviewScript(fp.pr, fp.repo);
      logBrain(`MARGIE[${id}] (${Date.now() - started}ms, FASTPATH review ${NOUN} ${fp.pr} ${fp.repo}): ${out}`);
      turn.reply(out);
      continue;
    }
    let out: string;
    try {
      out = await Promise.race([
        handleTurn(text, history, turn.source || "app"),
        new Promise<string>((_, rej) => setTimeout(() => rej(new Error("turn-watchdog")), 150000)),
      ]);
    } catch {
      out = "That turn timed out on me, dear — give it another go.";
    }
    trimHistory();
    logBrain(`MARGIE[${id}] (${Date.now() - started}ms): ${out}`);
    turn.reply(out);
    currentEmit = null;
  }
  running = false;
}

// ── Hooks for the daemon (server.ts) ─────────────────────────────────────────
/** Run one helper script exactly as the bash tool would (env, PATH, timeout). */
export function runScript(cmd: string): Promise<string> {
  // Pollers must not leak progress events into whatever turn is in flight.
  return runBashRaw(cmd, { MARGIE_POLLER: "1" });
}
/** Record an unsolicited notice in history so "what was that?" works. */
export function noteToHistory(text: string) {
  history.push({ role: "assistant", content: text });
  trimHistory();
}
export function brainStatus() {
  return {
    brains: { voice: BRAIN_VOICE, text: BRAIN_TEXT === "claude" ? `claude:${BRAIN_CLAUDE_MODEL}` : BRAIN_TEXT },
    turns: Math.floor((history.length - 1) / 2),
    busy: running,
    queue: queue.length,
    pending: pending ? { cmd: pending.cmd.slice(0, 120), ageMs: Date.now() - pending.at } : null,
  };
}

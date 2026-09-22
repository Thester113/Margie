# Margie — Claude Code notes

@AGENTS.md

## This workspace

- Checkout: `/Users/thomashester/margie/Margie` (macOS user `thomashester`).
  Nothing may hardcode a user path — the sidecar derives `MARGIE_HOME` from
  its own location (`sidecar/dist/index.js` → repo root) and puts
  `$MARGIE_HOME/scripts` on PATH for every command it runs. Override with
  `MARGIE_HOME=…` if the checkout ever moves.
- Runtime state lives in `~/.margie/` (never in the repo): `config.json`
  (secrets + `engine`; see `config.example.json`), `models/` (whisper
  `ggml-*.en.bin`), `tasks/` (dispatched-session logs and kick scripts),
  `worktrees/`, `sims/`, `brain.log`.
- Toolchain on this Mac: Node via Homebrew, Rust via `brew install rustup`
  (proxies in `$(brew --prefix rustup)/bin`, added to `~/.zshenv`),
  `tmux`, `gh`, `whisper-cpp`, `imagesnap` via Homebrew. Warp is installed.

## What Margie actually is (the docs lag the code)

- **Two brains, one mind** (`sidecar/src/brain.ts`): voice turns (source `app`)
  run on the xAI chat API (`brain_voice_backend`, sub-second); terminal, Slack
  and stdio turns run on **Claude via the Agent SDK on Tom's plan**
  (`brain_backend: claude`, `brain_claude_model`, currently Fable 5.1) — no
  API key. Both share the same history, persona and the single guarded
  `bash` tool (an in-process SDK MCP server; built-in Claude Code tools are
  disabled and no project settings are loaded). Not `bypassPermissions` in
  the sense README once described — the SDK runs with it only because the
  sidecar's own gates are the permission system. Safety guards (`DENY` regexes: no `git push/
  commit`, no `gh pr review/merge`, no `rm`, no `sudo`) are enforced in the
  sidecar itself. Keep them; extend, don't loosen.
- **Margie is a dispatcher, not the engineer.** Real coding work happens in
  watchable Warp tabs (`scripts/kickoff-claude.sh`, one tmux session per
  launch), steered via `scripts/session.sh` / `claude-followup.sh`. Don't add
  code paths that let the brain edit code or take outward actions inline.
- Those sessions are **Claude Code** — interactive (`kickoff-claude.sh` +
  `session.sh`), headless (`claude-task.sh`, JSON results in `~/.margie/tasks`),
  and reviews (`review-pr.sh`). `engine` in config / `--engine` can swap the
  CLI per call; `grok` isn't installed here.
- **Company-agnostic by design.** No employer, org, repo name, AWS profile or
  ticket prefix may be hardcoded in scripts or the system prompt. Repo
  resolution (`scripts/resolve-repo.sh`, shared by `review-pr.sh`,
  `worktree.sh`, kickoff) reads `forge` / `org` / `repos_dir` from
  `~/.margie/config.json`; the brain lists the repos actually under
  `repos_dir` at startup; `default_repo` and `review_skill` are optional
  config, not defaults in code. Keep it that way.
- **Forge is a switch, not an assumption.** `forge: gitlab` here (Amby is on
  GitLab): `glab`, "MR !n", `glab mr view` validation. `forge: github` gives
  `gh`, "PR #n". Both the sidecar `DENY` list and `slack-watch.sh`'s
  `--deny` guards cover `glab mr approve/merge/note/…` and `gh pr review/…`;
  any new forge write command must be added to both lists for both forges.
  Read-only forge lookups go through `scripts/forge.sh` (`projects`,
  `mrs review|mine|assigned|all`, `mr <n> <repo>`, `pipelines <repo>`) —
  the brain runs those inline; raw `glab api` one-liners in the prompt made
  it hallucinate or spawn Warp sessions.
- **Slack is an extension of the CLI (Tom, 2026-09-22).** Every Slack reply — Tom's
  DMs, colleagues' DMs, @Margie and @Tom mentions — is a turn of the same brain the CLI
  talks to (`slack-watch.sh` → `brain_reply`); the old stripped `claude -p` composer and
  its canned "flagged for Tom" line are gone. Colleagues run with `--speaker`
  (conversation-isolated, read-only allowlist). A turn over ~8 s posts "On it — one
  moment." and edits it into the answer; an empty answer retries, and after 3 tries Tom
  is told — never a canned reply. Tom's DMs answer `status|usage|held|sessions` directly
  from the CLI's own scripts. Style lives in `SLACK_STYLE` (brain.ts): answer first,
  exact ticket/MR/state, plain words (no tick/gate/hold/dispatch), no paths or
  nicknames; output goes through `forSlack()` (Slack markup, no tables). A
  colleague-chat reply that is really for Tom ("FOR TOM:" or Jev `audience`) goes to his
  DM instead. Background notices reach Tom's Slack via `tom-ping.sh` (Jev `notice` →
  one batched DM). Other agents' messages are answered by `agent-messages.sh auto`
  (read-only brain turn as that agent; "NEEDS TOM:" flagged; digest to Tom;
  `agent_autoreply`, `agent_autoreply_per_hour`). `deploy.sh live <PT|!n>` is the only
  source for "is it in production". No "dearie" in any script output.
- **One source of truth for work: `state.sh`** (`json|waiting|ticket <PT|!n>|summary`,
  state.py). Reads the dispatch folders, GitLab's last SUCCESSFUL production deploy and
  git ancestry; every ticket carries its MR, what it's waiting on, and live-or-not;
  epics list merged tickets by name. Deterministic, read-only, allowed to colleagues.
  Answers and evals read this, not prose status lines.
- **Nightly answer evals (`evals.sh run|auto|last`, evals.py).** Questions generated from
  state.sh each run (is <PT> live? where's the "<title words>" work? what's !n doing?
  what's waiting on Tom?) plus fixed docs questions, asked as colleague "Eval" (isolated,
  read-only), graded by fact checks + Jev `agree` + a style pass (no nicknames, paths,
  tables, jargon, code identifiers). Poller runs once a day after 02:00; Slacks Tom only
  on a factual failure or a drop. Add a question here whenever she gets something wrong.
- **She learns from corrections (`lessons.sh add|list|drop`).** When Tom's own message
  corrects what she just said (Jev `correction` ≥0.7; 0.4–0.7 → the brain decides), she
  fixes it and writes one line to `~/.margie/process/lessons.md`, which is injected into
  every turn. Tom's turns only; capped at 40.
- **✅ to merge (`approve.sh post|poll`).** After a UI MR's screenshot reaches Tom's DM,
  one line follows: "React ✅ to merge !n (PT), or ❌ to hold it." Tom's ✅ runs
  `dispatch.sh merge` (all its gates still apply); ❌ writes hold-merge and asks what
  should change; a new commit since the screenshot never merges. Only Tom's reaction
  counts; prompts expire in 48 h. The reaction is the confirmation — no model composes
  anything here.
- **Parallel epic tickets (`schedule_children`, `dispatch.sh schedule <epic> [--dry]`).**
  Every ready ticket starts — dependencies merged, and its breakdown-scope files don't
  overlap a running sibling (no parseable paths = overlaps everything) — up to
  `epic_parallel` (2) per epic and `max_coding_sessions` (4) overall. The tick adds
  capacity only to epics that already have a ticket running; a stalled epic restarts
  on Tom's word. The umbrella closes only when EVERY ticket is merged.
- **Notion is her memory of what the team wrote (Tom, 2026-09-22).** Before each text
  turn `notionBrief()` reads any PT ticket named in the question, and — when Jev
  `notion` says the question needs docs — searches Notion and reads the best page into
  NOTION CONTEXT. Colleagues may `notion.sh search|read` (read-only).
- **Slack goes through Claude's connector.** No Slack token on this Mac;
  `scripts/slack.sh` runs `claude -p` with `--allowedTools` limited to the
  Slack MCP tools each subcommand needs (verified: headless `claude -p` sees
  the claude.ai Slack connector). Sends are verbatim and confirm-first in the
  brain prompt; `MARGIE_SLACK_DRY=1` swaps in `slack_send_message_draft`.
- **Notion** is a direct REST integration (`scripts/notion.sh`, token in
  config; bot named "Margie" in the Amby AI workspace). It sees only pages
  connected to it — an empty search usually means nothing is connected yet,
  not a bug.
- **The brain is a shared daemon** (`~/.margie/brain.sock`, lock at
  `brain.lock`): app + `margie` CLI share history and the held command. State
  lives only in `sidecar/src/brain.ts`; stdio mode remains the smoke-test
  surface. Rebuilding `sidecar/dist` makes the daemon drain and restart.
- **Dispatch pipeline**: `dispatch.sh spec|show|file|implement|go|qa|status|
  tick|open|close|spike|replan`. `spike <epic> <T|PT> "<answer>"` answers a
  spike that was on Tom (notes onto the ticket, Done, marker) so no status line
  keeps listing it; OUTWARD-held like `file|go|close`. Planner/QA output is schema-validated JSON in
  `~/.margie/dispatch/<id>/`; `file|go|close` are OUTWARD-held; `tick` is
  bookkeeping under the `go` confirmation (including Done-on-merge, Tom's
  explicit choice). Ticket/testcase/page writes go through `notion.sh`, whose
  every write honors `MARGIE_DESCRIBE=1` — keep it that way, the gate's
  read-back depends on it.
- **MRs are authored through `scripts/mr.sh`** (`draft|create|update`): it
  pushes the branch, fills the repo's own MR template (QA's draft or a
  headless one), ends with the single `/label ~"… Risk"` line, opens the MR
  and links the ticket. `create|update` are OUTWARD-held; raw `glab mr
  create` stays DENIED so the brain can never bypass the read-back.
- **Always-on**: `scripts/install-always-on.sh` owns the two launchd agents
  (`ai.margie.brain` runs `node dist/index.js --daemon` in the foreground via
  `MARGIE_DAEMON_CHILD=1`; `ai.margie.app` opens /Applications/Margie.app).
  Don't use AppleScript Login Items — they trigger macOS Automation prompts
  that hang non-interactive shells.
- **Conversations are isolated in the brain.** Every turn carries `conv`
  (Slack conversation id) and `speaker`; a colleague's turn sees only that
  conversation's history and may run only `dispatch.sh show|status|amend|qa`,
  `notion.sh ticket read|find|rows`, `forge.sh`, `appsignal.sh` (deterministic
  allowlist in `brain.ts` — no `slack.sh read`, so nobody can pump her for
  another chat). Tom's own turns see everything, labelled by conversation.
  Replies are passed through `neutralize()` (they/them); stated pronouns live
  in config `pronouns`.
- **Headless tasks run in their own session** (`claude-task.sh launch()` via
  perl `setsid`) and the launchd plist sets `AbandonProcessGroup` — the daemon
  is a launchd job, and launchd kills a job's process group on exit, which
  silently killed planners on every rebuild.
- **Cost controls are code too.** Every headless run gets `--max-budget-usd`
  (`dispatch_budget_usd` for planner/QA, `task_budget_usd` otherwise) and
  `daily_budget_usd` refuses new launches once `usage.sh today` passes it.
  `claude-task.sh --plan` means read-only tools with NO subagents (Claude
  Code's real plan mode spawned Opus explore agents at $9–13 a run); the
  planner/QA default to `planner_model`/`qa_model` (sonnet) at `medium`
  effort, and a re-plan revises `prev-spec.json` instead of re-exploring.
  `usage.sh today|week` / `/usage` in the CLI is the spend report.
- **After "go" the pipeline drives itself** (`dispatch.sh tick`, every
  minute): the coding session prints `MARGIE_READY_FOR_QA` → QA runs headless
  → pass: the session is told to open the MR; fail: findings go back into the
  session. Once the MR exists: headless self-review per commit (≤3 rounds,
  `prompts/mr-review.md`), pipeline and review threads watched (`mr.sh check`),
  failures/comments sent into the session, "ready to merge" announced once per
  commit. Merging is Tom's word: `dispatch.sh merge` → `mr.sh merge` (OUTWARD;
  a solicited "merge" confirms). `session.sh needs` (poller) reports sessions
  stuck on prompts, idle questions, and endings.
- **UI MRs get a visual review before merge** (`ui_review`, Tom's rule): an MR
  whose diff touches `ui_review_paths[<repo>]` (e.g. `mobile/`) is never
  auto-merged. When it goes green, `tick` boots the branch in the iOS simulator
  (`sim.sh`), kicks a session to make the change visible (demo data + feature
  flag, per `~/.margie/process/<repo>.md`) and screenshot it, then opens the shot
  on Tom's Mac, Slack-pings him and leaves the sim running — merge waits for his
  explicit "merge". Backend-only MRs auto-merge as before. `mr.sh resolve`
  resolves review threads once a session has addressed them.
- **Jev is the harness's classifier, not a brain** (`scripts/jev.sh`,
  `sidecar/src/jev.ts`; TypeSafe's System One model, ~300 ms, key
  `typesafe_api_key`, `jev: off` disables). It answers the small typed questions
  the code used to guess with regexes and never generates text or runs anything:
  `session.sh needs` triages an idle session (question | handoff |
  transient_error | checkpoint) BEFORE waking the brain — done summaries,
  surveys and connection drops no longer cost a 10–100 s Claude turn;
  `slack-watch.sh` skips mentions that aren't addressed to her ("margie already
  did that"); a session's permission prompt gets a second risk opinion that can
  only ADD an escalation; the confirm gate reads a short reply the regexes
  missed ("kk", "looks good, send it", "hold on") — approve only at ≥0.9
  confidence, "yes but…" is an edit and drops; `preBrief` picks which dispatch a
  status question is about; `dispatch.sh spec` asks whether a PT named in the
  request is the ticket TO WORK or only cited ("don't duplicate PT-1412"), so a
  request that mentions in-flight work never re-files it. Every decision fails
  closed to the old path and is one line in `~/.margie/jev.log`; `jev.sh check`
  runs the fixture set (run it when `jev-latest` moves). Don't give the brain
  `jev.sh` — it's for code. **Tom's rule (2026-09-21): every harness fix notes
  whether the decision it touches is a Jev question (typed, from text) or
  deterministic (a field, a status), and moves regex guesses onto Jev with a
  fixture.** A headless task's failure reason (`claude-task.sh why`:
  `terminal_reason` such as `budget_exhausted`) is deterministic — no Jev.
  Every decision, its gate, and what happens below the gate (all fail closed):

  | decision (`jev.sh` / `jev()`) | caller | acts when | below the gate |
  |---|---|---|---|
  | `session` kind + needs_operator | `session.sh needs` | kind conf ≥0.5 and needs <0.5 → skip checkpoint / transient / working | wake the brain (old path) |
  | `session` (QA hand-off) | `dispatch.sh tick` | idle + clean + ahead of main and kind ∈ {checkpoint, handoff} | wait for the marker |
  | `danger` risky | `session.sh needs` | HARD regex → Tom, always; SOFT word + Jev <0.35 → answer; otherwise the BRAIN judges once (SAFE → answer, ESCALATE/none → Tom with the reason) | SOFT word → escalate |
  | `mention` addressed | `slack-watch.sh` (colleague mentions, and Tom's untagged thread replies; Tom tagging someone else is skipped deterministically) | no_reply ≥0.7 → don't compose | reply as before |
  | `ticket` intent | `dispatch.sh spec` | ≥0.9 either way | PT in first 64 chars = work it |
  | `ci_failure` cause | `dispatch.sh tick` | infrastructure ≥0.8 → retry the failed jobs once | send the red pipeline to the session |
  | `review_intent` | brain fast path | mention ≥0.9 → no fast path; session-sourced or colleague text never fast-paths | run `review-pr.sh` (old path) |
  | `reply` kind | brain confirm gate | approve ≥0.9 → run; decline/edit/other ≥0.75 | regex verdict (drop) |
  | `brief` dispatch | brain status pre-brief | ≥0.6 | title-overlap score |
  | `audience` group/owner | `slack-watch.sh brain_reply` | owner ≥0.6 (or a "FOR TOM:" reply) → Tom's DM, not the chat | post to the chat |
  | `notice` act/know/skip | `tom-ping.sh consider` | act ≥0.6, know ≥0.75 → queued, one Slack DM a batch | no ping (CLI still shows it) |
  | `notion` docs/none | brain `notionBrief` | docs ≥0.75 → search + read the best page | no Notion context (a PT number is always read) |
  | `preamble` | brain, every text reply | narration ≥0.6 → drop the opening self-talk paragraph | reply as written |
  | `mention` (agents) | `agent-messages.sh auto` | no_reply ≥0.7 → acknowledge only | brain composes a reply |
  | `correction` | brain, Tom's turns | ≥0.7 → fix + lessons.sh add; 0.4–0.7 → the brain decides | ordinary turn |
  | `agree` | `evals.py` grading | contradict ≥0.7 → factual fail; anything but agree → "doesn't state the fact" | — |

  `jev.sh outcome <decision> <what>` (and `jevOutcome()` in TS) writes what the
  caller DID next to the answer in `~/.margie/jev.log` — grep `outcome` to see
  escalate(hard) / clear(jev) / retry / brain / skip counts. `jev.sh auto` (poller,
  5 min) runs the fixtures nightly and whenever the served model id changes, logs
  to `~/.margie/jev-check.log`, and Slacks Tom only on a FAIL.
- **Confirm-first is code, not prose.** The sidecar's `OUTWARD` gate holds
  any send-on-Tom's-behalf command, makes the model read it back, and executes
  it verbatim only on Tom's short affirmative (regex, or Jev at ≥0.9) within
  15 minutes; anything else drops it. The one other confirmation is Tom's own ✅
  reaction on an `approve.sh` message, which is tied to one MR and one commit. The prompt-only rule was skipped by the model in testing.

## Build & verify

```bash
npm run build                                   # frontend typecheck + bundle
cd sidecar && npm run build                     # brain → sidecar/dist/index.js
cargo check --manifest-path src-tauri/Cargo.toml
echo '{"id":1,"text":"hello"}' | node sidecar/dist/index.js   # protocol smoke test
DRY_RUN=1 scripts/kickoff-claude.sh "$PWD" "prompt"           # dispatcher without launching Warp
npm run tauri dev                               # run the overlay
```

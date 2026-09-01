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

- **Brain (`sidecar/src/index.ts`) runs on the xAI chat API with one guarded
  `bash` tool** — not the Claude Agent SDK and not `bypassPermissions` as
  README/AGENTS.md still say. Safety guards (`DENY` regexes: no `git push/
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
  tick|open|close`. Planner/QA output is schema-validated JSON in
  `~/.margie/dispatch/<id>/`; `file|go|close` are OUTWARD-held; `tick` is
  bookkeeping under the `go` confirmation (including Done-on-merge, Tom's
  explicit choice). Ticket/testcase/page writes go through `notion.sh`, whose
  every write honors `MARGIE_DESCRIBE=1` — keep it that way, the gate's
  read-back depends on it.
- **Confirm-first is code, not prose.** The sidecar's `OUTWARD` gate holds
  any send-on-Tom's-behalf command, makes the model read it back, and executes
  it verbatim only on a ≤6-word affirmative within 3 minutes; anything else
  drops it. The prompt-only rule was skipped by the model in testing.

## Build & verify

```bash
npm run build                                   # frontend typecheck + bundle
cd sidecar && npm run build                     # brain → sidecar/dist/index.js
cargo check --manifest-path src-tauri/Cargo.toml
echo '{"id":1,"text":"hello"}' | node sidecar/dist/index.js   # protocol smoke test
DRY_RUN=1 scripts/kickoff-claude.sh "$PWD" "prompt"           # dispatcher without launching Warp
npm run tauri dev                               # run the overlay
```

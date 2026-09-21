# Margie — Agent Notes

Guidance for AI agents (Claude Code etc.) working in this repo.

## What this is

Margie is a personal desktop assistant: a Tauri 2 overlay app (Rust shell +
React/TS webview) with a Node sidecar brain running the Claude Agent SDK.
Read `ARCHITECTURE.md` before structural changes.

## Layout

- `src/` — React UI. Three forms (Orb, CommandBar, Panel) switched in
  `App.tsx`; window resize happens via the `set_form` Tauri command.
- `src-tauri/` — Rust shell. `lib.rs` (window/forms), `brain.rs` (sidecar
  bridge). Capabilities in `capabilities/default.json`; camera/mic usage
  strings in `Info.plist`.
- `sidecar/` — Node brain. Protocol: one JSON request on stdin →
  one JSON response on stdout. Built output must land in `sidecar/dist/`
  (the Rust bridge looks for `sidecar/dist/index.js`).

## Conventions

- Branch per feature, branched from `main`; rebase (not merge) to update.
- Keep PRs focused; reference the issue in branch name and PR description.
- New features need tests where the layer supports them (Rust: `cargo test`;
  sidecar: add vitest when the protocol grows).
- Update README.md/AGENTS.md for user-visible or structural changes.

## Build & check

```bash
npm run build                  # frontend typecheck + bundle
cargo check --manifest-path src-tauri/Cargo.toml
cd sidecar && npm run build    # brain
npm run tauri dev              # run the app
```

## Gotchas

- The overlay window is transparent + undecorated; `macOSPrivateApi: true`
  is required for transparency on macOS.
- Window drag uses `data-tauri-drag-region` attributes — don't remove them.
- **Two windows.** `main` (overlay) and `holo` (Looking Glass hologram, opened
  by `hologram.rs` when a 1440×2560 display is present). Both are listed in
  `capabilities/default.json`; a new command either window calls must stay
  reachable from both. The holo window is a pure consumer of `margie:holo`
  events — never give it brain access or outward helpers. Its canvas must map
  1:1 onto the panel's physical pixels (no CSS scaling, no overlays in the
  normal path). The avatar (`~/.margie/avatar/margie.vrm`) and the calibration
  cache (`~/.margie/lkg/`) are runtime state, never repo content.
- `holoplay-core` (Looking Glass) has a node-only `require("ws")` branch;
  `vite.config.ts` aliases `ws` to an empty module. Keep that alias.
- Adding `@tauri-apps/api` window calls may require new permissions in
  `capabilities/default.json`.
- Margie's replies are spoken aloud — keep the sidecar system prompt tuned
  for short conversational output, never markdown.
- **The brain is per-channel**: voice → xAI chat API; terminal/Slack → Claude
  Agent SDK on Tom's plan (`claudeTurn` in `brain.ts`, our guarded `bash` as the
  only tool, `tools: []`, `settingSources: []`, `bypassPermissions` because the
  gate is the permission system). Same history and gates for both. Margie is a *dispatcher*: the
  `DENY` regexes in the sidecar refuse `git push/commit`, `gh pr
  review/merge`, `rm`, `sudo`, etc. — real work happens in the watchable Warp
  sessions her scripts spawn. Extend the guards; don't loosen them. A second
  deterministic gate (`OUTWARD` in the sidecar) HOLDS anything that sends on
  Tom's behalf (`slack.sh send`, `gmail.sh send`, `messages.sh send`,
  `jira.sh create/comment`, `notion.sh create/append`, `mr.sh create/update`,
  `dispatch.sh file/go/close/spike`) until his short "yes" on the next turn — add new
  outward helpers to that list rather than trusting the prompt.
- Nothing may hardcode a user path. The sidecar derives `MARGIE_HOME` from
  its own location and puts `$MARGIE_HOME/scripts` on PATH for every command;
  Coding sessions, reviews and headless tasks run **Claude Code** (`engine` in
  `~/.margie/config.json` / `MARGIE_ENGINE` can swap it); the Slack watcher
  composes with `claude -p` and all tools stripped. `forge` (`gitlab` |
  `github`) picks `glab`/`gh`,
  MR/PR vocabulary and the matching write-guards — when you add a forge
  command anywhere, add it for both. See `config.example.json` for every key.
- `slack.sh` has two backends: raw Web API with a config token, or (default
  here) Claude Code's Slack connector via `claude -p --allowedTools
  mcp__claude_ai_Slack__…` — keep the allowed-tool lists minimal per
  subcommand (send gets send + lookup tools only). `slack-watch.sh` still
  needs a bot token.
- Headless tasks live in `~/.margie/tasks/<id>.{meta,log,json}` and are
  managed only through `scripts/claude-task.sh` (start/status/result/followup/
  stop) — don't teach the brain raw `claude -p`.
- The sidecar is now several modules: ALL shared state (history, `pending`,
  gates, queue) lives in `brain.ts` only; `server.ts` is the socket daemon +
  pollers; `index.ts` keeps the stdio mode for smoke tests; `client.ts`/
  `cli.ts` are the `margie` terminal client. Never put brain state anywhere
  but brain.ts. After `npm run build` the daemon drains and restarts itself.
- dispatch.sh is the product/architecture/QA pipeline; its planner and QA
  stages are headless Claude runs with JSON schemas (`scripts/schemas/`) and
  prompts (`scripts/prompts/`). Notion writes go through notion.sh, which must
  keep `MARGIE_DESCRIBE=1` side-effect-free on EVERY write subcommand — the
  sidecar uses it to read back exactly what a held command will do.
- `jev.sh` / `sidecar/src/jev.ts` (TypeSafe's Jev) is a calibrated classifier
  the harness code calls for typed decisions (session triage, Slack mention
  addressed?, prompt risky?, was a short reply a yes/no, which dispatch a status
  question means). It is confidence-gated and fails closed to the previous
  regex/brain path; the brain never calls it. New decision → a subcommand in
  `jev.sh` (or a `jev()` call in TS) plus a fixture in `jev.sh check`.
- The brain is a small, fast, non-reasoning model: it is unreliable with long
  piped one-liners and tends to open a Warp session instead. Anything she
  should do inline gets a tested helper script with trivial subcommands
  (`forge.sh`, `slack.sh`, `messages.sh`…) and the prompt points at that —
  don't teach her raw multi-step shell.

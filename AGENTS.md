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
- Adding `@tauri-apps/api` window calls may require new permissions in
  `capabilities/default.json`.
- Margie's replies are spoken aloud — keep the sidecar system prompt tuned
  for short conversational output, never markdown.
- **The sidecar runs with `permissionMode: "bypassPermissions"`** — Margie
  has full machine access by design (Tom's explicit choice). The only guard
  is the confirm-first rule for destructive actions in her system prompt.
  To restrict her, switch to `permissionMode: "default"` and restore an
  `allowedTools` whitelist in `sidecar/src/index.ts`.
- Dispatched Claude Code tasks log to `~/.margie/tasks/*.log`; Margie reads
  these for status reports.

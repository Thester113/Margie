# Margie — Architecture

## Overview

```
┌──────────────────────────────────────────────────────────┐
│  Tauri shell (Rust)                                      │
│  • transparent, always-on-top overlay window             │
│  • set_form: resizes window to orb / bar / panel         │
│  • brain.rs: bridges UI ↔ Node sidecar                   │
│  • (planned) audio.rs: wake-word + whisper.cpp STT       │
│  • (planned) pty.rs: spawn & drive `claude` CLI sessions │
└───────────────▲──────────────────────────┬───────────────┘
                │ invoke/events            │ spawn, JSON over stdio
┌───────────────┴───────────────┐  ┌───────▼───────────────┐
│  WebView UI (React + TS)      │  │  Sidecar (Node + TS)  │
│  • Orb / CommandBar / Panel   │  │  • Claude Agent SDK   │
│  • useVoice: mic level, TTS   │  │  • Margie persona     │
│  • useCamera: preview +       │  │  • (planned) vision,  │
│    JPEG snapshots             │  │    task dispatch      │
└───────────────────────────────┘  └───────────────────────┘
```

## Why this shape

- **Tauri** keeps the always-running overlay light (~30MB) versus Electron.
- **The brain is a Node sidecar** because the Claude Agent SDK is
  TypeScript-native while Tauri's core is Rust. The Rust shell owns the
  process lifecycle; the protocol is JSON over stdio (v0: one
  request/response per spawn; v1: long-lived process, streaming NDJSON).
- **STT belongs on the Rust side** — whisper.cpp bindings (`whisper-rs`) and a
  wake-word engine run natively; the webview streams PCM frames to Rust.
- **TTS is a swap-in point** — `useVoice.speak()` currently uses
  `speechSynthesis`; replacing it with cloud TTS means fetching audio through
  the sidecar and playing it via Web Audio, no UI changes.

## The three forms

`set_form` (Rust command) resizes the window; the frontend renders the
matching component. Sizes live in `src-tauri/src/lib.rs`.

| Form | Size | Purpose |
|---|---|---|
| `orb` | 120×120 | Resting state; draggable; click to open bar |
| `bar` | 560×72 | One-line quick commands, mic toggle |
| `panel` | 440×640 | Conversation, camera preview, full input |

## Voice pipeline (target)

1. Rust captures mic audio continuously; a local wake-word model gates on
   "Margie".
2. On wake, audio is transcribed by whisper.cpp locally; the transcript is
   emitted to the UI and sent to the brain.
3. The brain's reply is synthesized by cloud TTS (Margie's voice) and played
   by the UI. `useVoice` drives orb animation from state
   (idle/listening/thinking/speaking).

## Claude Code control (target)

Two tiers:

- **Agent SDK (headless)** — the sidecar runs `query()` for research, quick
  answers, and small tasks with read-only tools.
- **PTY sessions (interactive)** — for real coding tasks, Rust spawns
  `claude` in a PTY (`portable-pty`), Margie writes prompts to it and parses
  output; the panel gains a "sessions" view so Tom can watch or take over.

## Security notes

- Camera/mic permission strings: `src-tauri/Info.plist`.
- The sidecar inherits Claude Code credentials from the environment — no keys
  are stored in this repo. `.env` is gitignored.
- The webview has no remote content; CSP is currently `null` (dev) and should
  be tightened before any distribution.

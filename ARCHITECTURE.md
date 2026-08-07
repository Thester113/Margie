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

## Voice pipeline (implemented)

STT runs entirely on-device via whisper.cpp:

1. **Rust** (`stt.rs`) owns the process lifecycle only: it spawns
   `whisper-server` (Homebrew `whisper-cpp`) once, loading
   `~/.margie/models/ggml-base.en.bin`, and kills it on app exit.
2. **Webview** (`useWakeWord.ts`) captures the mic, runs an energy-based VAD
   to segment speech into whole phrases, downsamples each to 16 kHz, WAV-encodes
   it, and POSTs to `http://127.0.0.1:8178/inference`. Audio never leaves the
   machine.
3. **Wake FSM**: transcripts are scanned for "Margie". "Margie, open Safari"
   in one breath dispatches immediately; a bare "Margie" wakes her and the next
   phrase becomes the command. Non-speech tokens (`[BLANK_AUDIO]`, etc.) are
   stripped. VAD/timeout constants live at the top of `useWakeWord.ts`.
4. Commands render as text (a user message) and go to the brain. Capture is
   muted while `voice.status === "speaking"` so she doesn't hear herself.

TTS is still `speechSynthesis` (best installed voice); cloud TTS is the swap
point in `useVoice.speak()`.

A separate wake-word engine (Porcupine etc.) was intentionally avoided —
continuous whisper transcription + a regex trigger needs no extra model or
API key.

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

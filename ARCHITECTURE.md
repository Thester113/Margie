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

## The hologram window (Looking Glass)

A second Tauri window, label `holo`, owned by `src-tauri/src/hologram.rs`:

- **Placement.** A watcher thread polls the monitors every 5 s. The Looking
  Glass is matched by physical size (the Go is 1440×2560; tao names monitors
  "Monitor #N", so names are useless) or by `hologram_monitor` in the config.
  The window is borderless, black, never focused, always on top, sized to the
  panel and put in macOS simple-fullscreen (hides the menu bar without a
  Space). Unplug → closed; replug → reopened. `hologram: "off"` disables it.
- **One bundle, two entries.** `main.tsx` mounts `<Hologram/>` (code-split)
  when the URL carries `?view=holo`, otherwise the normal `<App/>`.
- **Rendering** (`src/holo/`): the display shows a *quilt* — a grid of views
  (11×6 on the Go, 4092²) — swizzled onto its subpixels by Looking Glass's
  lenticular shader (`holoplay-core`'s `Shader`). `quilt.ts` drives a
  three.js `ArrayCamera` of 66 off-axis cameras sharing one focal plane (the
  maths from the official WebXR library, which itself can't run in a WKWebView)
  into a render target, then a full-screen `RawShaderMaterial` pass. The canvas
  is sized to the panel's physical pixels; any CSS scaling breaks the lens
  mapping.
- **Calibration** (`calibration.ts`) comes from Looking Glass Bridge — its
  HoloPlay driver websocket first, its REST API second — and is cached by Rust
  in `~/.margie/lkg/calibration.json` so Bridge needn't run afterwards.
- **The character** (`character.ts`) is loaded from `~/.margie/avatar/` via the
  `read_avatar` command (binary IPC). `CharacterBase` owns the behaviour —
  blinking, breathing, gaze at the viewer, per-state posture/expressions and
  amplitude-driven mouth shapes — and drives a format adapter: `vrmCharacter.ts`
  (VRM via `@pixiv/three-vrm`) or `arkitCharacter.ts` (any GLB with ARKit-52
  blendshapes / Oculus visemes and a Head/Neck/Spine skeleton). The loader
  sniffs which one the file is.
- **State bus** (`src/lib/holoBus.ts`): the overlay window broadcasts
  `margie:holo` Tauri events — status changes, the sentence about to be
  spoken with its timed mouth shapes (`src/lib/visemes.ts`, built from
  ElevenLabs' with-timestamps character alignment), and ~30 Hz
  level/centroid/progress/audio-time metered from her own TTS audio through
  an `AnalyserNode` (`useVoice.ts`). The character plays the viseme track
  against the audio clock and uses loudness only as a gate; voices without
  timing fall back to amplitude. The hologram only listens; it never talks to
  the brain or anything outward.
- **Captions** (`caption.ts`) are a canvas-textured plane on the focal plane
  (zero depth, so they stay sharp), chunked and advanced by speech progress.

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

## Claude Code harness (implemented)

Margie is a dispatcher: the brain never edits code or reviews anything itself —
it picks the one right helper, runs it, and reports one sentence. Three tiers:

- **Interactive Warp session (primary)** — `scripts/kickoff-claude.sh <dir>
  <prompt>` writes a Warp Launch Configuration and opens it via the
  `warp://launch/<name>` URI, starting `claude "<prompt>"` inside a tmux session
  (`margie-<stamp>`, or `margie-<branch>` for `--worktree`) in a new Warp tab
  Tom can watch and take over. `session.sh read|send|list` captures the pane
  or injects follow-ups into that same session, so Margie can relay what a
  session is asking and act on Tom's spoken answer. Deterministic — no
  AppleScript keystrokes, no Accessibility permission; prompts go through
  files to dodge quoting.
- **Headless task** — `scripts/claude-task.sh start <dir> "<task>"` runs
  `claude -p … --output-format json` detached, recording `<id>.{meta,log,json}`
  under `~/.margie/tasks/`. `status` shows RUNNING/DONE/FAILED with a gist,
  `result` prints the outcome (plus turns/cost/session id), `followup` resumes
  the same Claude session with a new prompt, `stop` kills it.
- **Review session** — `scripts/review-pr.sh <n> <repo>` validates the MR/PR
  (`glab mr view` / `gh pr view`), then opens a watchable Claude Code session
  in the repo with a review prompt (or a repo-local `review_skill`).

The brain runs with an in-sidecar deny-list (no `git push/commit`, no forge
writes, no `rm`/`sudo`) so anything outward happens only in those supervised
sessions. `engine` in `~/.margie/config.json` can swap the session CLI.

## The shared brain daemon

The sidecar is a daemon on `~/.margie/brain.sock` (NDJSON, 0600).
`sidecar/src/brain.ts` owns ALL shared state — conversation history, the held
outward command, the DENY/OUTWARD gates, the single-writer turn queue — and
`server.ts` serves it to every client: the Tauri shell (`brain.rs` connects,
spawning `node dist/index.js --daemon` on demand) and any number of `margie`
CLIs in Warp. Whoever asked gets the reply; a "yes" in any client confirms the
one held command. Lifecycle: detaching launcher, `~/.margie/brain.lock`
(O_EXCL) as the single-daemon arbiter, drain-and-exit when `dist/index.js` is
rebuilt, stdio mode kept for smoke tests
(`echo '{"id":1,"text":"hi"}' | node sidecar/dist/index.js`).

The daemon also hosts the pollers: `dispatch.sh tick` and `claude-task.sh
notify` every minute, `agent-messages.sh check` every five — each silent when
idle; any output becomes a notice (into history, broadcast to clients, and a
spoken announcement via `~/.margie/announce/` while the app is connected).

## The dispatch pipeline (product → architecture → QA)

`scripts/dispatch.sh` drives one feature from words to merged MR:
`spec` (headless Claude planner in the repo, JSON-schema'd output) → `show`
(spoken summary + open questions) → `go` [held for Tom's yes] = `file` (Notion
ticket in the team Tickets DB, Test Cases rows, spec child page) + `implement`
(worktree branch `margie/PT-###-…`, watchable session seeded with the spec) →
`qa` (read-only verifier: per-criterion evidence, test run, sabotage record,
ADR findings, full MR text draft) → `tick` (writes QA back to Notion, flips
ticket status, detects the merged MR → Done). State in `~/.margie/dispatch/`.

## Security notes

- Camera/mic permission strings: `src-tauri/Info.plist`.
- The sidecar inherits Claude Code credentials from the environment — no keys
  are stored in this repo. `.env` is gitignored.
- The webview has no remote content; CSP is currently `null` (dev) and should
  be tightened before any distribution.

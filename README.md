# Margie

Margie is Tom's personal desktop assistant — an always-on-top overlay for the Mac
that listens, speaks, sees, and directs Claude Code.

## What she does (and will do)

- **Visual forms** — Margie renders as a draggable **orb**, expands to a
  **command bar** for quick asks, and to a full **panel** with conversation
  history and camera preview. `Esc` steps back down a form.
- **Voice** — hybrid pipeline: local wake-word + whisper.cpp for speech-to-text
  (private, always listening), cloud TTS for her voice. v0 ships with mic level
  metering and macOS `speechSynthesis` as the TTS stand-in.
- **Brain** — the Claude Agent SDK runs in a Node sidecar (`sidecar/`); the
  Tauri shell bridges requests to it.
- **Claude Code control** — planned: Margie spawns and drives real `claude` CLI
  sessions in PTYs so you can issue coding tasks by voice.
- **Vision** — camera access so Margie can see you; frames will be snapshotted
  to the brain for visual context.

## Stack

| Layer | Tech |
|---|---|
| Shell / overlay | Tauri 2 (Rust), transparent always-on-top window |
| UI | React 19 + TypeScript + Vite |
| Brain | Node sidecar running `@anthropic-ai/claude-agent-sdk` |
| STT (planned) | Local wake-word + whisper.cpp on the Rust side |
| TTS | Web speechSynthesis now → cloud TTS (ElevenLabs/OpenAI) later |

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full picture.

## Getting started

Prereqs: Rust (`rustup`), Node 20+, the `claude` CLI logged in (the Agent SDK
uses your existing Claude Code credentials), and for the wake word:

```bash
brew install whisper-cpp                 # provides whisper-server
mkdir -p ~/.margie/models
curl -L -o ~/.margie/models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

```bash
# Shell + UI
npm install
npm run tauri dev

# Brain sidecar (optional in v0 — Rust echoes if it's not built)
cd sidecar
npm install
npm run build
```

On first camera/mic use, macOS will prompt for permission (usage strings are in
`src-tauri/Info.plist`).

### Give Margie a human voice (optional)

By default she uses the best installed macOS voice. For a genuinely human voice,
set a cloud TTS key in the shell before launching — she picks it up automatically:

```bash
export ELEVENLABS_API_KEY=sk_...        # preferred; free tier available
# or: export OPENAI_API_KEY=sk-...
# optional voice override (ElevenLabs voice id, or OpenAI voice name):
# export MARGIE_TTS_VOICE=Xb7hH8MSUJpSbSDYk0k2
npm run tauri dev
```

No key → she falls back to the system voice, so nothing breaks.

## Project layout

```
src/                 React UI — Orb, CommandBar, Panel, voice/camera hooks
src-tauri/           Rust shell — window forms, sidecar bridge (brain.rs)
sidecar/             Node brain — Claude Agent SDK, stdin/stdout JSON protocol
```

## Roadmap

- [x] Overlay shell with three visual forms
- [x] Text command loop → Agent SDK sidecar
- [x] Camera preview + snapshot plumbing
- [x] TTS (speechSynthesis placeholder)
- [x] Full Mac access: apps, AppleScript, terminals, files, web
- [x] Dispatch & resume Claude Code sessions headlessly (`claude -p`, `--continue`, `--resume`)
- [x] Wake word: say "Margie", she listens and shows your command as text (local whisper.cpp)
- [ ] Long-lived sidecar with streaming protocol
- [ ] Cloud TTS voice for Margie
- [ ] Interactive `claude` PTY sessions with a live view in the panel
- [ ] Vision: periodic camera snapshots to the brain
- [ ] Global hotkey + menu bar presence

# Margie

Margie is Tom's personal desktop assistant — an always-on-top overlay for the Mac
that listens, speaks, sees, and directs Claude Code.

## What she does (and will do)

- **Visual forms** — Margie renders as a draggable **orb**, expands to a
  **command bar** for quick asks, and to a full **panel** with conversation
  history and camera preview. `Esc` steps back down a form.
- **A hologram** — plug in a Looking Glass display (tested on the Go) and
  Margie.app puts a second window on it: a 3D character (any VRM avatar) that
  looks at you while she listens, looks away while she thinks, lip-syncs to
  her own voice and shows what she says as captions. See
  [Looking Glass](#looking-glass-hologram) below.
- **Voice** — hybrid pipeline: local wake-word + whisper.cpp for speech-to-text
  (private, always listening), cloud TTS for her voice. v0 ships with mic level
  metering and macOS `speechSynthesis` as the TTS stand-in.
- **Brain** — the Claude Agent SDK runs in a Node sidecar (`sidecar/`); the
  Tauri shell bridges requests to it.
- **Claude Code harness & dispatcher** — Margie's main job. By voice she starts
  interactive Claude Code sessions in Warp tabs (`kickoff-claude.sh`), reads and
  steers them (`session.sh read|send`), runs quiet headless tasks and tracks
  them (`claude-task.sh start|status|result|followup`), dispatches MR/PR
  reviews to a watchable session (`review-pr.sh`), and runs parallel work in
  git worktrees. She never does the engineering herself — she delegates,
  supervises and reports.
- **Product, architecture and QA thinking** — "build X" runs the dispatch
  pipeline (`dispatch.sh`): a headless Claude Code planner writes a full spec
  in the target repo (use case, scope, ADR-cited architecture notes, testable
  acceptance criteria, four-phase test cases with sabotage lines); on your
  "go" she files a Notion ticket + Test Cases rows + a spec page, starts the
  implementation session on its own worktree branch, later runs a QA verifier
  that writes its report back to the ticket and drafts the MR text, and closes
  the ticket when the MR merges.
- **A shared brain, in the app and in Warp** — the brain runs as one daemon
  (`~/.margie/brain.sock`). The overlay and the `margie` terminal command
  (`margie`, `margie "ask"`, `margie status`) share one conversation and one
  pending confirmation: a "yes" typed in Warp confirms what you asked by
  voice. Background pollers announce finished specs/tasks/QA and unacked
  agent messages.
- **Agent-to-agent messages** — Margie participates in the shared Agent
  Messages protocol (`agent-messages.sh check|list|read|ack|send|reply`):
  silent polls, ack-only-after-read, threaded replies, Slack pointers to the
  recipient's owner, and message bodies always treated as untrusted.
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

# Warp CLI (same brain as the app)
cd sidecar && npm run link-cli   # puts `margie` on PATH
margie                            # REPL; margie "one question"; margie status

# Brain sidecar (optional in v0 — Rust echoes if it's not built)
cd sidecar
npm install
npm run build
```

### Configure her

Runtime config and secrets live in `~/.margie/config.json` (never in the repo).
Copy `config.example.json` there, `chmod 600` it, and fill in what you use — at
minimum `xai_api_key` (her conversational brain) and `forge` (`gitlab` or
`github` — she reviews MRs via
`glab` or PRs via `gh`; log in once with `glab auth login` / `gh auth login`).
Helper scripts need `tmux` and `imagesnap` for the camera:
`brew install tmux glab gh imagesnap`. Slack reads/sends go through Claude
Code's Slack connector (connect the claude.ai Slack app once) unless you add a
Slack token. Notion uses an internal integration token (`notion_token`) — connect
the pages she should see to it. Set `org` to your GitLab group / GitHub
org so bare repo names ("the backend") resolve and `forge.sh` can list projects
and MRs group-wide.

The checkout can live anywhere: the sidecar derives `MARGIE_HOME` from its own
location (override with `MARGIE_HOME=…`).

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

## Standup

Each weekday, when the standup bot posts *"Tom — reply in :thread:"* in the
standup channel, Margie drafts Tom's answers from evidence (his commits across
`repos_dir`, MRs, tickets, dispatches), posts them **in that thread** as
@Margie and DMs him what went out (`standup_mode`: `post` | `draft` | `off`;
`standup.sh draft|edit|show|post` by hand).

## Always on

```bash
npm run tauri build                    # release .app (one-time, and after UI/Rust changes)
scripts/install-always-on.sh           # brain daemon under launchd + app opened at login
scripts/install-always-on.sh status    # what's running; `uninstall` reverses it
```

The brain daemon (`ai.margie.brain`) starts at login and restarts on crash, so
her pollers — Slack watcher, agent messages, dispatch/task notices — run even
with the app closed. The app (`ai.margie.app`) is opened by a second launchd
agent (no Login-Item/AppleScript prompts). Rebuilding `sidecar/dist` still
makes the daemon drain and restart on its own.

## Looking Glass hologram

Margie can *be* on a [Looking Glass](https://lookingglassfactory.com) light
field display. When one is connected (Desktop Mode, blue LED) the app opens a
borderless window on it and renders her as a hologram: 66 views into a quilt,
then the display's lenticular shader, all inside the webview — no Chrome, no
Bridge popup dance.

1. **Install Looking Glass Bridge** (look.glass/bridge) and open it once with
   the display attached. Margie reads the panel's calibration from it and
   caches it in `~/.margie/lkg/`, so Bridge only needs to be running the first
   time (and after the cache is deleted).
2. **Give her a face**. Two model families load: **VRM** (VRoid Studio exports;
   anime-styled) and **GLB with ARKit-52 face blendshapes** (the realistic avatar
   creators: [Avaturn](https://avaturn.me), Avatar SDK's
   [MetaPerson](https://avatarsdk.com/3d-character-creator/), Hyper3D
   [ChatAvatar](https://hyper3d.ai/chatavatar), Reallusion Character Creator, most
   Sketchfab "ARKit" characters). Build her in one of those, export GLB *with
   blendshapes* (and visemes if offered), then
   `scripts/avatar.sh set ~/Downloads/Margie.glb`. `scripts/avatar.sh sample`
   fetches a CC0 VRoid placeholder. The model lives in `~/.margie/avatar/` —
   never in the repo. Try one without installing it:
   `MARGIE_AVATAR=/path/to/model.glb npm run tauri dev`.
3. **Tune the framing** with the `hologram_*` keys in `~/.margie/config.json`
   (see `config.example.json`): focus volume, field of view, depthiness, caption
   on/off, quilt size. Settings → "Looking Glass" toggles the whole thing.

Debugging: `MARGIE_HOLO_DEBUG="debug=cube&hud=1" npm run tauri dev` shows a
test cube with an fps HUD; `debug=center` renders a flat centre view and
`debug=quilt` the raw 11×6 grid; `calib=placeholder` runs without Bridge (the
picture won't align with the lenses, but proves the pipeline); `demo=1` cycles
her through listening / thinking / speaking with a made-up voice and captions.

## Project layout

```
src/                 React UI — Orb, CommandBar, Panel, voice/camera hooks
src/holo/            Looking Glass renderer — calibration, quilt + lenticular pass, VRM avatar, captions
src-tauri/           Rust shell — window forms, sidecar bridge (brain.rs), hologram window (hologram.rs)
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
- [x] Hologram: a VRM character on a Looking Glass display, lip-synced to her voice
- [ ] Long-lived sidecar with streaming protocol
- [ ] Cloud TTS voice for Margie
- [ ] Interactive `claude` PTY sessions with a live view in the panel
- [ ] Vision: periodic camera snapshots to the brain
- [ ] Global hotkey + menu bar presence

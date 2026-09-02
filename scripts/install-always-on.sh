#!/bin/bash
# install-always-on.sh — make Margie run all the time on this Mac.
#
#   1. Brain daemon under launchd (starts at login, restarts on crash, survives
#      the app and every terminal closing). Pollers (Slack watcher, agent
#      messages, dispatch/task notices) therefore run 24/7.
#   2. The overlay app opened at login by a second launchd agent — from the
#      release build (`npm run tauri build`) installed into /Applications.
#
#   install-always-on.sh            install/refresh both (app step skipped if no build)
#   install-always-on.sh daemon     just the launchd agent
#   install-always-on.sh app        just copy the release .app + start-at-login agent
#   install-always-on.sh status     what's running
#   install-always-on.sh uninstall  remove both launchd agents
#
# Paths are derived from this checkout; nothing is hardcoded.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$DIR/.." && pwd)"
LABEL="ai.margie.brain"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
NODE="$(command -v node || ls /opt/homebrew/bin/node /usr/local/bin/node 2>/dev/null | head -1)"
UID_="$(id -u)"
APP_SRC="$(ls -d "$ROOT"/src-tauri/target/release/bundle/macos/*.app 2>/dev/null | head -1)"
APP_DST="/Applications/Margie.app"

install_daemon() {
  [ -f "$ROOT/sidecar/dist/index.js" ] || { echo "Build the sidecar first: cd sidecar && npm run build" >&2; return 1; }
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.margie"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$ROOT/sidecar/dist/index.js</string>
    <string>--daemon</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MARGIE_DAEMON_CHILD</key><string>1</string>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>WorkingDirectory</key><string>$ROOT/sidecar</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/.margie/daemon.log</string>
  <key>StandardErrorPath</key><string>$HOME/.margie/daemon.log</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null || { echo "plist invalid" >&2; return 1; }
  # Hand over from any on-demand daemon to the launchd-owned one.
  "$ROOT/bin/margie" stop >/dev/null 2>&1 || true
  sleep 1
  launchctl bootout "gui/$UID_/$LABEL" >/dev/null 2>&1 || true
  # bootout is asynchronous — wait for the old service to be gone, then bootstrap (retrying).
  for _ in $(seq 1 20); do launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
  for _ in $(seq 1 5); do
    launchctl bootstrap "gui/$UID_" "$PLIST" 2>/dev/null && { echo "Brain daemon installed under launchd ($LABEL) — starts at login, restarts on crash."; return 0; }
    sleep 1
  done
  echo "launchctl bootstrap kept failing — try: launchctl bootstrap gui/$UID_ $PLIST" >&2; return 1
}

APP_LABEL="ai.margie.app"
APP_PLIST="$HOME/Library/LaunchAgents/$APP_LABEL.plist"

install_app() {
  [ -n "$APP_SRC" ] || { echo "No release build yet — run: npm run tauri build   (then re-run: install-always-on.sh app)"; return 1; }
  pkill -f "Margie.app/Contents/MacOS" 2>/dev/null; sleep 1
  rm -rf "$APP_DST" && cp -R "$APP_SRC" "$APP_DST" && echo "Installed $APP_DST"
  # Start-at-login via a launchd agent that simply opens the app: no Login Item,
  # no AppleScript, so no macOS Automation permission prompt. RunAtLoad opens it
  # now; launchd re-runs it at every login.
  cat > "$APP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$APP_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-a</string><string>$APP_DST</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
EOF
  plutil -lint "$APP_PLIST" >/dev/null || { echo "app plist invalid" >&2; return 1; }
  launchctl bootout "gui/$UID_/$APP_LABEL" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do launchctl print "gui/$UID_/$APP_LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
  for _ in $(seq 1 5); do launchctl bootstrap "gui/$UID_" "$APP_PLIST" 2>/dev/null && break; sleep 1; done
  echo "Margie.app opens at login ($APP_LABEL) — and is opening now."
}

status() {
  if launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1; then
    echo "daemon: launchd-managed (pid $(cat "$HOME/.margie/brain.lock" 2>/dev/null || echo ?))"
  else echo "daemon: NOT under launchd (on-demand only)"; fi
  [ -d "$APP_DST" ] && echo "app: $APP_DST installed" || echo "app: not installed in /Applications"
  pgrep -fq "Margie.app/Contents/MacOS" && echo "app: running" || echo "app: not running"
  launchctl print "gui/$UID_/$APP_LABEL" >/dev/null 2>&1 && echo "app at login: yes ($APP_LABEL)" || echo "app at login: no"
}

uninstall() {
  launchctl bootout "gui/$UID_/$LABEL" >/dev/null 2>&1; rm -f "$PLIST"
  launchctl bootout "gui/$UID_/$APP_LABEL" >/dev/null 2>&1; rm -f "$APP_PLIST"
  echo "Removed both launchd agents (app bundle left in /Applications)."
}

case "${1:-all}" in
  all) install_daemon; install_app || true; echo; status ;;
  daemon) install_daemon ;;
  app) install_app ;;
  status) status ;;
  uninstall) uninstall ;;
  *) echo "usage: install-always-on.sh [all|daemon|app|status|uninstall]" >&2; exit 1 ;;
esac

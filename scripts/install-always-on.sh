#!/bin/bash
# install-always-on.sh — make Margie run all the time on this Mac.
#
#   1. Brain daemon under launchd (starts at login, restarts on crash, survives
#      the app and every terminal closing). Pollers (Slack watcher, agent
#      messages, dispatch/task notices) therefore run 24/7.
#   2. The overlay app as a Login Item — from the release build
#      (`npm run tauri build`) installed into /Applications.
#
#   install-always-on.sh            install/refresh both (app step skipped if no build)
#   install-always-on.sh daemon     just the launchd agent
#   install-always-on.sh app        just copy the release .app + add the Login Item
#   install-always-on.sh status     what's running
#   install-always-on.sh uninstall  remove the launchd agent + Login Item
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
  launchctl bootstrap "gui/$UID_" "$PLIST" && echo "Brain daemon installed under launchd ($LABEL) — starts at login, restarts on crash."
}

install_app() {
  [ -n "$APP_SRC" ] || { echo "No release build yet — run: npm run tauri build   (then re-run: install-always-on.sh app)"; return 1; }
  rm -rf "$APP_DST" && cp -R "$APP_SRC" "$APP_DST" && echo "Installed $APP_DST"
  # Login Item (System Events). Replace any existing one.
  osascript >/dev/null 2>&1 <<EOF
tell application "System Events"
  repeat with li in (every login item whose name is "Margie")
    delete li
  end repeat
  make login item at end with properties {path:"$APP_DST", hidden:false}
end tell
EOF
  echo "Margie.app added as a Login Item."
}

status() {
  if launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1; then
    echo "daemon: launchd-managed (pid $(cat "$HOME/.margie/brain.lock" 2>/dev/null || echo ?))"
  else echo "daemon: NOT under launchd (on-demand only)"; fi
  [ -d "$APP_DST" ] && echo "app: $APP_DST installed" || echo "app: not installed in /Applications"
  pgrep -fq "Margie.app/Contents/MacOS" && echo "app: running" || echo "app: not running"
  osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | tr ',' '\n' | grep -q "Margie" && echo "login item: yes" || echo "login item: no"
}

uninstall() {
  launchctl bootout "gui/$UID_/$LABEL" >/dev/null 2>&1; rm -f "$PLIST"
  osascript -e 'tell application "System Events" to delete (every login item whose name is "Margie")' >/dev/null 2>&1
  echo "Removed launchd agent and Login Item (app bundle left in /Applications)."
}

case "${1:-all}" in
  all) install_daemon; install_app || true; echo; status ;;
  daemon) install_daemon ;;
  app) install_app ;;
  status) status ;;
  uninstall) uninstall ;;
  *) echo "usage: install-always-on.sh [all|daemon|app|status|uninstall]" >&2; exit 1 ;;
esac

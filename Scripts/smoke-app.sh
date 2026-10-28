#!/bin/bash
# Launches a built app for a few seconds in demo mode, to catch launch crashes such as a missing resource before a
# bundle ships. User state stays unchanged: preferences go to a temporary directory that is removed afterwards, demo
# mode neither scans nor starts anything, and the panel frame that AppKit saves in the app's defaults, which no launch
# option redirects, is put back once the app has quit.
set -euo pipefail
skip_without_gui=false
if [[ "${1:-}" == --skip-without-gui ]]; then
  skip_without_gui=true
  shift
fi
app="${1:?Usage: smoke-app.sh [--skip-without-gui] <Byte Ports.app>}"
executable="$app/Contents/MacOS/BytePorts"
fail() { printf 'Smoke launch of %s failed: %s\n' "$app" "$1" >&2; exit 1; }
[[ -x "$executable" ]] || fail 'Contents/MacOS/BytePorts is missing or not executable'
# AppKit needs a login session with a window server; SSH and background jobs have none.
if [[ "$(/bin/launchctl managername 2>/dev/null || true)" != Aqua ]]; then
  [[ "$skip_without_gui" == true ]] || fail 'no GUI login session'
  notice=''
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then notice='::notice::'; fi
  printf '%sNo GUI login session: smoke launch skipped\n' "$notice"
  exit 0
fi
domain=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist") ||
  fail 'Contents/Info.plist has no CFBundleIdentifier'
# The key of MainPanelController's frame autosave name.
frame_key='NSWindow Frame BytePortsPanel'
had_frame=false
if saved_frame=$(/usr/bin/defaults read "$domain" "$frame_key" 2>/dev/null); then had_frame=true; fi
# Runs after stop(), so the app cannot save the frame again.
restore_frame() {
  if [[ "$had_frame" == true ]]; then
    /usr/bin/defaults write "$domain" "$frame_key" -string "$saved_frame" ||
      printf 'Could not restore %s in the %s defaults\n' "$frame_key" "$domain" >&2
  else
    /usr/bin/defaults delete "$domain" "$frame_key" 2>/dev/null || true
  fi
}
state=$(mktemp -d "${TMPDIR:-/tmp}/ports-smoke.XXXXXX")
pid=''
# SIGTERM, then SIGKILL after 5 s. The shell's job notice for the expected termination goes nowhere.
stop() {
  [[ -n "$pid" ]] || return 0
  {
    kill "$pid" || true
    for _ in {1..50}; do
      kill -0 "$pid" || break
      sleep 0.1
    done
    kill -KILL "$pid" || true
    wait "$pid" || true
  } 2>/dev/null
  pid=''
}
trap 'stop; restore_frame; rm -rf "$state"' EXIT
"$executable" --state-directory "$state" --demo >"$state/output.log" 2>&1 &
pid=$!
sleep 5
if ! kill -0 "$pid" 2>/dev/null; then
  status=0
  wait "$pid" || status=$?
  pid=''
  cat "$state/output.log" >&2
  fail "the app exited during launch with status $status"
fi
predicate="processID == $pid AND messageType == fault"
events=$(/usr/bin/log show --last 1m --style ndjson --predicate "$predicate") || fail 'the unified log is not readable'
if /usr/bin/grep -q '"eventType"' <<<"$events"; then
  /usr/bin/log show --last 1m --style compact --predicate "$predicate" >&2 || true
  fail 'the app logged faults during launch'
fi
stop
printf 'Smoke-launched app: %s\n' "$app"

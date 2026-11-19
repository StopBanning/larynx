#!/bin/zsh
# Larynx installer: builds the menu bar app from source on this Mac and opens it. Free, no account, no download of
# anything but the source and the speech model (about 500 MB, on first launch).
#
#   curl -fsSL https://raw.githubusercontent.com/StopBanning/larynx/main/scripts/install.sh | zsh
#
# LARYNX_DIR picks where the source goes (default ~/.larynx-src). Run it again to update. LARYNX_SIGN=adhoc and
# LARYNX_NO_WARM=1 pass through to make-app.sh; LARYNX_NO_OPEN=1 builds without opening (tests/install.py, CI).
set -euo pipefail
say() { print -P "%F{cyan}larynx:%f $*"; }
fail() { print -P "%F{red}larynx:%f $*" >&2; exit 1; }

[[ "$(uname -m)" == arm64 ]] || fail "Larynx needs an Apple Silicon Mac (M1 or later): the speech model runs on its Neural Engine."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 15 )) || fail "Larynx needs macOS 15 or later (this Mac has $(sw_vers -productVersion))."
if ! xcrun --find swift >/dev/null 2>&1; then
  say "Larynx is built on your Mac, which needs Apple's free command-line developer tools. A window is opening to"
  say "install them: click Install and agree. It can take 10 to 20 minutes."
  xcode-select --install 2>/dev/null || true
  fail "When that window says the software was installed, paste the same line into Terminal again."
fi

# Use this checkout when run from inside one; otherwise fetch the source (or update it).
here="${0:a:h}/.."
if [[ -f "$here/Package.swift" ]] && grep -q larynx "$here/Package.swift" 2>/dev/null; then
  src="${here:a}"
else
  src="${LARYNX_DIR:-$HOME/.larynx-src}"
  if [[ -d "$src/.git" ]]; then
    say "Updating the source in $src"
    git -C "$src" pull --ff-only --quiet
  else
    say "Fetching the source into $src"
    git clone --depth 1 --quiet https://github.com/StopBanning/larynx "$src"
  fi
fi

say "Building Larynx. The first time takes about 5 to 10 minutes, and Terminal stays quiet while it works."
say "Leave this window open."
log="${TMPDIR:-/tmp}/larynx-build.log"
if ! "$src/scripts/make-app.sh" >"$log" 2>&1; then
  tail -n 25 "$log" >&2
  fail "The build failed. The full log is $log. Please open an issue with it attached:
  https://github.com/StopBanning/larynx/issues/new"
fi
grep -E "speech model|Larynx.app$" "$log" || true
if [[ -n "${LARYNX_NO_OPEN:-}" ]]; then
  # Tests and CI: build only. Never restart or open anything (a second Larynx would fight the first for the talk key).
  say "Built $HOME/Applications/Larynx.app (LARYNX_NO_OPEN: not opened)"
  exit 0
elif pgrep -x larynx >/dev/null; then
  say "Restarting Larynx on the new build (waits until you're not dictating)"
  "$src/scripts/restart-app.sh"
  if grep -q "signed with: -" "$log"; then
    say "If Larynx stops hearing its key or typing after this update, macOS forgot its permissions: in System Settings,"
    say "Privacy & Security, remove Larynx with − from Input Monitoring and Accessibility, then follow the setup window."
  fi
else
  open "$HOME/Applications/Larynx.app"
fi
say "Done. Larynx is in your menu bar; the setup window walks you through three permissions."
say "Hold Fn, Right Option or Right Command, speak, let go."

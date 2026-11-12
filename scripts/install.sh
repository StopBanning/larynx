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
  say "Apple's command-line developer tools are needed to build Larynx. Opening the installer..."
  xcode-select --install 2>/dev/null || true
  fail "Run this script again once the developer tools have finished installing."
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

say "Building (a few minutes the first time)..."
"$src/scripts/make-app.sh" | grep -E "speech model|Larynx.app$" || true
if [[ -n "${LARYNX_NO_OPEN:-}" ]]; then
  # Tests and CI: build only. Never restart or open anything (a second Larynx would fight the first for the talk key).
  say "Built $HOME/Applications/Larynx.app (LARYNX_NO_OPEN: not opened)"
  exit 0
elif pgrep -x larynx >/dev/null; then
  say "Restarting Larynx on the new build (waits until you're not dictating)"
  "$src/scripts/restart-app.sh"
else
  open "$HOME/Applications/Larynx.app"
fi
say "Done. Larynx is in your menu bar; the setup window walks you through three permissions."
say "Hold Fn, Right Option or Right Command, speak, let go."

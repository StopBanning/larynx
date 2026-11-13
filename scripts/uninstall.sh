#!/bin/zsh
# Removes Larynx and everything it stored on this Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/StopBanning/larynx/main/scripts/uninstall.sh | zsh
#   ./scripts/uninstall.sh --keep-data     keep your history, words and downloaded models; remove only the app
#   ./scripts/uninstall.sh --dry-run       show what would be removed and change nothing
#
# It asks before removing anything. What it removes: the app, your dictation history and recordings, your
# dictionary, vocabulary and snippets, the speech models, the log, the settings, the source used to build it, and
# Larynx's entries under Privacy & Security.
# --files-only (tests): remove the files under $HOME and nothing else: no app is quit, no settings or permissions touched.
set -euo pipefail
keep_data=0 dry=0 files_only=0 yes=0
for a in "$@"; do
  case "$a" in
    --keep-data) keep_data=1 ;; --dry-run) dry=1 ;; --files-only) files_only=1 ;; --yes) yes=1 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

app="$HOME/Applications/Larynx.app"
targets=("$app" "$HOME/.larynx-src")
if (( ! keep_data )); then
  targets+=("$HOME/Library/Application Support/Larynx" "$HOME/Library/Logs/Larynx.log")
fi

echo "This removes:"
found=0
for t in "${targets[@]}"; do
  if [[ -e "$t" ]]; then
    found=1
    echo "  $t ($(du -sh "$t" 2>/dev/null | cut -f1 | tr -d ' '))"
  fi
done
(( found )) || echo "  (no Larynx files found)"
if (( ! files_only )); then
  (( keep_data )) || echo "  Larynx's settings"
  echo "  Larynx's entries in System Settings > Privacy & Security (Microphone, Accessibility, Input Monitoring)"
fi
(( keep_data )) && echo "Kept: your history, words, models and settings in ~/Library/Application Support/Larynx"

if (( dry )); then echo "Dry run: nothing was changed."; exit 0; fi
if (( ! yes )); then
  printf "Type yes to continue: "
  read -r answer < /dev/tty || answer=""
  [[ "$answer" == "yes" ]] || { echo "Nothing was removed."; exit 1; }
fi

if (( ! files_only )); then
  # Quit the app first so it does not write its files back.
  osascript -e 'tell application id "com.automatedworkflow.larynx" to quit' >/dev/null 2>&1 || true
  pkill -f "$app/Contents/MacOS/larynx" >/dev/null 2>&1 || true
fi
for t in "${targets[@]}"; do
  [[ -e "$t" ]] && rm -rf -- "$t"
done
if (( ! files_only )); then
  (( keep_data )) || defaults delete com.automatedworkflow.larynx >/dev/null 2>&1 || true
  tccutil reset All com.automatedworkflow.larynx >/dev/null 2>&1 || true
fi
echo "Larynx is removed."
(( files_only )) || echo "If you turned on Open at Login, remove Larynx under System Settings > General > Login Items."

#!/usr/bin/env bash
# Installs the Flatpak bundle the way a user does and runs DeltaView in its
# sandbox. CI runs this in the flatpak-builder container right after the
# build (the GNOME runtime is already installed there from Flathub).
#
# usage: smoke.sh <bundle.flatpak>
#
#   1. `flatpak install --user` the bundle;
#   2. ldd every ELF file under /app inside the sandbox: no "not found";
#   3. under Xvfb, `delta-view --version`, printed from Dart;
#   4. the app opened on a folder in $HOME and one in /tmp, as git difftool
#      --dir-diff opens it. It must find both through --filesystem=home and
#      --filesystem=/tmp and record the comparison in its settings file
#      (inside ~/.var/app, written from Dart), and Flutter must draw the
#      window: counted in Xvfb's framebuffer, where an empty screen has one
#      colour. The container has no xdotool, so the screen is read directly.
set -euo pipefail
APP_ID=com.dhivalabs.delta_view
[ $# -eq 1 ] || { echo "usage: $0 <bundle.flatpak>" >&2; exit 2; }
bundle="$(readlink -f "$1")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"
mkdir -p -m 0700 "$XDG_RUNTIME_DIR"

echo "::group::flatpak install --user $(basename "$bundle")"
flatpak install --user -y --noninteractive "$bundle"
flatpak info --user "$APP_ID"
flatpak info --user --show-permissions "$APP_ID"
echo "::endgroup::"

echo "::group::ldd inside the sandbox"
flatpak run --command=bash "$APP_ID" -c '
  set -euo pipefail
  mapfile -d "" elfs < <(find /app -type f -print0)
  libdirs="$(find /app -name "*.so*" -type f -printf "%h\n" | sort -u | paste -sd:)"
  n=0; bad=0
  for f in "${elfs[@]}"; do
    [ "$(head -c 4 "$f" | od -An -tx1 | tr -d " \n")" = 7f454c46 ] || continue
    n=$((n + 1))
    if LD_LIBRARY_PATH="$libdirs" ldd "$f" 2>&1 | grep "not found" > /dev/null; then
      echo "missing libraries for $f:"
      LD_LIBRARY_PATH="$libdirs" ldd "$f" | grep "not found"
      bad=1
    fi
  done
  echo "$n ELF files checked with ldd in the sandbox"
  [ "$n" -gt 0 ] && [ "$bad" = 0 ]'
echo "::endgroup::"

fb="$(mktemp -d)"
cat > "$fb/run.sh" <<'EOS'
set -euo pipefail
app_id="$1"; fb="$2"; here="$3"
out="$(flatpak run "$app_id" --version 2>&1)"
printf '%s\n' "$out"
grep -qE '^DeltaView [0-9]' <<< "$out" || { echo "no version line from the sandboxed app"; exit 1; }

left="$HOME/left"
right="$(mktemp -d /tmp/right.XXXXXX)"
mkdir -p "$left"
echo one > "$left/a.txt"
echo two > "$right/a.txt"
settings="$HOME/.var/app/$app_id/data/$app_id/settings.json"
log="$fb/app.log"
flatpak run "$app_id" "$left" "$right" > "$log" 2>&1 &
pid=$!
ok=0
for i in $(seq 1 120); do
  kill -0 "$pid" 2> /dev/null || { echo "the app exited early"; break; }
  colours="$(python3 "$here/xwd-colours.py" "$fb/Xvfb_screen0")"
  if grep -qsF "\"$left\"" "$settings" && grep -qsF "\"$right\"" "$settings" \
     && [ "$colours" -ge 16 ]; then
    echo "after ${i}s: $settings records $left and $right, and the screen shows $colours colours"
    ok=1
    break
  fi
  sleep 1
done
if [ "$ok" = 1 ]; then
  sleep 5
  kill -0 "$pid" 2> /dev/null || { echo "the app died after it came up"; ok=0; }
else
  echo "not up after 120s: screen colours ${colours:-?}, settings file:"
  cat "$settings" 2> /dev/null || echo "(none)"
fi
kill "$pid" 2> /dev/null || :
cat "$log"
if grep -E 'error while loading shared libraries|cannot open shared object|undefined symbol' "$log"; then ok=0; fi
[ "$ok" = 1 ]
EOS
echo "::group::run under Xvfb"
xvfb-run -a -s "-screen 0 1280x800x24 -br -fbdir $fb" \
  dbus-run-session -- bash "$fb/run.sh" "$APP_ID" "$fb" "$here"
echo "::endgroup::"
rm -rf "$fb"
echo "Flatpak bundle $(basename "$bundle"): OK"

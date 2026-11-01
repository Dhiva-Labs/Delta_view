#!/usr/bin/env bash
# Runs inside a distribution container started by verify.sh.
# MODE: rpm (Fedora) | rpm-suse (openSUSE) | pacman (Arch) | appimage (Fedora)
# FILE: the package to install, under /pkgs.
set -euo pipefail
# shellcheck source=/dev/null
. /linux-distros/distro.conf

# Display and GL stack for the GUI smoke test, per distribution. xdotool
# finds the app's window. libEGL and libGLESv2 are what Flutter's renderer
# opens at run time (through libepoxy, so they are no ELF dependencies; the
# rpm requires them by capability, and the AppImage needs them from the
# host). xvfb-run needs awk, which openSUSE's image lacks. Capabilities and
# file paths instead of package names where the names differ between Fedora
# and openSUSE.
case "$MODE" in
  rpm|appimage)
    dnf -y -q install file findutils which procps-ng \
      xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers dbus-daemon \
      'libEGL.so.1()(64bit)' 'libGLESv2.so.2()(64bit)' /usr/bin/xdotool
    ;;
  rpm-suse)
    zypper -n -q --gpg-auto-import-keys refresh
    zypper -n -q install file findutils which procps gawk \
      /usr/bin/xvfb-run /usr/bin/xauth /usr/bin/dbus-run-session Mesa-dri \
      'libEGL.so.1()(64bit)' 'libGLESv2.so.2()(64bit)' /usr/bin/xdotool
    ;;
  pacman)
    pacman -Syu --noconfirm --needed -q file findutils which procps-ng \
      xorg-server-xvfb xorg-xauth mesa dbus xdotool
    ;;
esac

case "$MODE" in
  rpm)      dnf -y install "$FILE"; files() { rpm -ql "$NAME"; } ;;
  rpm-suse) zypper -n install --allow-unsigned-rpm "$FILE"; files() { rpm -ql "$NAME"; } ;;
  pacman)   pacman -U --noconfirm "$FILE"; files() { pacman -Qlq "$NAME"; } ;;
  appimage)
    # The libraries an AppImage expects from the host: GTK 3 and friends.
    dnf -y -q install gtk3
    cp "$FILE" /tmp/app.AppImage
    chmod +x /tmp/app.AppImage
    (cd /tmp && /tmp/app.AppImage --appimage-extract > /dev/null)
    files() { find /tmp/squashfs-root -type f; }
    ;;
  *) echo "unknown MODE $MODE" >&2; exit 2 ;;
esac

# Every ELF file the package installed must find all of its libraries. The
# package's own library directories go on LD_LIBRARY_PATH, as the app's
# RPATH/$ORIGIN would supply them at run time, so only libraries missing
# from the distribution are reported. (grep > /dev/null, not grep -q: under
# pipefail an early grep exit can kill ldd with SIGPIPE and hide a miss.)
mapfile -t elfs < <(files | while IFS= read -r f; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] && echo "$f"
done)
libdirs="$(for f in "${elfs[@]}"; do case "$f" in *.so|*.so.*) dirname "$f" ;; esac; done | sort -u | paste -sd:)"
missing=0
for f in "${elfs[@]}"; do
  if LD_LIBRARY_PATH="$libdirs" ldd "$f" 2>&1 | grep 'not found' > /dev/null; then
    echo "missing libraries for $f:"
    LD_LIBRARY_PATH="$libdirs" ldd "$f" | grep 'not found'
    missing=1
  fi
done
echo "${#elfs[@]} ELF files checked with ldd"
[ "$missing" = 0 ] || exit 1

# Smoke test, under Xvfb and a session bus with a clean home directory.
#   SMOKE_CMD: must exit 0, and print a line matching SMOKE_EXPECT if set.
#   GUI_CMD + GUI_ARGS: started after SMOKE_SETUP; must make SMOKE_READY
#     succeed within SMOKE_SECONDS (or, without SMOKE_READY, still be
#     running then), stay up 5 s longer, and log no loader errors.
# For the AppImage, the AppImage itself replaces the installed command.
if [ "$MODE" = appimage ]; then
  export APPIMAGE_EXTRACT_AND_RUN=1
  cmd_prefix=/tmp/app.AppImage
else
  cmd_prefix=
fi
export HOME=/tmp/smoke-home
mkdir -p "$HOME"
cat > /tmp/smoke.sh <<'EOS'
set -euo pipefail
. /linux-distros/distro.conf
cmd_prefix="$1"
if [ -n "${SMOKE_SETUP:-}" ]; then eval "$SMOKE_SETUP"; fi

if [ -n "${SMOKE_CMD:-}" ]; then
  read -r -a words <<< "$SMOKE_CMD"
  if [ -n "$cmd_prefix" ]; then words[0]="$cmd_prefix"; fi
  echo "+ ${words[*]}"
  out="$("${words[@]}" 2>&1)"
  printf '%s\n' "$out"
  if [ -n "${SMOKE_EXPECT:-}" ]; then
    grep -qE -- "$SMOKE_EXPECT" <<< "$out" || { echo "no line matches $SMOKE_EXPECT"; exit 1; }
  fi
fi

[ -n "${GUI_CMD:-}" ] || exit 0
if [ -n "$cmd_prefix" ]; then gui=("$cmd_prefix"); else read -r -a gui <<< "$GUI_CMD"; fi
eval "args=(${GUI_ARGS:-})"
echo "+ ${gui[*]} ${args[*]}"
log=/tmp/smoke.log
"${gui[@]}" "${args[@]}" > "$log" 2>&1 &
pid=$!
secs="${SMOKE_SECONDS:-20}"
ok=0
for i in $(seq 1 "$secs"); do
  if ! kill -0 "$pid" 2> /dev/null; then
    wait "$pid" && rc=0 || rc=$?
    echo "exited early with status $rc"
    break
  fi
  if [ -n "${SMOKE_READY:-}" ] && eval "$SMOKE_READY"; then
    echo "ready after ${i}s: $SMOKE_READY"
    ok=1
    break
  fi
  sleep 1
done
if [ -z "${SMOKE_READY:-}" ] && kill -0 "$pid" 2> /dev/null; then
  echo "still running after ${secs}s"
  ok=1
fi
if [ "$ok" = 1 ]; then
  sleep 5
  kill -0 "$pid" 2> /dev/null || { echo "died after it came up"; ok=0; }
elif kill -0 "$pid" 2> /dev/null; then
  echo "not ready after ${secs}s"
fi
kill "$pid" 2> /dev/null || :
cat "$log"
if grep -E 'error while loading shared libraries|cannot open shared object|undefined symbol' "$log"; then ok=0; fi
[ "$ok" = 1 ]
EOS
xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- bash /tmp/smoke.sh "$cmd_prefix"
echo "$MODE: OK"

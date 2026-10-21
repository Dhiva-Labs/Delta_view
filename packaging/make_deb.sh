#!/usr/bin/env bash
# Build a .deb for DeltaView from the Flutter Linux release bundle.
# Usage: packaging/make_deb.sh [--build]
#   --build   run `flutter build linux --release` first
#
# The package architecture comes from the machine this runs on (amd64 or
# arm64), because Flutter builds for the host. The output is
# dist/delta-view_<version>_<arch>.deb. The package version is the one in
# pubspec.yaml (without the build number); override it with DEB_VERSION.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${DEB_VERSION:-$(grep '^version:' "$ROOT/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)}"
PKGNAME="delta-view"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) FLUTTER_ARCH=x64 ;;
  arm64) FLUTTER_ARCH=arm64 ;;
  *)
    echo "error: unsupported architecture '$ARCH' (amd64 or arm64)" >&2
    exit 1
    ;;
esac

BUNDLE="$ROOT/build/linux/$FLUTTER_ARCH/release/bundle"
OUT="${OUT_DIR:-$ROOT/dist}"
STAGE="$(mktemp -d)"
PKG="$STAGE/${PKGNAME}_${VERSION}_${ARCH}"
trap 'rm -rf "$STAGE"' EXIT

if [[ "${1:-}" == "--build" ]]; then
  (cd "$ROOT" && flutter build linux --release)
fi
[[ -x "$BUNDLE/delta_view" ]] || {
  echo "Release bundle not found. Run with --build or 'flutter build linux --release' first." >&2
  exit 1
}

# ---- staging tree ----
mkdir -p "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/opt/delta_view" \
         "$PKG/usr/share/applications"

cp -r "$BUNDLE"/. "$PKG/opt/delta_view/"
ln -s /opt/delta_view/delta_view "$PKG/usr/bin/$PKGNAME"

# Icons: every hicolor size from the brand assets, plus the SVG so themes
# that prefer scalable icons get a crisp one.
for size in 16 24 32 48 64 128 256 512; do
  mkdir -p "$PKG/usr/share/icons/hicolor/${size}x${size}/apps"
  cp "$ROOT/assets/brand/delta_view_${size}.png" \
     "$PKG/usr/share/icons/hicolor/${size}x${size}/apps/$PKGNAME.png"
done
mkdir -p "$PKG/usr/share/icons/hicolor/scalable/apps"
cp "$ROOT/assets/brand/delta_view.svg" \
   "$PKG/usr/share/icons/hicolor/scalable/apps/$PKGNAME.svg"

# Extras: the "Compare with DeltaView" file manager script and its notes.
# Not enabled by default; docs/command-line.md explains how to install it.
mkdir -p "$PKG/usr/share/doc/$PKGNAME"
cp "$ROOT/LICENSE" "$PKG/usr/share/doc/$PKGNAME/copyright"

mkdir -p "$PKG/opt/delta_view/extras"
cp "$ROOT/packaging/extras/"* "$PKG/opt/delta_view/extras/"

# The entry is named after the GTK application id: GNOME Shell matches a
# running Wayland window to its launcher by <app-id>.desktop, and any other
# name leaves the window with a generic icon in the dock. The same file is
# used by the PPA (debian/rules) and the snap.
install -m 0644 "$ROOT/linux/com.dhivalabs.delta_view.desktop" \
   "$PKG/usr/share/applications/com.dhivalabs.delta_view.desktop"

cat > "$PKG/DEBIAN/control" <<CONTROL
Package: $PKGNAME
Version: $VERSION
Section: devel
Priority: optional
Architecture: $ARCH
Depends: libgtk-3-0, libglib2.0-0
Maintainer: dhivadhiva <dhivakar1010@gmail.com>
Description: Compare and merge folders and files, Meld-style
 DeltaView compares folders and files side by side and merges the
 differences: copy changes across, resolve three-way merges, and
 synchronize folders with a preview of every step.
 .
 It compares local folders, zip and tar archives and SFTP servers, shows
 images and JSON, YAML and CSV by their structure, and works as git
 difftool and mergetool.
CONTROL

# Refresh the icon and desktop caches so the entry and icon show up
# without a logout. Each step is optional: a missing tool is not an error.
for script in postinst postrm; do
  cat > "$PKG/DEBIAN/$script" <<'MAINT'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications 2>/dev/null || true
fi
exit 0
MAINT
  chmod 0755 "$PKG/DEBIAN/$script"
done

find "$PKG/opt" "$PKG/usr" -type d -exec chmod 0755 {} \;
find "$PKG/usr/share/icons" -type f -exec chmod 0644 {} \;
# Nothing in the package should be writable by group or others.
chmod 0755 "$PKG"
find "$PKG/opt" "$PKG/usr" -type f -exec chmod go-w {} +
chmod 0755 "$PKG/opt/delta_view/delta_view"
chmod 0755 "$PKG/opt/delta_view/extras/compare-with-deltaview"

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$PKG" "$OUT/${PKGNAME}_${VERSION}_${ARCH}.deb"
echo "Built: $OUT/${PKGNAME}_${VERSION}_${ARCH}.deb"

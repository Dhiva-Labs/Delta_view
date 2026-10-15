#!/usr/bin/env bash
# Build a .deb for DeltaView from the Flutter Linux release bundle.
# Usage: packaging/make_deb.sh [--build]
#   --build   run `flutter build linux --release` first
#
# The package architecture comes from the machine this runs on (amd64 or
# arm64), because Flutter builds for the host. The output is
# dist/delta-view_<version>_<arch>.deb. The package version is 1.0.0, the one
# the published amd64 package carries; override it with DEB_VERSION.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${DEB_VERSION:-1.0.0}"
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
         "$PKG/usr/share/applications" \
         "$PKG/usr/share/icons/hicolor/512x512/apps"

cp -r "$BUNDLE"/. "$PKG/opt/delta_view/"
cp "$ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png" \
   "$PKG/usr/share/icons/hicolor/512x512/apps/$PKGNAME.png"
ln -s /opt/delta_view/delta_view "$PKG/usr/bin/$PKGNAME"

cat > "$PKG/usr/share/applications/$PKGNAME.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=DeltaView
Comment=Compare folders and files, beautifully
Exec=/opt/delta_view/delta_view
Icon=$PKGNAME
Terminal=false
Categories=Development;Utility;FileTools;
StartupWMClass=delta_view
DESKTOP

cat > "$PKG/DEBIAN/control" <<CONTROL
Package: $PKGNAME
Version: $VERSION
Section: devel
Priority: optional
Architecture: $ARCH
Depends: libgtk-3-0, libglib2.0-0
Maintainer: dhivadhiva <dhivakar1010@gmail.com>
Description: Meld-style folder and file comparison tool
 DeltaView compares folders and files side by side with a Myers-diff
 engine, tabbed multi-comparison workflow, dual-pane tree view, and an
 in-place editor with live re-highlighting and save.
CONTROL

find "$PKG/opt" "$PKG/usr" -type d -exec chmod 0755 {} \;
chmod 0755 "$PKG/opt/delta_view/delta_view"

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$PKG" "$OUT/${PKGNAME}_${VERSION}_${ARCH}.deb"
echo "Built: $OUT/${PKGNAME}_${VERSION}_${ARCH}.deb"

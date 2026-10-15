# DeltaView

[![ARM64 builds](https://github.com/Dhiva-Labs/Delta_view/actions/workflows/desktop.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/Delta_view/actions/workflows/desktop.yml)
![Linux x64 | arm64](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-informational?logo=linux&logoColor=white)
![Windows x64 | arm64](https://img.shields.io/badge/Windows-x64%20%7C%20arm64-informational?logo=windows&logoColor=white)

A fast, modern folder and file comparison tool — Meld-style, built with
Flutter for **Windows, Ubuntu, and macOS**.

## Features

- **Folder compare** — recursive tree comparison with byte-accurate content
  checks, run on a background isolate so huge trees never freeze the UI.
  Live progress while scanning, per-directory change badges, filters
  (changes / left only / right only), and name search.
- **File compare** — side-by-side diff (Myers algorithm) with line numbers,
  intra-line change highlighting, previous/next-change navigation, and a
  clickable minimap of changes.
- **Smooth UI** — Material 3, dark and light themes, animated transitions,
  virtualised lists that stay fluid on large diffs.
- Binary files and files over 8 MB are detected and reported instead of
  producing a garbage diff.

## Install

Every release carries the Linux and Windows builds for x64 and arm64:

| Platform | Architecture | Asset |
|---|---|---|
| Linux (Debian, Ubuntu) | x64 | `delta-view_1.0.0_amd64.deb` |
| Linux (Debian, Ubuntu) | arm64 | `delta-view_1.0.0_arm64.deb` |
| Windows | x64 | `DeltaView-<version>-windows-x64-setup.exe` |
| Windows | arm64 | `DeltaView-<version>-windows-arm64-setup.exe` |

```sh
sudo apt install ./delta-view_1.0.0_arm64.deb   # or _amd64.deb
```

The [Desktop builds](.github/workflows/desktop.yml) workflow builds, tests,
installs and starts the packages on Linux and Windows, x64 and arm64, on every
push.

## Run

```sh
flutter run -d linux    # or -d windows / -d macos
```

## Build a release

```sh
flutter build linux     # or windows / macos
```

The Linux bundle lands in `build/linux/<x64|arm64>/release/bundle/` (Flutter
builds for the machine it runs on). To package a build:

```sh
packaging/make_deb.sh                                 # Linux .deb for this machine's architecture
pwsh packaging/windows/build_installer.ps1            # Windows installer (needs Inno Setup 6)
```

## Test

```sh
flutter test
```

Covers the Myers diff engine (round-trip correctness, intra-line spans,
change-block tracking) and the folder scanner (identical / modified /
one-sided classification).

## Layout

- `lib/diff/line_diff.dart` — Myers line diff + side-by-side row builder
- `lib/compare/folder_compare.dart` — recursive folder scan in an isolate
- `lib/ui/` — home, folder tree, and file diff screens
- `lib/theme.dart` — app theme and diff colour palette

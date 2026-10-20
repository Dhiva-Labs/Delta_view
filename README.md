# DeltaView

[![ARM64 builds](https://github.com/Dhiva-Labs/Delta_view/actions/workflows/desktop.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/Delta_view/actions/workflows/desktop.yml)
![Linux x64 | arm64](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-informational?logo=linux&logoColor=white)
![Windows x64 | arm64](https://img.shields.io/badge/Windows-x64%20%7C%20arm64-informational?logo=windows&logoColor=white)

A fast, modern folder and file comparison tool — Meld-style, built with
Flutter for **Windows, Ubuntu, and macOS**.

## Features

- **Folder compare**: a recursive dual-pane tree, scanned in the background
  and cancellable, with filters, sorting, keyboard navigation, ignore
  patterns and `.gitignore` support, quick compare by size and date, folder
  sync with a preview of every step, and HTML/CSV reports.
- **File compare**: a Meld-style side-by-side diff with intra-line
  highlights, syntax highlighting, word wrap or horizontal scrolling,
  hidden unchanged runs, find, a minimap, and compare rules (whitespace,
  case, line endings, blank lines). Copy changes across or edit in place,
  with undo. Encoding and line endings are kept on save.
- **Three-way merge**: Left | Merged | Right, with clean changes merged up
  front and every conflict one key away. Works as `git mergetool`.
- **Images**: side by side, swipe, onion skin and pixel difference.
- **JSON, YAML, CSV**: compared by structure, so reordering is not a change.
- **Anywhere**: local folders, zip and tar archives, and SFTP servers (host
  keys confirmed by you), plus pasted text.
- **Yours to tune**: themes, accent colour, colour-blind-safe diff colours,
  editor font and size, density, and rebindable shortcuts (Ctrl+/ lists
  them). Recent comparisons, open tabs and the window are remembered.

## Install

Every release carries the Linux and Windows builds for x64 and arm64:

| Platform | Architecture | Asset |
|---|---|---|
| Linux (Debian, Ubuntu) | x64 | `delta-view_<version>_amd64.deb` |
| Linux (Debian, Ubuntu) | arm64 | `delta-view_<version>_arm64.deb` |
| Windows | x64 | `DeltaView-<version>-windows-x64-setup.exe` |
| Windows | arm64 | `DeltaView-<version>-windows-arm64-setup.exe` |

```sh
sudo apt install ./delta-view_<version>_arm64.deb   # or _amd64.deb
```

The [Desktop builds](.github/workflows/desktop.yml) workflow builds, tests,
installs and starts the packages on Linux and Windows, x64 and arm64, on every
push.

## Run

```sh
flutter run -d linux    # or -d windows / -d macos
```

From a terminal or as a git tool:

```sh
delta-view LEFT RIGHT                                  # two folders or two files
delta-view --merge LOCAL BASE REMOTE --output MERGED   # three-way merge
```

[docs/command-line.md](docs/command-line.md) shows the `git difftool` and
`git mergetool` setup and the file manager script.

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

Covers the diff and merge engines, text encodings, folding and patches, the
folder scanner, ignore rules, sync planning and reports, archive and SFTP
sources, structured and image diffs, command-line parsing, settings and
sessions, plus widget tests of the main views.

## Layout

- `lib/compare/` — comparisons, sources (local, archive, SFTP), folder scan,
  ignore rules, sync and reports
- `lib/diff/` — Myers diff, compare rules, text codec, folding, patches
- `lib/merge/` — three-way merge engine
- `lib/remote/` — known hosts, saved connections, credential cache
- `lib/settings/` — persisted preferences and session state
- `lib/ui/` — shell and tabs, home, settings, and the folder, file, merge,
  image and structured views
- `lib/cli/` — command-line parsing
- `assets/brand/` — the app icon sources

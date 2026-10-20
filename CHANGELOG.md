# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - Unreleased

DeltaView grows from a viewer into a compare-and-merge tool: copy changes
across, merge three versions, synchronize folders, and compare archives,
SFTP servers, images and structured data. It has its own icon now.

### Added
- **Merging.** Copy a change left or right, or delete it, from the bands
  between the panes; undo and redo cover every step. Three-way merge shows
  Left | Merged | Right, merges clean changes up front, and resolves each
  conflict by taking a side, both, the base, or editing by hand.
- **More to compare.** Folders and files inside zip and tar archives
  (read-only), and on SFTP servers. A server's host key is shown for you to
  confirm the first time, and a changed key is refused. Saved connections
  never store passwords.
- **Images**: side by side, swipe, onion skin, and a pixel difference with
  the share of pixels changed. **JSON, YAML and CSV** are compared by
  structure, so reordered keys or rows are not changes.
- **Pasted text**: compare two snippets, or the clipboard (Ctrl+Shift+V).
- **Folder sync**: copy or delete across sides, or mirror a whole tree, with
  a preview of every step and a confirmation before anything is overwritten
  or deleted. Reports export as HTML or CSV.
- **Ignore rules**: patterns from Settings and `.gitignore` files are left
  out of folder scans; quick compare by size and date for huge trees.
- **Settings**: theme, accent colour, diff colours (including a
  colour-blind-safe set), density, editor font and size, word wrap, tab
  width, whitespace markers, syntax highlighting, compare rules, ignore
  patterns, and rebindable keyboard shortcuts.
- **Reading diffs**: horizontal scrolling or word wrap for long lines,
  hidden unchanged runs, syntax highlighting, find, go to line, a draggable
  minimap, a status bar, and +/−/~ markers so changes do not rely on colour.
- **Home screen**: type, paste or drop paths; recent comparisons with
  pinning; Folders, Files, Text and Merge modes.
- **Command line**: `delta-view LEFT RIGHT` and
  `delta-view --merge LOCAL BASE REMOTE --output MERGED`, for use as
  `git difftool` and `git mergetool` (see docs/command-line.md). The .deb
  adds a "Compare with DeltaView" file manager script.
- Window size and open tabs are restored on the next start. Ctrl+/ lists
  every shortcut; Ctrl+1…9 switch tabs.
- The Split Delta app icon, and an About dialog.

### Changed
- Files keep their encoding (UTF-8, UTF-8 with BOM, UTF-16, Latin-1) and line
  endings when saved; before, every save wrote UTF-8.
- Folder scans are several times faster, can be cancelled, and stop when
  their tab closes.
- The window is titled DeltaView instead of delta_view.

### Fixed
- Long lines were cut off at the edge of the diff.
- Closing a tab or quitting threw away unsaved edits without asking.
- In edit mode the two sides drifted apart while scrolling.
- Opening the same file twice from a folder comparison opened two tabs.
- The theme was not remembered between runs.

## [1.0.1] - 2026-10-16

The version is now the same everywhere. The `0.0.1` release tag carried a
`delta-view_1.0.0_amd64.deb` and a `DeltaView-0.1.0-windows-x64-setup.exe`, while
`pubspec.yaml` said `0.1.0`. This release is tagged `1.0.1`, `pubspec.yaml` says
`1.0.1`, and every package is named `1.0.1`.

### Added
- Linux arm64 and Windows arm64 builds, next to the x64 ones. Releases carry
  `delta-view_<version>_amd64.deb`, `delta-view_<version>_arm64.deb`,
  `DeltaView-<version>-windows-x64-setup.exe` and
  `DeltaView-<version>-windows-arm64-setup.exe`. Every package is built,
  installed and started on a runner of its own architecture.
- The `.deb` and the Windows installer are built by CI (`packaging/make_deb.sh`,
  `packaging/windows/build_installer.ps1`).
- Releases are completed by CI: publishing a release attaches the packages,
  leaving alone any file name already on the release.

### Changed
- `packaging/make_deb.sh` takes the package version from `pubspec.yaml` instead
  of a fixed `1.0.0`. `DEB_VERSION` still overrides it.

## [0.0.1] - 2026-07-14

- Initial test release: Meld-style folder and file comparison with a Myers diff
  engine, recursive folder comparison on a background isolate, and a dual-pane
  tree view. Shipped as `delta-view_1.0.0_amd64.deb` and
  `DeltaView-0.1.0-windows-x64-setup.exe`.

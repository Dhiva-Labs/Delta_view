# DeltaView

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

## Run

```sh
flutter run -d linux    # or -d windows / -d macos
```

## Build a release

```sh
flutter build linux     # or windows / macos
```

The Linux bundle lands in `build/linux/x64/release/bundle/`.

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

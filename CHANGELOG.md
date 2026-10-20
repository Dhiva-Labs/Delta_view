# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

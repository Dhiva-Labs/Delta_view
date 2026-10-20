/// Facts about the app shared by the About dialog, the command line and
/// the window title. One place to change when a release is cut.
library;

const appName = 'DeltaView';

/// Must match `version:` in pubspec.yaml (without the build number); a
/// test under test/cli checks that it does.
const appVersion = '1.1.0';

const appTagline = 'Compare folders and files, beautifully.';

const appDescription =
    'A fast, Meld-style comparison tool: folder trees, side-by-side file '
    'diffs, pasted text and three-way merges, on Linux, Windows and macOS.';

const appRepositoryUrl = 'https://github.com/Dhiva-Labs/Delta_view';

const appCopyright = '© 2026 Dhiva Labs';

/// Shown in the About dialog. The repository carries the licence text.
const appLicense = 'Open source. See LICENSE in the repository.';

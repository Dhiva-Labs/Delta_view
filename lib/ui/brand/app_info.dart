/// Facts about the app shared by the About dialog, the command line and
/// the window title. One place to change when a release is cut.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

/// Shown in the About dialog. The full text is the LICENSE file, which
/// the licence page lists (see [registerAppLicense]).
const appLicense = 'MIT License';

/// Lists DeltaView's own MIT licence on the licence page, above the
/// licences of the packages it uses.
void registerAppLicense() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
        const [appName], await rootBundle.loadString('LICENSE'));
  });
}

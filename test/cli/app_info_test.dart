import 'dart:io';

import 'package:delta_view/ui/brand/app_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appVersion matches pubspec.yaml', () {
    // `--version`, the About dialog and the packages must agree.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*([^\s+]+)', multiLine: true)
        .firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has a version line');
    expect(appVersion, match!.group(1));
  });
}

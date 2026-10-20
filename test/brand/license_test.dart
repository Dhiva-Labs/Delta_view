import 'dart:io';

import 'package:delta_view/ui/brand/app_info.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the repository is MIT licensed, as the About dialog says', () {
    final text = File('LICENSE').readAsStringSync();
    expect(text, startsWith('MIT License'));
    expect(text, contains('Copyright (c) 2026 Dhiva Labs'));
    expect(appLicense, 'MIT License');
  });

  test('the licence page lists DeltaView with the LICENSE text', () async {
    registerAppLicense();
    final entries = await LicenseRegistry.licenses.toList();
    final ours = entries.where((e) => e.packages.contains(appName));
    expect(ours, isNotEmpty);
    final body =
        ours.first.paragraphs.map((p) => p.text).join('\n');
    expect(body, contains('Permission is hereby granted'));
  });
}

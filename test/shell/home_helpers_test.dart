import 'dart:io';

import 'package:delta_view/compare/comparison.dart';
import 'package:delta_view/ui/home/relative_time.dart';
import 'package:delta_view/ui/home/side_slot.dart';
import 'package:delta_view/ui/shortcuts/key_caps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('relativeTime', () {
    final now = DateTime(2026, 10, 21, 14, 0);
    String at(Duration ago) => relativeTime(now.subtract(ago), now: now);

    test('reads naturally at every scale', () {
      expect(at(Duration.zero), 'just now');
      expect(at(const Duration(seconds: 30)), 'just now');
      expect(at(const Duration(minutes: 5)), '5 min ago');
      expect(at(const Duration(hours: 1)), '1 hour ago');
      expect(at(const Duration(hours: 5)), '5 hours ago');
      expect(at(const Duration(hours: 30)), 'yesterday');
      expect(at(const Duration(days: 3)), '3 days ago');
      expect(at(const Duration(days: 10)), '11 Oct');
      expect(at(const Duration(days: 400)), '16 Sep 2025');
    });

    test('a time in the future is just now', () {
      expect(relativeTime(now.add(const Duration(hours: 1)), now: now),
          'just now');
    });
  });

  group('SideSlot', () {
    late Directory dir;
    late String file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('delta_view_slot');
      file = p.join(dir.path, 'a.txt');
      File(file).writeAsStringSync('hi');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('reports whether what it holds fits the mode', () {
      final slot = SideSlot('Left');
      expect(slot.status(SlotKind.folder), SlotStatus.empty);

      slot.setSpec(LocalSource(dir.path));
      expect(slot.status(SlotKind.folder), SlotStatus.ready);
      expect(slot.status(SlotKind.file), SlotStatus.wrongKind);
      expect(slot.controller.text, dir.path);

      slot.setSpec(LocalSource(file));
      expect(slot.status(SlotKind.file), SlotStatus.ready);

      slot.setSpec(LocalSource(p.join(dir.path, 'missing')));
      expect(slot.status(SlotKind.file), SlotStatus.missing);
      expect(slot.status(SlotKind.file, mayBeMissing: true), SlotStatus.ready);
      slot.dispose();
    });

    test('keeps a path across a mode switch only while it fits', () {
      final slot = SideSlot('Right')..setSpec(LocalSource(file));
      slot.keepIfFits(SlotKind.file);
      expect(slot.isEmpty, isFalse);
      slot.keepIfFits(SlotKind.folder);
      expect(slot.isEmpty, isTrue);
      expect(slot.controller.text, '');
      slot.dispose();
    });

    test('typed paths expand ~ and clear when blank', () {
      final slot = SideSlot('Left');
      slot.controller.text = '~/x';
      slot.setTypedPath('~/x');
      expect((slot.spec as LocalSource).path, isNot(startsWith('~')));
      slot.setTypedPath('   ');
      expect(slot.spec, isNull);
      slot.dispose();
    });

    test('non-local sources are kept read-only and count as ready', () {
      final slot = SideSlot('Left')
        ..setSpec(const ArchiveSource('/tmp/x.zip', innerPath: 'src'));
      expect(slot.isPicked, isTrue);
      expect(slot.controller.text, '');
      expect(slot.status(SlotKind.folder), SlotStatus.ready);
      slot.keepIfFits(SlotKind.file);
      expect(slot.isEmpty, isFalse);
      slot.dispose();
    });

    test('swap exchanges sources and field text', () {
      final a = SideSlot('Left')..setSpec(LocalSource(dir.path));
      final b = SideSlot('Right');
      a.swapWith(b);
      expect(a.isEmpty, isTrue);
      expect(b.localPath, dir.path);
      expect(b.controller.text, dir.path);
      a.dispose();
      b.dispose();
    });
  });

  testWidgets('KeyCaps draws one cap per key, including a literal plus',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          KeyCaps('Ctrl+Shift+V'),
          KeyCaps('Ctrl++'),
        ]),
      ),
    ));
    expect(find.text('Ctrl'), findsNWidgets(2));
    expect(find.text('Shift'), findsOneWidget);
    expect(find.text('V'), findsOneWidget);
    // The separators are drawn as '+' too, so count the cap for the key.
    final caps = tester.widgetList<Text>(find.text('+')).toList();
    expect(caps.where((t) => t.style?.fontWeight == FontWeight.w600),
        hasLength(1));
  });
}

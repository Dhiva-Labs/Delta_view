import 'dart:io';

import 'package:delta_view/compare/folder_compare.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempRoot;
  late String left;
  late String right;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('delta_view_test');
    left = p.join(tempRoot.path, 'left');
    right = p.join(tempRoot.path, 'right');

    // Identical file on both sides.
    File(p.join(left, 'same.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('unchanged\n');
    File(p.join(right, 'same.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('unchanged\n');

    // Same size, different content — must be caught by the byte compare.
    File(p.join(left, 'mod.txt')).writeAsStringSync('aaaa');
    File(p.join(right, 'mod.txt')).writeAsStringSync('aaab');

    // One-sided entries.
    File(p.join(left, 'gone.txt')).writeAsStringSync('left only');
    File(p.join(right, 'new', 'added.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('right only');
  });

  tearDown(() => tempRoot.deleteSync(recursive: true));

  test('classifies identical, modified, and one-sided entries', () async {
    final root = await compareFolders(left, right);

    expect(root.identicalCount, 1);
    expect(root.modifiedCount, 1);
    expect(root.onlyLeftCount, 1);
    expect(root.onlyRightCount, 1);

    final byName = {for (final c in root.children) c.name: c};
    expect(byName['same.txt']!.status, EntryStatus.identical);
    expect(byName['mod.txt']!.status, EntryStatus.modified);
    // 'aaaa' → 'aaab': one line replaced = one added + one removed.
    expect(byName['mod.txt']!.addedLines, 1);
    expect(byName['mod.txt']!.removedLines, 1);
    expect(byName['same.txt']!.addedLines, isNull);
    expect(byName['gone.txt']!.status, EntryStatus.onlyLeft);
    expect(byName['new']!.status, EntryStatus.onlyRight);
    expect(byName['new']!.children.single.name, 'added.txt');
  });

  test('identical trees report no changes', () async {
    File(p.join(left, 'mod.txt')).writeAsStringSync('aaab');
    File(p.join(left, 'gone.txt')).deleteSync();
    File(p.join(left, 'new', 'added.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('right only');

    final root = await compareFolders(left, right);
    expect(root.changedCount, 0);
    expect(root.hasChanges, isFalse);
  });
}

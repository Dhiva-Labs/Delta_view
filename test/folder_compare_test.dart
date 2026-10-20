import 'dart:io';

import 'package:delta_view/compare/folder_compare.dart';
import 'package:delta_view/compare/sources/file_source.dart';
import 'package:delta_view/diff/compare_options.dart';
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

  Future<ScanResult> scan({ScanOptions options = const ScanOptions()}) =>
      compareFolders(LocalSource(left), LocalSource(right), options: options);

  test('classifies identical, modified, and one-sided entries', () async {
    final result = await scan();
    final root = result.root;

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
    expect(byName['new']!.children.single.relativePath, 'new/added.txt');
    expect(result.leftWritable && result.rightWritable, isTrue);
    expect(result.leftLocal && result.rightLocal, isTrue);
  });

  test('identical trees report no changes', () async {
    File(p.join(left, 'mod.txt')).writeAsStringSync('aaab');
    File(p.join(left, 'gone.txt')).deleteSync();
    File(p.join(left, 'new', 'added.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('right only');

    final root = (await scan()).root;
    expect(root.changedCount, 0);
    expect(root.hasChanges, isFalse);
  });

  test('large same-size local files compare in chunks', () async {
    final big = List<int>.generate(3 * 1024 * 1024, (i) => i % 251);
    File(p.join(left, 'big.bin')).writeAsBytesSync(big);
    File(p.join(right, 'big.bin')).writeAsBytesSync(big);
    File(p.join(left, 'big2.bin')).writeAsBytesSync(big);
    File(p.join(right, 'big2.bin'))
        .writeAsBytesSync([...big.sublist(0, big.length - 1), 7]);

    final byName = {for (final c in (await scan()).root.children) c.name: c};
    expect(byName['big.bin']!.status, EntryStatus.identical);
    expect(byName['big2.bin']!.status, EntryStatus.modified);
  });

  test('settings ignore patterns and .gitignore leave entries out', () async {
    File(p.join(left, 'node_modules', 'x.js'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    File(p.join(right, '.gitignore')).writeAsStringSync('*.tmp\n');
    File(p.join(left, 'a.tmp')).writeAsStringSync('t');

    final result = await scan(
        options: const ScanOptions(ignorePatterns: ['node_modules']));
    final names = result.root.children.map((c) => c.name).toSet();
    expect(names, isNot(contains('node_modules')));
    // The right side's .gitignore applies to the left's entries too.
    expect(names, isNot(contains('a.tmp')));
    expect(names, contains('.gitignore'));
    expect(result.ignoredCount, 2);
    expect(result.ignoredPaths, containsAll(['node_modules', 'a.tmp']));
  });

  test('text rules make line-ending-only changes identical', () async {
    File(p.join(left, 'crlf.txt')).writeAsStringSync('a\r\nb\r\n');
    File(p.join(right, 'crlf.txt')).writeAsStringSync('a\nb\n');

    final exact = await scan();
    final loose = await scan(
        options: const ScanOptions(compareOptions: CompareOptions()));
    CompareNode crlf(ScanResult r) =>
        r.root.children.firstWhere((c) => c.name == 'crlf.txt');
    expect(crlf(exact).status, EntryStatus.modified);
    expect(crlf(loose).status, EntryStatus.identical);
  });

  test('line endings still count when only other rules are relaxed',
      () async {
    File(p.join(left, 'crlf.txt')).writeAsStringSync('A\r\nb\r\n');
    File(p.join(right, 'crlf.txt')).writeAsStringSync('a\nb\n');

    final result = await scan(
        options: const ScanOptions(
            compareOptions:
                CompareOptions(ignoreCase: true, ignoreLineEndings: false)));
    final node = result.root.children.firstWhere((c) => c.name == 'crlf.txt');
    expect(node.status, EntryStatus.modified);
  });

  test('UTF-16 files are compared as text, not as binary', () async {
    List<int> utf16le(String text) => [
          0xFF, 0xFE,
          for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
        ];
    File(p.join(left, 'wide.txt')).writeAsBytesSync(utf16le('Hello\nworld\n'));
    File(p.join(right, 'wide.txt'))
        .writeAsBytesSync(utf16le('hello\nworld\nagain\n'));

    final result = await scan(
        options: const ScanOptions(
            compareOptions: CompareOptions(ignoreCase: true)));
    final node = result.root.children.firstWhere((c) => c.name == 'wide.txt');
    expect(node.status, EntryStatus.modified);
    expect(node.addedLines, 1);
    expect(node.removedLines, 0);
  });

  test('a missing folder fails with a clear message', () async {
    await expectLater(
      compareFolders(LocalSource(p.join(tempRoot.path, 'nope')),
          LocalSource(right)),
      throwsA(isA<ScanFailure>().having(
          (f) => f.message, 'message', contains('left folder does not exist'))),
    );
  });

  test('a remote side without credentials fails with a sign-in message',
      () async {
    await expectLater(
      compareFolders(LocalSource(left),
          const SftpSource(host: 'h', username: 'u', path: '/srv')),
      throwsA(isA<ScanFailure>()
          .having((f) => f.unsupported, 'unsupported', isFalse)
          .having((f) => '$f', 'message', contains('Sign in to u@h'))),
    );
  });

  test('a cancelled scan stops and reports it', () async {
    final scan = FolderScan.start(LocalSource(left), LocalSource(right));
    scan.cancel();
    await expectLater(scan.result, throwsA(isA<ScanCancelled>()));
    expect(scan.isRunning, isFalse);
  });
}

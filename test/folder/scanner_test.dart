import 'package:delta_view/compare/folder_compare.dart';
import 'package:delta_view/compare/sources/file_source.dart';
import 'package:delta_view/diff/compare_options.dart';
import 'package:flutter_test/flutter_test.dart';

import 'memory_source.dart';

Future<ScanResult> scan(MemorySource left, MemorySource right,
        [ScanOptions options = const ScanOptions()]) =>
    FolderScanner(left, right, options: options).run();

CompareNode find(CompareNode root, String path) {
  for (final child in root.children) {
    if (child.relativePath == path) return child;
    if (path.startsWith('${child.relativePath}/')) return find(child, path);
  }
  throw StateError('$path not in tree');
}

void main() {
  test('works on any FileSource, with /-separated paths', () async {
    final left = MemorySource({
      'a/b/same.txt': 'x',
      'a/b/mod.txt': 'one\n',
      'a/left.txt': 'l',
    });
    final right = MemorySource({
      'a/b/same.txt': 'x',
      'a/b/mod.txt': 'two\n',
      'a/c/right.txt': 'r',
    });
    final root = (await scan(left, right)).root;

    expect(find(root, 'a/b/same.txt').status, EntryStatus.identical);
    expect(find(root, 'a/b/mod.txt').status, EntryStatus.modified);
    expect(find(root, 'a/left.txt').status, EntryStatus.onlyLeft);
    expect(find(root, 'a/c').status, EntryStatus.onlyRight);
    expect(find(root, 'a/c/right.txt').status, EntryStatus.onlyRight);
    expect(find(root, 'a').status, EntryStatus.modified);
    expect(root.modifiedCount, 1);
    expect(root.onlyLeftCount, 1);
    expect(root.onlyRightCount, 1);
    expect(root.identicalCount, 1);
  });

  test('folders come first, names in natural order', () async {
    final left = MemorySource({
      'file10.txt': '',
      'file2.txt': '',
      'Zeta/x': '',
      'alpha/x': '',
    });
    final root = (await scan(left, MemorySource({}))).root;
    expect(root.children.map((c) => c.name),
        ['alpha', 'Zeta', 'file2.txt', 'file10.txt']);
  });

  test('folder sizes add up the files inside', () async {
    final left = MemorySource({'d/a': '123', 'd/e/b': '45'});
    final right = MemorySource({'d/a': '1'});
    final d = find((await scan(left, right)).root, 'd');
    expect(d.leftSize, 5);
    expect(d.rightSize, 1);
  });

  test('a new empty folder counts as a change', () async {
    final left = MemorySource({'empty': const Folder(), 'same': 's'});
    final right = MemorySource({'same': 's'});
    final root = (await scan(left, right)).root;
    expect(find(root, 'empty').status, EntryStatus.onlyLeft);
    expect(find(root, 'empty').hasChanges, isTrue);
    expect(root.onlyLeftCount, 1);
    expect(root.hasChanges, isTrue);
  });

  test('a file on one side and a folder on the other', () async {
    final left = MemorySource({'thing': 'file'});
    final right = MemorySource({'thing/inner.txt': 'in a folder'});
    final node = find((await scan(left, right)).root, 'thing');
    expect(node.isTypeConflict, isTrue);
    expect(node.folderSide, Side.right);
    expect(node.status, EntryStatus.modified);
    expect(node.isDirectoryOn(Side.left), isFalse);
    expect(node.isDirectoryOn(Side.right), isTrue);
    expect(node.children.single.relativePath, 'thing/inner.txt');
  });

  group('ignore rules', () {
    test('ignored entries are never listed or read', () async {
      final left = MemorySource({
        'node_modules/pkg/index.js': 'a',
        'src/x.pyc': 'b',
        'src/main.py': 'same',
      });
      final right = MemorySource({
        'node_modules/pkg/index.js': 'different',
        'src/x.pyc': 'c',
        'src/main.py': 'same',
      });
      final result = await scan(left, right,
          const ScanOptions(ignorePatterns: ['node_modules', '*.pyc']));
      expect(result.root.changedCount, 0);
      expect(result.ignoredCount, 2);
      for (final source in [left, right]) {
        expect(source.listed, isNot(contains('node_modules')));
        expect(source.reads.where((r) => r.contains('node_modules')), isEmpty);
        expect(source.reads, isNot(contains('src/x.pyc')));
      }
    });

    test('.gitignore files on both sides apply, per folder', () async {
      final left = MemorySource({
        '.gitignore': 'dist/\n*.log\n',
        'dist/bundle.js': 'l',
        'pkg/.gitignore': '!keep.log\n/local\n',
        'pkg/keep.log': 'k',
        'pkg/drop.log': 'd',
        'pkg/local': 'x',
        'pkg/sub/local': 'y',
      });
      final right = MemorySource({
        'cache/x': 'r',
        'cache/.gitignore': '*\n',
      });
      final result = await scan(left, right);
      final root = result.root;
      final all = <String>[];
      void walk(CompareNode n) {
        for (final c in n.children) {
          all.add(c.relativePath);
          walk(c);
        }
      }

      walk(root);
      expect(all, isNot(contains('dist')));
      expect(all, contains('pkg/keep.log'));
      expect(all, isNot(contains('pkg/drop.log')));
      expect(all, isNot(contains('pkg/local')));
      expect(all, contains('pkg/sub/local'));
      // `*` in cache/.gitignore hides everything there, itself included.
      expect(all, contains('cache'));
      expect(all, isNot(contains('cache/x')));
      expect(left.reads, isNot(contains('dist/bundle.js')));
    });

    test('.gitignore can be switched off', () async {
      final left = MemorySource({'.gitignore': '*.log\n', 'a.log': 'x'});
      final result = await scan(left, MemorySource({}),
          const ScanOptions(respectGitignore: false));
      expect(result.root.children.map((c) => c.name), contains('a.log'));
      expect(left.reads, isEmpty);
    });
  });

  group('quick compare', () {
    final t = DateTime(2026, 3, 1, 12);

    test('size and time decide; nothing is read', () async {
      final left = MemorySource({}, time: t)
        ..put('same', 'aaaa', modified: t)
        ..put('newer', 'aaaa', modified: t)
        ..put('size', 'aaaa', modified: t)
        ..put('rounded', 'aaaa', modified: t);
      final right = MemorySource({}, time: t)
        ..put('same', 'bbbb', modified: t) // same size and time: identical
        ..put('newer', 'aaaa', modified: t.add(const Duration(minutes: 1)))
        ..put('size', 'aaaaa', modified: t)
        ..put('rounded', 'aaaa', modified: t.add(const Duration(seconds: 1)));
      final root =
          (await scan(left, right, const ScanOptions(quick: true))).root;
      expect(find(root, 'same').status, EntryStatus.identical);
      expect(find(root, 'newer').status, EntryStatus.modified);
      expect(find(root, 'size').status, EntryStatus.modified);
      expect(find(root, 'rounded').status, EntryStatus.identical,
          reason: 'two-second rounding of FAT and zip times');
      expect(left.reads, isEmpty);
      expect(right.reads, isEmpty);
    });

    test('a full compare reads and sees the difference', () async {
      final left = MemorySource({}, time: t)..put('f', 'aaaa', modified: t);
      final right = MemorySource({}, time: t)..put('f', 'bbbb', modified: t);
      final root = (await scan(left, right)).root;
      expect(find(root, 'f').status, EntryStatus.modified);
    });
  });

  group('text rules in a full compare', () {
    Future<EntryStatus> compare(
        String a, String b, CompareOptions options) async {
      final root = (await scan(MemorySource({'f.txt': a}),
              MemorySource({'f.txt': b}), ScanOptions(compareOptions: options)))
          .root;
      return find(root, 'f.txt').status;
    }

    test('whitespace, case, line endings and blank lines', () async {
      const loose = CompareOptions(
        whitespace: WhitespaceMode.changes,
        ignoreCase: true,
        ignoreBlankLines: true,
      );
      expect(await compare('A  b\r\n', 'a b\n', loose), EntryStatus.identical);
      expect(await compare('a\n\n\nb\n', 'a\nb\n', loose),
          EntryStatus.identical);
      expect(await compare('a\n', 'b\n', loose), EntryStatus.modified);
      expect(await compare('A  b\r\n', 'a b\n', CompareOptions.exact),
          EntryStatus.modified);
    });

    test('binary files never match by text rules', () async {
      expect(
          await compare('a\u0000\r\n', 'a\u0000\n', const CompareOptions()),
          EntryStatus.modified);
    });

    test('line stats follow the rules', () async {
      final root = (await scan(
              MemorySource({'f': 'a\nB\nc\n'}),
              MemorySource({'f': 'a\nb\nc\nd\n'}),
              const ScanOptions(
                  compareOptions: CompareOptions(ignoreCase: true))))
          .root;
      final f = find(root, 'f');
      expect(f.status, EntryStatus.modified);
      expect(f.addedLines, 1);
      expect(f.removedLines, 0);
    });
  });

  test('an unreadable folder is reported and the scan goes on', () async {
    final left = _BrokenListing({'ok/a': 'a', 'bad/b': 'b'});
    final result =
        await FolderScanner(left, MemorySource({'ok/a': 'a'})).run();
    expect(result.issues.single.path, 'bad');
    expect(find(result.root, 'ok/a').status, EntryStatus.identical);
  });
}

class _BrokenListing extends MemorySource {
  _BrokenListing(super.files);

  @override
  Future<List<SourceEntry>> list(String relative) async {
    if (relative == 'bad') throw StateError('Permission denied');
    return super.list(relative);
  }
}

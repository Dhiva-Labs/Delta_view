import 'package:delta_view/compare/folder_compare.dart';
import 'package:delta_view/compare/folder_format.dart';
import 'package:delta_view/ui/folder/tree_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'memory_source.dart';

Future<FolderTreeModel> _model() async {
  final t = DateTime(2026, 5, 1);
  final left = MemorySource({}, time: t)
    ..put('src/app.dart', 'one', modified: t)
    ..put('src/big.dart', 'a much longer file', modified: t)
    ..put('docs/readme.md', 'same', modified: t)
    ..put('zz.txt', 'only here', modified: t.add(const Duration(days: 1)));
  final right = MemorySource({}, time: t)
    ..put('src/app.dart', 'two', modified: t)
    ..put('src/big.dart', 'a much longer file', modified: t)
    ..put('docs/readme.md', 'same', modified: t)
    ..put('aa.txt', 'new', modified: t);
  final result = await FolderScanner(left, right).run();
  return FolderTreeModel()..root = result.root;
}

List<String> _paths(FolderTreeModel m) =>
    [for (final r in m.rows) r.node.relativePath];

void main() {
  test('filters by status; folders show when something inside does',
      () async {
    final m = await _model()..filter = TreeFilter.changes;
    expect(_paths(m), ['src', 'aa.txt', 'zz.txt']);
    m.filter = TreeFilter.leftOnly;
    expect(_paths(m), ['zz.txt']);
    m.filter = TreeFilter.all;
    expect(_paths(m), ['docs', 'src', 'aa.txt', 'zz.txt']);
  });

  test('expanding shows children, indented', () async {
    final m = await _model()..filter = TreeFilter.all;
    m.setExpanded(m.nodeAt('src')!, true);
    expect(m.rows.map((r) => '${r.depth}:${r.node.name}'), [
      '0:docs',
      '0:src',
      '1:app.dart',
      '1:big.dart',
      '0:aa.txt',
      '0:zz.txt',
    ]);
    expect(m.indexOf('src/big.dart'), 3);
    m.collapseAll();
    expect(m.indexOf('src/big.dart'), -1);
  });

  test('a search opens folders holding matches', () async {
    final m = await _model()
      ..filter = TreeFilter.all
      ..query = 'BIG';
    expect(_paths(m), ['src', 'src/big.dart']);
    // Closing the folder during the search sticks until the search changes.
    m.setExpanded(m.nodeAt('src')!, false);
    expect(_paths(m), ['src']);
    m.query = 'big.';
    expect(_paths(m), ['src', 'src/big.dart']);
    // A folder whose own name matches shows all it holds once opened.
    m.query = 'src';
    expect(_paths(m), ['src']);
    m.setExpanded(m.nodeAt('src')!, true);
    expect(_paths(m), ['src', 'src/app.dart', 'src/big.dart']);
    expect(m.isShown(m.nodeAt('docs')!), isFalse);
  });

  test('sorting keeps folders first', () async {
    final m = await _model()..filter = TreeFilter.all;
    m.sort = const TreeSort(SortColumn.name, ascending: false);
    expect(_paths(m), ['src', 'docs', 'zz.txt', 'aa.txt']);
    m.sort = const TreeSort(SortColumn.modified, ascending: false);
    expect(_paths(m).last, 'aa.txt');
    expect(_paths(m)[2], 'zz.txt', reason: 'newest file first');
    m.sort = const TreeSort(SortColumn.size, side: Side.right);
    // aa.txt (3 bytes, right) before zz.txt (missing right, 9 on left).
    expect(_paths(m).sublist(2), ['aa.txt', 'zz.txt']);
  });

  group('formatting', () {
    test('natural name order', () {
      final names = ['file10', 'File2', 'file1', 'a', 'file02b'];
      names.sort(compareNatural);
      expect(names, ['a', 'file1', 'File2', 'file02b', 'file10']);
    });

    test('sizes, counts and durations', () {
      expect(formatSize(999), '999 B');
      expect(formatSize(1500), '1.5 kB');
      expect(formatSize(2500000), '2.5 MB');
      expect(formatCount(1234567), '1,234,567');
      expect(formatCount(12), '12');
      expect(formatElapsed(const Duration(seconds: 7)), '0:07');
      expect(formatElapsed(const Duration(minutes: 62, seconds: 9)),
          '1:02:09');
    });

    test('dates', () {
      final t = DateTime(2026, 10, 21, 14, 5);
      expect(formatDateShort(t), '21 Oct 2026 14:05');
      expect(formatDateIso(t), '2026-10-21 14:05');
      final now = DateTime(2026, 10, 21, 17, 5);
      expect(formatDateRelative(t, now: now), '3 h ago');
      expect(formatDateRelative(now.add(const Duration(minutes: 5)), now: now),
          'just now');
      expect(formatDateRelative(DateTime(2026, 10, 1), now: now),
          '1 Oct 2026 00:00');
    });
  });
}

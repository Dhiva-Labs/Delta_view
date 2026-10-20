import 'package:delta_view/compare/folder_compare.dart';
import 'package:delta_view/compare/folder_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'memory_source.dart';

final _old = DateTime(2026, 1, 1);
final _new = DateTime(2026, 2, 1);

/// left: a (changed, newer), b (only), d/e (only, in a folder), same
/// right: a (changed, older), c (only), x/ (only, empty), same
(MemorySource, MemorySource) _sides() {
  final left = MemorySource({}, name: 'L')
    ..put('a.txt', 'left a', modified: _new)
    ..put('b.txt', 'only left')
    ..put('d/e.txt', 'deep')
    ..put('same.txt', 'same');
  final right = MemorySource({'x': const Folder()}, name: 'R')
    ..put('a.txt', 'right a, longer', modified: _old)
    ..put('c.txt', 'only right')
    ..put('same.txt', 'same');
  return (left, right);
}

Future<CompareNode> _scan(MemorySource l, MemorySource r) async =>
    (await FolderScanner(l, r).run()).root;

String _describe(SyncOp op) =>
    '${op.kind.name} ${op.target.name} ${op.path}';

CompareNode _find(CompareNode root, String path) {
  for (final c in root.children) {
    if (c.relativePath == path) return c;
    if (path.startsWith('${c.relativePath}/')) return _find(c, path);
  }
  throw StateError(path);
}

void main() {
  test('mirror left to right copies, overwrites and deletes', () async {
    final (l, r) = _sides();
    final plan = planSync(await _scan(l, r), SyncMode.mirrorLeftToRight);
    expect(plan.ops.map(_describe), [
      'delete right x',
      'delete right c.txt',
      'copy right d/e.txt',
      'overwrite right a.txt',
      'copy right b.txt',
    ]);
    expect(plan.copyCount, 2);
    expect(plan.overwriteCount, 1);
    expect(plan.deleteCount, 2);
    expect(plan.bytesToWrite, 'left a'.length + 'only left'.length + 4);
    expect(plan.destructive, isTrue);
    expect(plan.targets, {Side.right});

    final errors = await runSyncPlan(plan, left: l, right: r);
    expect(errors, isEmpty);
    final after = await _scan(l, r);
    expect(after.changedCount, 0, reason: 'right now matches left');
  });

  test('mirror right to left mirrors the other way', () async {
    final (l, r) = _sides();
    final plan = planSync(await _scan(l, r), SyncMode.mirrorRightToLeft);
    expect(plan.ops.map(_describe), [
      'delete left d',
      'delete left b.txt',
      'createFolder left x',
      'overwrite left a.txt',
      'copy left c.txt',
    ]);
    expect(plan.deletedFiles, 2);
    await runSyncPlan(plan, left: l, right: r);
    expect(l.hasFolder('x'), isTrue);
    expect((await _scan(l, r)).changedCount, 0);
  });

  test('two-way copies both ways, newer wins, deletes nothing', () async {
    final (l, r) = _sides();
    final plan = planSync(await _scan(l, r), SyncMode.twoWay);
    expect(plan.ops.map(_describe), [
      'createFolder left x',
      'copy right d/e.txt',
      'overwrite right a.txt',
      'copy right b.txt',
      'copy left c.txt',
    ]);
    expect(plan.deleteCount, 0);
    await runSyncPlan(plan, left: l, right: r);
    expect(r.text('a.txt'), 'left a');
    expect((await _scan(l, r)).changedCount, 0);
  });

  test('two-way skips changes it cannot order', () async {
    final l = MemorySource({})..put('f', 'one', modified: _old);
    final r = MemorySource({})..put('f', 'two', modified: _old);
    final plan = planSync(await _scan(l, r), SyncMode.twoWay);
    expect(plan.isEmpty, isTrue);
    expect(plan.skipped.single.path, 'f');
  });

  test('copy a selection: new and changed files only, no deletes', () async {
    final (l, r) = _sides();
    final root = await _scan(l, r);
    final plan = planCopy(
        [_find(root, 'a.txt'), _find(root, 'd'), _find(root, 'c.txt')],
        from: Side.left);
    expect(plan.ops.map(_describe),
        ['overwrite right a.txt', 'copy right d/e.txt']);
    expect(plan.deleteCount, 0);
  });

  test('a folder and something inside it are handled once', () async {
    final (l, r) = _sides();
    final root = await _scan(l, r);
    final plan = planCopy([_find(root, 'd/e.txt'), _find(root, 'd')],
        from: Side.left);
    expect(plan.ops.map(_describe), ['copy right d/e.txt']);
  });

  test('delete on one side counts the files inside folders', () async {
    final l = MemorySource({'d/1': 'a', 'd/2/3': 'bb', 'f': 'x'});
    final r = MemorySource({'d/1': 'a'});
    final root = await _scan(l, r);
    final plan = planDelete([_find(root, 'd'), _find(root, 'f')],
        side: Side.left);
    expect(plan.ops.map(_describe), ['delete left d', 'delete left f']);
    expect(plan.deletedFiles, 3);
    expect(plan.ops.first.isDirectory, isTrue);
    expect(plan.ops.first.bytes, 3);
    await runSyncPlan(plan, left: l, right: r);
    expect(l.files, isEmpty);
  });

  test('a file replaces a folder of the same name', () async {
    final l = MemorySource({'thing': 'file'});
    final r = MemorySource({'thing/inner.txt': 'x'});
    final plan = planSync(await _scan(l, r), SyncMode.mirrorLeftToRight);
    expect(plan.ops.map(_describe), ['delete right thing', 'copy right thing']);
    await runSyncPlan(plan, left: l, right: r);
    expect(r.text('thing'), 'file');
    expect((await _scan(l, r)).changedCount, 0);
  });

  test('errors are collected and the rest still runs', () async {
    final (l, _) = _sides();
    final r = MemorySource({}, writable: false);
    final plan = planSync(await _scan(l, r), SyncMode.mirrorLeftToRight);
    final errors = await runSyncPlan(plan, left: l, right: r);
    expect(errors.length, plan.ops.length);
    expect(errors.first.message, contains('read-only'));
  });

  test('progress is reported and cancel stops between steps', () async {
    final (l, r) = _sides();
    final plan = planSync(await _scan(l, r), SyncMode.mirrorLeftToRight);
    final seen = <SyncProgress>[];
    await runSyncPlan(plan,
        left: l,
        right: r,
        onProgress: seen.add,
        isCancelled: () => seen.length >= 2);
    expect(seen.length, 3, reason: 'two steps, then the final report');
    expect(r.text('c.txt'), isNull, reason: 'the first steps ran');
    expect(r.text('b.txt'), isNull, reason: 'cancelled before copies');
  });
}

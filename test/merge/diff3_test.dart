import 'dart:math';

import 'package:delta_view/merge/merge_document.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _l(String s) => s.isEmpty ? [] : s.split(' ');

/// The clean merge result, or null when anything conflicts.
List<String>? _clean(List<MergeChunk> chunks) {
  if (chunks.any((c) => c.isConflict)) return null;
  return [for (final c in chunks) ...c.automatic];
}

List<MergeChunkKind> _kinds(List<MergeChunk> chunks) =>
    [for (final c in chunks) c.kind];

void main() {
  group('diff3Merge', () {
    test('identical inputs are one unchanged chunk', () {
      final chunks = diff3Merge(_l('a b c'), _l('a b c'), _l('a b c'));
      expect(_kinds(chunks), [MergeChunkKind.unchanged]);
      expect(_clean(chunks), _l('a b c'));
    });

    test('a change on one side merges cleanly', () {
      final chunks = diff3Merge(_l('a b c'), _l('a X c'), _l('a b c'));
      expect(_kinds(chunks), [
        MergeChunkKind.unchanged,
        MergeChunkKind.leftOnly,
        MergeChunkKind.unchanged,
      ]);
      expect(_clean(chunks), _l('a X c'));

      final right = diff3Merge(_l('a b c'), _l('a b c'), _l('a b Y'));
      expect(right.last.kind, MergeChunkKind.rightOnly);
      expect(_clean(right), _l('a b Y'));
    });

    test('changes to separate regions both apply', () {
      final chunks = diff3Merge(
        _l('1 2 3 4 5 6 7'),
        _l('1 L 3 4 5 6 7'),
        _l('1 2 3 4 5 R 7'),
      );
      expect(_clean(chunks), _l('1 L 3 4 5 R 7'));
      expect(chunks.where((c) => c.isChange).map((c) => c.kind),
          [MergeChunkKind.leftOnly, MergeChunkKind.rightOnly]);
    });

    test('the same change on both sides is taken once', () {
      final chunks = diff3Merge(_l('a b c'), _l('a X c'), _l('a X c'));
      expect(chunks[1].kind, MergeChunkKind.bothSame);
      expect(_clean(chunks), _l('a X c'));
    });

    test('different changes to the same line conflict', () {
      final chunks = diff3Merge(_l('a b c'), _l('a L c'), _l('a R c'));
      expect(_kinds(chunks), [
        MergeChunkKind.unchanged,
        MergeChunkKind.conflict,
        MergeChunkKind.unchanged,
      ]);
      final conflict = chunks[1];
      expect(conflict.base, ['b']);
      expect(conflict.left, ['L']);
      expect(conflict.right, ['R']);
      expect(conflict.baseStart, 1);
      expect(conflict.leftStart, 1);
      expect(conflict.rightStart, 1);
      expect(_clean(chunks), isNull);
    });

    test('changes to neighbouring lines conflict, like git', () {
      final chunks = diff3Merge(_l('a b c d'), _l('a L c d'), _l('a b R d'));
      final conflict = chunks.singleWhere((c) => c.isConflict);
      expect(conflict.base, _l('b c'));
      expect(conflict.left, _l('L c'));
      expect(conflict.right, _l('b R'));
    });

    test('a deletion against an edit of the same line conflicts', () {
      final chunks = diff3Merge(_l('a b c'), _l('a c'), _l('a B c'));
      final conflict = chunks.singleWhere((c) => c.isConflict);
      expect(conflict.left, isEmpty);
      expect(conflict.right, ['B']);
    });

    test('both sides deleting the same line merges cleanly', () {
      final chunks = diff3Merge(_l('a b c'), _l('a c'), _l('a c'));
      expect(chunks[1].kind, MergeChunkKind.bothSame);
      expect(_clean(chunks), _l('a c'));
    });

    test('insertions at the start', () {
      expect(_clean(diff3Merge(_l('a b'), _l('X a b'), _l('a b'))),
          _l('X a b'));
      expect(_clean(diff3Merge(_l('a b'), _l('X a b'), _l('X a b'))),
          _l('X a b'));
      final conflict = diff3Merge(_l('a b'), _l('X a b'), _l('Y a b'));
      expect(conflict.first.kind, MergeChunkKind.conflict);
      expect(conflict.first.base, isEmpty);
      expect(conflict.first.left, ['X']);
      expect(conflict.first.right, ['Y']);
    });

    test('insertions at the end', () {
      expect(_clean(diff3Merge(_l('a b'), _l('a b'), _l('a b Z'))),
          _l('a b Z'));
      final conflict = diff3Merge(_l('a b'), _l('a b X'), _l('a b Y'));
      expect(conflict.last.kind, MergeChunkKind.conflict);
      expect(conflict.last.baseStart, 2);
      expect(conflict.last.left, ['X']);
      expect(conflict.last.right, ['Y']);
    });

    test('an insertion at the start and a change at the end merge', () {
      final chunks = diff3Merge(
          _l('a b c d'), _l('START a b c d'), _l('a b c END'));
      expect(_clean(chunks), _l('START a b c END'));
    });

    test('empty base: one side adding is clean, both adding conflicts', () {
      expect(_kinds(diff3Merge([], [], [])), isEmpty);
      expect(_clean(diff3Merge([], _l('a b'), [])), _l('a b'));
      expect(_clean(diff3Merge([], [], _l('a b'))), _l('a b'));
      expect(_clean(diff3Merge([], _l('a b'), _l('a b'))), _l('a b'));
      final conflict = diff3Merge([], _l('a b'), _l('c'));
      expect(_kinds(conflict), [MergeChunkKind.conflict]);
      expect(conflict.single.left, _l('a b'));
      expect(conflict.single.right, ['c']);
    });

    test('a side emptying the file', () {
      expect(_clean(diff3Merge(_l('a b'), [], _l('a b'))), isEmpty);
      final conflict = diff3Merge(_l('a b'), [], _l('a B'));
      expect(conflict.any((c) => c.isConflict), isTrue);
    });

    test('a conflict in between clean changes keeps line positions', () {
      final base = _l('1 2 3 4 5 6 7 8 9');
      final left = _l('0 1 2 L 4 5 6 7 8 9');
      final right = _l('1 2 R 4 5 6 7 9 10');
      final chunks = diff3Merge(base, left, right);
      final conflict = chunks.singleWhere((c) => c.isConflict);
      expect(conflict.baseStart, 2);
      expect(conflict.leftStart, 3);
      expect(conflict.rightStart, 2);
      // Everything else applies.
      final doc = MergeDocument(chunks)
        ..take(chunks.indexOf(conflict), Resolution.left);
      expect(doc.resultLines(), _l('0 1 2 L 4 5 6 7 9 10'));
    });

    test('chunks always tile all three inputs (randomised)', () {
      final random = Random(42);
      List<String> mutate(List<String> lines) {
        final out = List.of(lines);
        final edits = random.nextInt(4);
        for (var e = 0; e < edits; e++) {
          final at = out.isEmpty ? 0 : random.nextInt(out.length + 1);
          switch (random.nextInt(3)) {
            case 0:
              out.insert(at, 'n${random.nextInt(5)}');
            case 1:
              if (at < out.length) out.removeAt(at);
            default:
              if (at < out.length) out[at] = 'e${random.nextInt(5)}';
          }
        }
        return out;
      }

      for (var round = 0; round < 500; round++) {
        final base = List.generate(random.nextInt(12), (i) => 'b$i');
        final left = mutate(base);
        final right = mutate(base);
        final chunks = diff3Merge(base, left, right);
        expect([for (final c in chunks) ...c.base], base);
        expect([for (final c in chunks) ...c.left], left);
        expect([for (final c in chunks) ...c.right], right);
        var b = 0, l = 0, r = 0;
        for (final c in chunks) {
          expect((c.baseStart, c.leftStart, c.rightStart), (b, l, r));
          b += c.base.length;
          l += c.left.length;
          r += c.right.length;
          switch (c.kind) {
            case MergeChunkKind.unchanged:
              expect(c.left, c.base);
              expect(c.right, c.base);
            case MergeChunkKind.leftOnly:
              expect(c.right, c.base);
            case MergeChunkKind.rightOnly:
              expect(c.left, c.base);
            case MergeChunkKind.bothSame:
              expect(c.left, c.right);
            case MergeChunkKind.conflict:
              expect(c.left, isNot(c.right));
          }
        }
        // Merging a side with itself never conflicts and gives that side.
        expect(_clean(diff3Merge(base, left, left)), left);
        expect(_clean(diff3Merge(base, base, right)), right);
      }
    });

    test('large inputs with scattered edits merge quickly', () {
      final base = List.generate(50000, (i) => 'line $i');
      final left = List.of(base);
      final right = List.of(base);
      for (var i = 100; i < 50000; i += 1000) {
        left[i] = 'left $i';
        right[i + 500] = 'right $i';
      }
      final sw = Stopwatch()..start();
      final chunks = diff3Merge(base, left, right);
      expect(sw.elapsedMilliseconds, lessThan(3000));
      expect(chunks.any((c) => c.isConflict), isFalse);
      expect(_clean(chunks)!.where((l) => l.startsWith('left')).length, 50);
    });
  });
}

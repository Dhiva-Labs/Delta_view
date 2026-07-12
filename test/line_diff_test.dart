import 'package:delta_view/diff/line_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('diffLines', () {
    test('identical inputs produce a single equal chunk', () {
      final chunks = diffLines(['a', 'b', 'c'], ['a', 'b', 'c']);
      expect(chunks, hasLength(1));
      expect(chunks.single.op, DiffOp.equal);
      expect(chunks.single.lines, ['a', 'b', 'c']);
    });

    test('pure insertion', () {
      final chunks = diffLines([], ['x', 'y']);
      expect(chunks.single.op, DiffOp.insert);
      expect(chunks.single.lines, ['x', 'y']);
    });

    test('pure deletion', () {
      final chunks = diffLines(['x', 'y'], []);
      expect(chunks.single.op, DiffOp.delete);
    });

    test('middle edit keeps surrounding context equal', () {
      final chunks = diffLines(['a', 'b', 'c', 'd'], ['a', 'X', 'c', 'd']);
      expect(chunks.first.op, DiffOp.equal);
      expect(chunks.first.lines, ['a']);
      expect(chunks.last.op, DiffOp.equal);
      expect(chunks.last.lines, ['c', 'd']);
      final middle = chunks.sublist(1, chunks.length - 1);
      expect(middle.any((c) => c.op == DiffOp.delete && c.lines == ['b']),
          isFalse);
      // Reconstruct both sides from the chunks to prove correctness.
      final left = <String>[];
      final right = <String>[];
      for (final c in chunks) {
        if (c.op != DiffOp.insert) left.addAll(c.lines);
        if (c.op != DiffOp.delete) right.addAll(c.lines);
      }
      expect(left, ['a', 'b', 'c', 'd']);
      expect(right, ['a', 'X', 'c', 'd']);
    });

    test('huge completely-different inputs finish fast via fallback', () {
      final a = List.generate(20000, (i) => 'left $i');
      final b = List.generate(20000, (i) => 'right $i');
      final sw = Stopwatch()..start();
      final chunks = diffLines(a, b);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(3000));
      // Fallback must still round-trip both sides exactly.
      final left = <String>[];
      final right = <String>[];
      for (final c in chunks) {
        if (c.op != DiffOp.insert) left.addAll(c.lines);
        if (c.op != DiffOp.delete) right.addAll(c.lines);
      }
      expect(left, a);
      expect(right, b);
    });

    test('large file with small edits still diffs exactly', () {
      final a = List.generate(20000, (i) => 'line $i');
      final b = List.of(a)
        ..[7000] = 'changed'
        ..insert(14000, 'inserted');
      final chunks = diffLines(a, b);
      final changed = chunks
          .where((c) => c.op != DiffOp.equal)
          .fold(0, (sum, c) => sum + c.lines.length);
      // Exactly one replaced pair and one insertion — no coarse fallback.
      expect(changed, 3);
    });

    test('round-trips arbitrary edits', () {
      final a = List.generate(200, (i) => 'line $i');
      final b = List.of(a)
        ..removeAt(10)
        ..insert(50, 'inserted')
        ..[100] = 'replaced';
      final chunks = diffLines(a, b);
      final left = <String>[];
      final right = <String>[];
      for (final c in chunks) {
        if (c.op != DiffOp.insert) left.addAll(c.lines);
        if (c.op != DiffOp.delete) right.addAll(c.lines);
      }
      expect(left, a);
      expect(right, b);
    });
  });

  group('buildSideBySide', () {
    test('pairs replaced lines as modified with intra-line spans', () {
      final result = buildSideBySide('hello world\nsame\n', 'hello there\nsame\n');
      expect(result.rows, hasLength(2));
      final first = result.rows.first;
      expect(first.kind, DiffRowKind.modified);
      expect(first.leftNumber, 1);
      expect(first.rightNumber, 1);
      expect(first.leftSpans, isNotEmpty);
      // "world" vs "there" — the changed region starts after "hello ".
      expect(first.leftSpans!.first.$1, 6);
      expect(result.rows[1].kind, DiffRowKind.same);
    });

    test('tracks change blocks for navigation', () {
      final result = buildSideBySide('a\nb\nc\n', 'a\nB\nc\nd\n');
      expect(result.changeBlocks, hasLength(2));
      expect(result.rows[result.changeBlocks[0]].kind, DiffRowKind.modified);
      expect(result.rows[result.changeBlocks[1]].kind, DiffRowKind.added);
    });

    test('handles empty right side', () {
      final result = buildSideBySide('a\nb\n', '');
      expect(result.rows, hasLength(2));
      expect(result.rows.every((r) => r.kind == DiffRowKind.removed), isTrue);
      expect(result.rows.every((r) => r.rightNumber == null), isTrue);
    });

    test('line numbers advance independently per side', () {
      final result = buildSideBySide('a\nx\nb\n', 'a\nb\nc\n');
      final last = result.rows.last;
      expect(last.rightText, 'c');
      expect(last.rightNumber, 3);
      expect(last.leftNumber, isNull);
    });
  });
}

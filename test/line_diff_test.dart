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
      final result =
          buildSideBySide('hello world\nsame\n', 'hello there\nsame\n');
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

  group('compare options', () {
    List<DiffRowKind> kinds(String a, String b, CompareOptions o) =>
        [for (final r in buildSideBySide(a, b, options: o).rows) r.kind];

    test('the default is exact', () {
      expect(
          kinds('a \n', 'a\n', CompareOptions.exact), [DiffRowKind.modified]);
    });

    test('whitespace modes', () {
      const trailing = CompareOptions(whitespace: WhitespaceMode.trailing);
      const changes = CompareOptions(whitespace: WhitespaceMode.changes);
      const all = CompareOptions(whitespace: WhitespaceMode.all);
      expect(kinds('a  \n', 'a\n', trailing), [DiffRowKind.same]);
      expect(kinds(' a\n', 'a\n', trailing), [DiffRowKind.modified]);
      expect(kinds('  a   b\n', 'a b\n', changes), [DiffRowKind.same]);
      expect(kinds('ab\n', 'a b\n', changes), [DiffRowKind.modified]);
      expect(kinds('ab\n', 'a b\n', all), [DiffRowKind.same]);
    });

    test('compares by key but shows the original text', () {
      final row = buildSideBySide('Hello\n', 'HELLO\n',
              options: const CompareOptions(ignoreCase: true))
          .rows
          .single;
      expect(row.kind, DiffRowKind.same);
      expect(row.leftText, 'Hello');
      expect(row.rightText, 'HELLO');
    });

    test('line endings count only when not ignored', () {
      expect(kinds('a\r\nb\r\n', 'a\nb\n', const CompareOptions()),
          [DiffRowKind.same, DiffRowKind.same]);
      expect(
          kinds('a\r\n', 'a\n', CompareOptions.exact), [DiffRowKind.modified]);
      // The only difference is the ending: no characters light up.
      final row = buildSideBySide('a\r\n', 'a\n').rows.single;
      expect(row.leftSpans, isEmpty);
      expect(row.rightSpans, isEmpty);
    });

    test('blank lines drop out but stay visible', () {
      const o = CompareOptions(ignoreBlankLines: true);
      final result = buildSideBySide('a\n\nb\n', 'a\nb\n\n\n', options: o);
      expect(result.changeBlocks, isEmpty);
      // Every line of both sides is still shown, in order.
      expect([for (final r in result.rows) r.leftNumber].nonNulls, [1, 2, 3]);
      expect(
          [for (final r in result.rows) r.rightNumber].nonNulls, [1, 2, 3, 4]);
    });

    test('intra-line emphasis skips what the rules ignore', () {
      const o =
          CompareOptions(whitespace: WhitespaceMode.changes, ignoreCase: true);
      final row = buildSideBySide('Foo  bar baz\n', 'foo bar qux\n', options: o)
          .rows
          .single;
      expect(row.kind, DiffRowKind.modified);
      // Only "baz" → "qux"; the case and the double space do not light up.
      expect(row.leftSpans, [(9, 12)]);
      expect(row.rightSpans, [(8, 11)]);
    });

    test('intra-line emphasis narrows a renamed word', () {
      final (left, right) = intraLineSpans(
          'int count = 0;', 'int counter = 0;', CompareOptions.exact);
      expect(left, isEmpty);
      expect(right, [(9, 11)]);
    });

    test('summary names the active rules', () {
      expect(CompareOptions.exact.summary, 'Exact compare');
      expect(
          const CompareOptions(
                  whitespace: WhitespaceMode.trailing, ignoreCase: true)
              .summary,
          'Ignoring trailing whitespace, case, line endings');
    });
  });
}

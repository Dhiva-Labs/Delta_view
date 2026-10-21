import 'package:delta_view/diff/change_blocks.dart';
import 'package:delta_view/diff/edit_history.dart';
import 'package:delta_view/diff/folding.dart';
import 'package:delta_view/diff/line_diff.dart';
import 'package:delta_view/diff/unified_diff.dart';
import 'package:flutter_test/flutter_test.dart';

/// Applies a block copy the way the view does and returns the new texts.
(String, String) _copy(String left, String right, int block,
    {required bool toRight}) {
  final blocks = changeBlocksOf(buildSideBySide(left, right));
  final edit = copyBlockEdit(blocks[block],
      leftText: left, rightText: right, toRight: toRight)!;
  return toRight ? (left, edit.applyTo(right)) : (edit.applyTo(left), right);
}

void main() {
  group('change blocks', () {
    test('cover the right lines on each side', () {
      final result = buildSideBySide('a\nb\nc\nd\n', 'a\nB\nc\nd\ne\n');
      final blocks = changeBlocksOf(result);
      expect(blocks, hasLength(2));
      expect((blocks[0].leftStart, blocks[0].leftEnd), (1, 2));
      expect((blocks[0].rightStart, blocks[0].rightEnd), (1, 2));
      expect(blocks[0].kind, DiffRowKind.modified);
      // A pure insertion: empty on the left, placed after line 4.
      expect((blocks[1].leftStart, blocks[1].leftEnd), (4, 4));
      expect((blocks[1].rightStart, blocks[1].rightEnd), (4, 5));
      expect(blocks[1].kind, DiffRowKind.added);
    });

    test('copying every block across makes the sides equal', () {
      const left = 'one\ntwo\nthree\nfour\n';
      const right = 'one\nTWO\nthree\nfive\nsix\n';
      var (l, r) = (left, right);
      while (changeBlocksOf(buildSideBySide(l, r)).isNotEmpty) {
        (l, r) = _copy(l, r, 0, toRight: true);
      }
      expect(r, left);
      expect(l, left);
    });

    test('copy keeps the target file\'s final newline as it was', () {
      // Left's last line has no newline; copying it into the middle of the
      // right must not glue it to the next line.
      final (_, r) = _copy('x\nnew', 'x\nold\n', 0, toRight: true);
      expect(r, 'x\nnew\n');
      // Right ends without a newline and keeps doing so.
      final (_, r2) = _copy('a\nb\nc\n', 'a\nB', 0, toRight: true);
      expect(r2, 'a\nb\nc');
    });

    test('copy into an empty side takes the source\'s final newline', () {
      final (_, r) = _copy('a\nb\n', '', 0, toRight: true);
      expect(r, 'a\nb\n');
    });

    test('delete removes one side of a block', () {
      const left = 'a\nb\nc\n', right = 'a\nX\nY\nc\n';
      final block = changeBlocksOf(buildSideBySide(left, right)).single;
      expect(
          deleteBlockEdit(block, right, left: false)!.applyTo(right), 'a\nc\n');
      expect(deleteBlockEdit(block, left, left: true)!.applyTo(left), 'a\nc\n');
    });
  });

  group('scroll alignment', () {
    test('carries a line across insertions and deletions', () {
      // Left: 10 lines. Right: 3 lines inserted after line 2, line 7
      // deleted.
      final left = [for (var i = 0; i < 10; i++) 'l$i'];
      final right = [...left.sublist(0, 2), 'x', 'y', 'z', ...left.sublist(2)]
        ..remove('l7');
      final result =
          buildSideBySide('${left.join('\n')}\n', '${right.join('\n')}\n');
      final anchors = lineAnchors(changeBlocksOf(result), 10, 12);
      // Before the insertion the sides match line for line.
      expect(mapLine(1.5, anchors, fromLeft: true), 1.5);
      // After it, the right is three lines further down.
      expect(mapLine(4, anchors, fromLeft: true), 7);
      // Inside the right's insertion the left stays put.
      expect(mapLine(3, anchors, fromLeft: false), 2);
      // Past the deleted line 7 the offset shrinks back to two.
      expect(mapLine(9, anchors, fromLeft: true), 11);
      expect(mapLine(11, anchors, fromLeft: false), 9);
    });
  });

  group('undo and redo', () {
    test('copy block, undo, redo', () {
      final history = EditHistory();
      final texts = ['a\nb\n', 'a\nB\n'];
      void apply(List<(int, TextEdit)> edits) {
        for (final (side, edit) in edits) {
          texts[side] = edit.applyTo(texts[side]);
        }
      }

      final block = changeBlocksOf(buildSideBySide(texts[0], texts[1])).single;
      final edit = copyBlockEdit(block,
          leftText: texts[0], rightText: texts[1], toRight: true)!;
      apply([(1, edit)]);
      history.push([(1, edit)], label: 'Copy to the right');
      expect(texts[1], 'a\nb\n');
      expect(history.undoLabel, 'Copy to the right');

      apply(history.undo()!);
      expect(texts, ['a\nb\n', 'a\nB\n']);
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isTrue);

      apply(history.redo()!);
      expect(texts, ['a\nb\n', 'a\nb\n']);
      expect(history.canRedo, isFalse);
    });

    test('typing in one place is one step; a pause starts another', () {
      var now = DateTime(2026);
      final history = EditHistory(clock: () => now);
      var text = '';
      void type(String s) {
        final edit = TextEdit(text.length, '', s);
        text = edit.applyTo(text);
        history.recordTyping(0, edit);
        now = now.add(const Duration(milliseconds: 100));
      }

      type('h');
      type('i');
      now = now.add(const Duration(seconds: 2));
      type('!');
      for (final (_, e) in history.undo()!) {
        text = e.applyTo(text);
      }
      expect(text, 'hi');
      for (final (_, e) in history.undo()!) {
        text = e.applyTo(text);
      }
      expect(text, '');
    });

    test('a new edit clears redo', () {
      final history = EditHistory();
      history.push([(0, const TextEdit(0, '', 'x'))], label: 'one');
      history.undo();
      expect(history.canRedo, isTrue);
      history.push([(1, const TextEdit(0, '', 'y'))], label: 'two');
      expect(history.canRedo, isFalse);
    });

    test('TextEdit.between finds the smallest edit', () {
      final e = TextEdit.between('hello world', 'hello there world')!;
      expect((e.offset, e.removed, e.inserted), (6, '', 'there '));
      expect(e.applyTo('hello world'), 'hello there world');
      expect(e.inverse.applyTo('hello there world'), 'hello world');
      expect(TextEdit.between('same', 'same'), isNull);
    });
  });

  group('folding', () {
    List<DiffRow> rows(String kinds) => [
          for (final k in kinds.split(''))
            DiffRow(
                kind: k == '=' ? DiffRowKind.same : DiffRowKind.modified,
                leftNumber: 1,
                rightNumber: 1),
        ];

    test('keeps context around changes', () {
      // 10 same, change, 10 same.
      final r = rows('${'=' * 10}~${'=' * 10}');
      expect(foldRuns(r, context: 3), [
        const FoldRun(0, 7),
        const FoldRun(14, 21),
      ]);
    });

    test('short runs stay open', () {
      final r = rows('~=====~');
      // 5 same rows minus 3 + 3 context: nothing to hide.
      expect(foldRuns(r, context: 3), isEmpty);
      expect(foldRuns(rows('~${'=' * 9}~'), context: 3), [const FoldRun(4, 7)]);
    });

    test('identical files fold to a single marker', () {
      expect(foldRuns(rows('=' * 50), context: 3), [const FoldRun(0, 50)]);
    });

    test('layout maps rows to items and back', () {
      final layout = FoldedLayout(21, const [FoldRun(0, 7), FoldRun(14, 21)]);
      expect(layout.length, 1 + 7 + 1);
      expect(layout.foldAt(0), const FoldRun(0, 7));
      expect(layout.rowAt(1), 7);
      expect(layout.itemOfRow(3), 0); // hidden in the first fold
      expect(layout.itemOfRow(10), 4);
      expect(layout.itemOfRow(20), 8);
      expect(layout.foldHiding(15), const FoldRun(14, 21));
      expect(layout.foldHiding(10), isNull);
    });
  });

  group('unified diff', () {
    test('headers, hunk ranges and three lines of context', () {
      final left = [for (var i = 1; i <= 20; i++) 'line $i'].join('\n');
      final right = left.replaceFirst('line 10', 'line ten');
      final patch = unifiedDiff('$left\n', '$right\n',
          leftName: 'a/file.txt', rightName: 'b/file.txt');
      expect(
        patch,
        '--- a/file.txt\n'
        '+++ b/file.txt\n'
        '@@ -7,7 +7,7 @@\n'
        ' line 7\n'
        ' line 8\n'
        ' line 9\n'
        '-line 10\n'
        '+line ten\n'
        ' line 11\n'
        ' line 12\n'
        ' line 13\n',
      );
    });

    test('nearby changes share a hunk; distant ones do not', () {
      final left = [for (var i = 1; i <= 30; i++) '$i'].join('\n');
      final right = left
          .replaceFirst(RegExp(r'^2$', multiLine: true), 'two')
          .replaceFirst(RegExp(r'^5$', multiLine: true), 'five')
          .replaceFirst(RegExp(r'^25$', multiLine: true), 'twenty-five');
      final patch = unifiedDiff('$left\n', '$right\n');
      expect(RegExp(r'^@@ ', multiLine: true).allMatches(patch), hasLength(2));
      expect(patch, contains('@@ -1,8 +1,8 @@'));
      expect(patch, contains('@@ -22,7 +22,7 @@'));
    });

    test('pure insertion and deletion ranges', () {
      expect(
          unifiedDiff('', 'a\nb\n'), '--- a\n+++ b\n@@ -0,0 +1,2 @@\n+a\n+b\n');
      expect(unifiedDiff('a\n', ''), '--- a\n+++ b\n@@ -1 +0,0 @@\n-a\n');
    });

    test('marks a missing final newline', () {
      expect(
        unifiedDiff('a\nb', 'a\nb\n'),
        '--- a\n+++ b\n@@ -1,2 +1,2 @@\n a\n-b\n'
        '\\ No newline at end of file\n+b\n',
      );
    });

    test('identical texts give an empty patch', () {
      expect(unifiedDiff('x\n', 'x\n'), isEmpty);
    });
  });
}

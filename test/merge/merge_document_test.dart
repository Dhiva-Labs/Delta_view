import 'package:delta_view/merge/merge_document.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _l(String s) => s.isEmpty ? [] : s.split(' ');

void main() {
  // base: a b c d e f g; left edits b and f, right edits b and adds h.
  MergeDocument doc() => MergeDocument.merge(
        _l('a b c d e f g'),
        _l('a L c d e F g'),
        _l('a R c d e f g h'),
      );

  int conflictOf(MergeDocument d) => d.conflictIndexes.single;

  group('MergeDocument', () {
    test('starts with clean changes merged and conflicts unresolved', () {
      final d = doc();
      expect(d.conflictCount, 1);
      expect(d.unresolvedCount, 1);
      final c = conflictOf(d);
      expect(d.state(c).resolution, Resolution.unresolved);
      // The placeholder for an unresolved conflict is the base text.
      expect(d.state(c).lines, ['b']);
      expect(d.revision, 0);
      expect(d.canUndo, isFalse);
    });

    test('unresolved conflicts are written as diff3 markers', () {
      final d = doc();
      expect(
        d.resultLines(
            labels: const MergeLabels(left: 'ours', base: 'o', right: 'th')),
        [
          'a',
          '<<<<<<< ours',
          'L',
          '||||||| o',
          'b',
          '=======',
          'R',
          '>>>>>>> th',
          'c', 'd', 'e', 'F', 'g', 'h',
        ],
      );
    });

    test('take left, right, both and base', () {
      final d = doc();
      final c = conflictOf(d);
      d.take(c, Resolution.left);
      expect(d.resultLines(), _l('a L c d e F g h'));
      expect(d.unresolvedCount, 0);
      d.take(c, Resolution.right);
      expect(d.resultLines(), _l('a R c d e F g h'));
      d.take(c, Resolution.leftThenRight);
      expect(d.resultLines(), _l('a L R c d e F g h'));
      d.take(c, Resolution.rightThenLeft);
      expect(d.resultLines(), _l('a R L c d e F g h'));
      d.take(c, Resolution.base);
      expect(d.resultLines(), _l('a b c d e F g h'));
      expect(d.state(c).resolution, Resolution.base);
      // Resetting brings the conflict back.
      d.take(c, Resolution.automatic);
      expect(d.unresolvedCount, 1);
    });

    test('appending composes both sides, Meld-style', () {
      final d = doc();
      final c = conflictOf(d);
      d.append(c, left: false); // unresolved: appending takes the side
      expect(d.state(c).resolution, Resolution.right);
      d.append(c, left: true);
      expect(d.state(c).resolution, Resolution.rightThenLeft);
      expect(d.state(c).lines, ['R', 'L']);
    });

    test('editing by hand, and edits that match a side say so', () {
      final d = doc();
      final c = conflictOf(d);
      d.edit(c, ['merged', 'by-hand']);
      expect(d.state(c).resolution, Resolution.edited);
      expect(d.resultLines(), _l('a merged by-hand c d e F g h'));
      d.edit(c, ['L']);
      expect(d.state(c).resolution, Resolution.left);
      // Editing a clean chunk back to its automatic text is automatic.
      final clean = d.changeIndexes.firstWhere((i) => i != c);
      d.edit(clean, ['x']);
      expect(d.state(clean).resolution, Resolution.edited);
      d.edit(clean, d.chunks[clean].automatic);
      expect(d.state(clean).resolution, Resolution.automatic);
    });

    test('undo and redo walk the history and restore revisions', () {
      final d = doc();
      final c = conflictOf(d);
      d.take(c, Resolution.left);
      final afterLeft = d.revision;
      d.take(c, Resolution.right);
      final afterRight = d.revision;
      expect(afterRight, isNot(afterLeft));

      expect(d.undo(), c);
      expect(d.revision, afterLeft);
      expect(d.state(c).resolution, Resolution.left);
      expect(d.undo(), c);
      expect(d.revision, 0);
      expect(d.unresolvedCount, 1);
      expect(d.undo(), isNull);

      expect(d.redo(), c);
      expect(d.revision, afterLeft);
      expect(d.redo(), c);
      expect(d.state(c).resolution, Resolution.right);
      expect(d.redo(), isNull);

      // A new edit after undo drops the redo branch.
      d.undo();
      d.take(c, Resolution.base);
      expect(d.canRedo, isFalse);
      expect(d.revision, isNot(afterRight));
    });

    test('no-op actions do not add history', () {
      final d = doc();
      final c = conflictOf(d);
      d.take(c, Resolution.automatic);
      expect(d.canUndo, isFalse);
      d.take(c, Resolution.left);
      d.take(c, Resolution.left);
      d.undo();
      expect(d.canUndo, isFalse);
    });

    test('take everywhere and reset all are single steps', () {
      final d = MergeDocument.merge(
        _l('a b c d e'),
        _l('A b c d E'),
        _l('1 b c d 5'),
      );
      expect(d.conflictCount, 2);
      d.takeAllConflicts(Resolution.right);
      expect(d.unresolvedCount, 0);
      expect(d.resultLines(), _l('1 b c d 5'));
      d.undo();
      expect(d.unresolvedCount, 2);
      d.redo();
      d.resetAll();
      expect(d.unresolvedCount, 2);
      d.undo();
      expect(d.unresolvedCount, 0);
    });

    test('a clean merge has no conflicts and needs no resolving', () {
      final d = MergeDocument.merge(_l('a b c'), _l('a b c X'), _l('Y a b c'));
      expect(d.conflictCount, 0);
      expect(d.resultLines(), _l('Y a b c X'));
    });
  });
}

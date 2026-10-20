/// Undo and redo for both sides of a comparison as one timeline, so
/// "copy this change to the right" and typing in either editor undo in
/// the order they happened.
library;

/// Replacing [removed] at [offset] with [inserted].
class TextEdit {
  const TextEdit(this.offset, this.removed, this.inserted);

  final int offset;
  final String removed;
  final String inserted;

  /// The smallest single edit that turns [before] into [after], or null
  /// when they are equal. Trims the common prefix and suffix, so typing a
  /// character anywhere costs one small edit.
  static TextEdit? between(String before, String after) {
    if (before == after) return null;
    final minLen = before.length < after.length ? before.length : after.length;
    var start = 0;
    while (
        start < minLen && before.codeUnitAt(start) == after.codeUnitAt(start)) {
      start++;
    }
    var endBefore = before.length, endAfter = after.length;
    while (endBefore > start &&
        endAfter > start &&
        before.codeUnitAt(endBefore - 1) == after.codeUnitAt(endAfter - 1)) {
      endBefore--;
      endAfter--;
    }
    return TextEdit(start, before.substring(start, endBefore),
        after.substring(start, endAfter));
  }

  String applyTo(String text) =>
      text.replaceRange(offset, offset + removed.length, inserted);

  TextEdit get inverse => TextEdit(offset, inserted, removed);

  /// Where the caret belongs after this edit.
  int get end => offset + inserted.length;

  @override
  String toString() => 'TextEdit($offset, "$removed" → "$inserted")';
}

/// One undoable step: edits to one or both sides (0 = left, 1 = right).
class HistoryEntry {
  HistoryEntry(List<(int, TextEdit)> edits,
      {required this.label, this.typing = false})
      : edits = List.of(edits),
        time = DateTime.now();

  final List<(int, TextEdit)> edits;

  /// e.g. "Copy to the right", shown in the Undo tooltip.
  final String label;

  /// Keystrokes that may still be merged with the next one.
  final bool typing;
  DateTime time;
}

class EditHistory {
  EditHistory({this.limit = 500, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// Oldest steps are forgotten past this many.
  final int limit;
  final DateTime Function() _clock;

  final _undo = <HistoryEntry>[];
  final _redo = <HistoryEntry>[];

  /// Typing pauses longer than this start a new undo step.
  static const typingPause = Duration(seconds: 1);

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  /// Records a discrete operation (copy, delete, paste) as its own step.
  void push(List<(int, TextEdit)> edits, {required String label}) {
    if (edits.isEmpty) return;
    _add(HistoryEntry(edits, label: label));
  }

  /// Records a keystroke-sized change from an editor, merging it into the
  /// previous step while the user keeps typing (or deleting) in one place.
  void recordTyping(int side, TextEdit edit) {
    final last = _undo.isEmpty ? null : _undo.last;
    final now = _clock();
    if (last != null &&
        last.typing &&
        last.edits.length == 1 &&
        last.edits.single.$1 == side &&
        now.difference(last.time) < typingPause) {
      final merged = _merge(last.edits.single.$2, edit);
      if (merged != null) {
        last.edits[0] = (side, merged);
        last.time = now;
        _redo.clear();
        return;
      }
    }
    _add(HistoryEntry([(side, edit)], label: 'Typing', typing: true)
      ..time = now);
  }

  /// [b] continues [a] when it types on right after it, or backspaces or
  /// deletes next to it. A new line ends the step so undo goes line by line.
  static TextEdit? _merge(TextEdit a, TextEdit b) {
    if (b.inserted.contains('\n')) return null;
    final typing = a.removed.isEmpty && b.removed.isEmpty;
    if (typing && b.offset == a.offset + a.inserted.length) {
      return TextEdit(a.offset, '', a.inserted + b.inserted);
    }
    final deleting = a.inserted.isEmpty && b.inserted.isEmpty;
    if (deleting && b.offset + b.removed.length == a.offset) {
      return TextEdit(b.offset, b.removed + a.removed, ''); // backspace
    }
    if (deleting && b.offset == a.offset) {
      return TextEdit(a.offset, a.removed + b.removed, ''); // delete key
    }
    return null;
  }

  void _add(HistoryEntry entry) {
    _undo.add(entry);
    _redo.clear();
    if (_undo.length > limit) _undo.removeAt(0);
  }

  /// Ends the current typing step, so the next keystroke starts a new one.
  void seal() {
    if (_undo.isNotEmpty && _undo.last.typing) {
      final last = _undo.removeLast();
      _undo.add(HistoryEntry(last.edits, label: last.label)..time = last.time);
    }
  }

  /// The edits that undo the last step, in the order to apply them.
  List<(int, TextEdit)>? undo() {
    if (_undo.isEmpty) return null;
    final entry = _undo.removeLast();
    _redo.add(HistoryEntry(entry.edits, label: entry.label));
    return [
      for (final (side, edit) in entry.edits.reversed) (side, edit.inverse),
    ];
  }

  /// The edits that redo the last undone step, in order.
  List<(int, TextEdit)>? redo() {
    if (_redo.isEmpty) return null;
    final entry = _redo.removeLast();
    _undo.add(HistoryEntry(entry.edits, label: entry.label));
    return entry.edits;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}

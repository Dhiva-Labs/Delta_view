/// Everything a file comparison knows, apart from how it is drawn: both
/// sides' text and formats, the current diff, undo history, search, and
/// watching the files on disk. The view listens to it and redraws.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../compare/diff_side.dart';
import '../../compare/sources/source_spec.dart';
import '../../diff/change_blocks.dart';
import '../../diff/edit_history.dart';
import '../../diff/line_diff.dart';
import '../../diff/text_codec.dart';
import 'side_model.dart';
import 'syntax.dart';

export '../../diff/change_blocks.dart' show ChangeBlock;
export '../../diff/text_codec.dart';
export 'side_model.dart';

/// Files bigger than this are not diffed as text.
const maxDiffBytes = 8 * 1024 * 1024;

/// Texts bigger than this (both sides together) are diffed on a background
/// isolate so typing and scrolling stay smooth.
const _isolateThreshold = 200 * 1024;

/// One search hit: [line] and the `[start, end)` columns in it, on [side]
/// (0 left, 1 right). [offset] is where it starts in the side's text.
class FindMatch {
  const FindMatch(this.side, this.line, this.start, this.end, this.offset);

  final int side;
  final int line;
  final int start;
  final int end;
  final int offset;
}

/// At most this many search hits are collected.
const maxFindMatches = 10000;

class DiffSession extends ChangeNotifier {
  DiffSession(DiffSide left, DiffSide right, {CompareOptions? options})
      : sides = [SideModel(left), SideModel(right)],
        options = options ?? const CompareOptions() {
    for (var i = 0; i < 2; i++) {
      sides[i].controller.addListener(() => _onText(i));
    }
  }

  final List<SideModel> sides;

  /// Why there is no text diff (binary or oversized files), or a read
  /// error.
  String? notice;
  Object? error;
  bool loaded = false;

  DiffResult? result;
  List<ChangeBlock> blocks = const [];

  /// Corresponding line positions, for carrying a scroll position across.
  List<(double, double)> anchors = const [(0, 0)];

  /// The row that shows each line of each side.
  List<Int32List> rowOfLine = [Int32List(0), Int32List(0)];

  /// Bumped whenever [result] is replaced, so views can drop caches.
  int version = 0;

  /// The rules in force. Starts from the app default; [optionsOverridden]
  /// once the user picks rules for this view.
  CompareOptions options;
  bool optionsOverridden = false;

  final history = EditHistory();
  SyntaxHighlighter? highlighter;

  /// Shows a short message (a toast) to the user.
  void Function(String message)? onNotify;

  // ---- search ----
  String query = '';
  bool matchCase = false;
  List<FindMatch> matches = const [];
  int currentMatch = -1;
  List<Map<int, List<FindMatch>>> matchesByLine = [{}, {}];

  FindMatch? get currentFindMatch =>
      currentMatch >= 0 && currentMatch < matches.length
          ? matches[currentMatch]
          : null;

  bool _programmatic = false;
  final _shadow = ['', ''];
  Timer? _debounce;
  int _generation = 0;
  (String, String, CompareOptions)? _lastDiffed;

  /// The isolate diff of [_lastDiffed] while it runs.
  Future<DiffResult>? _running;
  final _watchers = <FileWatcher?>[null, null];
  bool _disposed = false;

  bool get dirty => sides.any((s) => s.dirty);

  // ---- loading ----

  Future<void> load() async {
    try {
      final reads = [await _read(sides[0].side), await _read(sides[1].side)];
      if (reads.any((r) => r.binary)) {
        notice = 'Binary files — no text diff available.';
      } else if (reads.any((r) => r.tooLarge)) {
        notice = 'File is larger than 8 MB — text diff is disabled.';
      }
      if (notice != null) {
        _notify();
        return;
      }
      for (var i = 0; i < 2; i++) {
        final read = reads[i];
        sides[i].loaded(read.decoded!, bytes: read.bytes, exists: read.exists);
        _setText(i, read.decoded!.text);
        sides[i].writable = await _canWrite(sides[i].side);
      }
      // A side that does not exist yet is saved like the other side.
      for (var i = 0; i < 2; i++) {
        final s = sides[i], other = sides[1 - i];
        if (!s.exists && other.exists) {
          final ending = other.format.lineEnding == LineEnding.mixed
              ? (other.mixed?.mostlyCrlf ?? false
                  ? LineEnding.crlf
                  : LineEnding.lf)
              : other.format.lineEnding;
          s.format = s.savedFormat = other.format.copyWith(lineEnding: ending);
        }
      }
      highlighter =
          _highlighterFor(sides[0].side) ?? _highlighterFor(sides[1].side);
      await rediff();
      loaded = true;
      for (var i = 0; i < 2; i++) {
        _watch(i);
      }
    } catch (e) {
      error = e;
    }
    _notify();
  }

  static SyntaxHighlighter? _highlighterFor(DiffSide side) =>
      side.isMemory ? null : SyntaxHighlighter.forFile(side.label);

  static Future<bool> _canWrite(DiffSide side) async {
    try {
      return await side.canWrite();
    } catch (_) {
      return false;
    }
  }

  static Future<_Read> _read(DiffSide side) async {
    if (side.isMemory) {
      return _Read(decoded: decodeString(side.initialText ?? ''));
    }
    final bytes = await side.read();
    if (bytes == null) {
      return const _Read(decoded: DecodedText('', TextFormat()), exists: false);
    }
    if (bytes.length > maxDiffBytes) return const _Read(tooLarge: true);
    if (looksBinary(bytes)) return const _Read(binary: true);
    return _Read(decoded: decodeText(bytes), bytes: bytes);
  }

  /// Replaces a side's text without recording an undo step.
  void _setText(int side, String text) {
    _programmatic = true;
    try {
      sides[side].controller.value = TextEditingValue(text: text);
      _shadow[side] = text;
    } finally {
      _programmatic = false;
    }
    sides[side].updateDirty();
  }

  // ---- diffing ----

  void _onText(int side) {
    final s = sides[side];
    final text = s.text;
    if (identical(text, _shadow[side]) || text == _shadow[side]) return;
    if (!_programmatic) {
      final edit = TextEdit.between(_shadow[side], text);
      if (edit != null) history.recordTyping(side, edit);
    }
    _shadow[side] = text;
    s.updateDirty();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), rediff);
    _notify();
  }

  /// Diffs the current texts, unless nothing changed since the last time.
  /// Completes once [result] describes them, so callers can act on
  /// [blocks] right after.
  Future<void> rediff() async {
    _debounce?.cancel();
    final rules = options;
    final left = sides[0].diffText(rules);
    final right = sides[1].diffText(rules);
    final last = _lastDiffed;
    if (last != null &&
        last.$3 == rules &&
        last.$1 == left &&
        last.$2 == right) {
      // Already done, or running on the isolate: the call that started it
      // resumes first and stores the result.
      final running = _running;
      if (running != null) await running;
      if (this.result != null) return;
    }
    _lastDiffed = (left, right, rules);
    final generation = ++_generation;
    if (left.length + right.length <= _isolateThreshold) {
      _running = null;
      _setResult(buildSideBySide(left, right, options: rules));
      return;
    }
    final running = _running = _diffInIsolate(left, right, rules);
    final result = await running;
    if (identical(_running, running)) _running = null;
    // A newer request (or disposal) supersedes this one.
    if (_disposed || generation != _generation) return;
    _setResult(result);
  }

  /// Static so the isolate closure captures only plain data. A closure
  /// created inside an instance method drags `this` (and the controllers
  /// and listeners hanging off it) into the isolate message, which is
  /// unsendable.
  static Future<DiffResult> _diffInIsolate(
          String left, String right, CompareOptions options) =>
      Isolate.run(() => buildSideBySide(left, right, options: options));

  void _setResult(DiffResult result) {
    this.result = result;
    blocks = changeBlocksOf(result);
    var leftLines = 0, rightLines = 0;
    for (final row in result.rows) {
      if (row.leftNumber != null) leftLines = row.leftNumber!;
      if (row.rightNumber != null) rightLines = row.rightNumber!;
    }
    anchors = lineAnchors(blocks, leftLines, rightLines);
    final rows = [Int32List(leftLines), Int32List(rightLines)];
    for (var i = 0; i < result.rows.length; i++) {
      final row = result.rows[i];
      if (row.leftNumber != null) rows[0][row.leftNumber! - 1] = i;
      if (row.rightNumber != null) rows[1][row.rightNumber! - 1] = i;
    }
    rowOfLine = rows;
    version++;
    if (query.isNotEmpty) _search(keepCurrent: true);
    _notify();
  }

  void setOptions(CompareOptions options, {bool overridden = true}) {
    if (options == this.options && overridden == optionsOverridden) return;
    this.options = options;
    optionsOverridden = overridden;
    rediff();
    _notify();
  }

  // ---- editing ----

  /// Applies [edits] in order. With a [label] they become one undo step;
  /// without, they are an undo or redo being replayed.
  void applyEdits(List<(int, TextEdit)> edits, {String? label}) {
    if (edits.isEmpty) return;
    _programmatic = true;
    try {
      for (final (side, edit) in edits) {
        final s = sides[side];
        final text = edit.applyTo(s.text);
        s.controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: edit.end),
        );
        _shadow[side] = text;
        s.updateDirty();
      }
    } finally {
      _programmatic = false;
    }
    if (label != null) history.push(edits, label: label);
    rediff();
    _notify();
  }

  /// Copies change block [index] across. False when there was nothing to
  /// copy.
  Future<bool> copyBlock(int index, {required bool toRight}) async {
    await rediff();
    if (index < 0 || index >= blocks.length) return false;
    final edit = copyBlockEdit(blocks[index],
        leftText: sides[0].text, rightText: sides[1].text, toRight: toRight);
    if (edit == null) return false;
    applyEdits([(toRight ? 1 : 0, edit)],
        label: toRight ? 'Copy to the right' : 'Copy to the left');
    return true;
  }

  /// Removes one side of change block [index].
  Future<bool> deleteBlock(int index, {required bool left}) async {
    await rediff();
    if (index < 0 || index >= blocks.length) return false;
    final side = left ? 0 : 1;
    final edit = deleteBlockEdit(blocks[index], sides[side].text, left: left);
    if (edit == null) return false;
    applyEdits([(side, edit)],
        label: left ? 'Delete on the left' : 'Delete on the right');
    return true;
  }

  /// Replaces all of one side's text as one undo step (Paste).
  void replaceText(int side, String text, {required String label}) {
    final edit = TextEdit.between(sides[side].text, text);
    if (edit != null) applyEdits([(side, edit)], label: label);
  }

  void undo() {
    history.seal();
    final edits = history.undo();
    if (edits != null) applyEdits(edits);
  }

  void redo() {
    history.seal();
    final edits = history.redo();
    if (edits != null) applyEdits(edits);
  }

  /// The format [side] is saved in next time.
  void setFormat(int side, TextFormat format) {
    final s = sides[side];
    if (s.format == format) return;
    s.format = format;
    s.updateDirty();
    if (!options.ignoreLineEndings) rediff();
    _notify();
  }

  // ---- saving and reloading ----

  /// Writes [side] in place in its format. Throws on failure, including
  /// [UnencodableTextException].
  Future<void> save(int side) async {
    final s = sides[side];
    final bytes = encodeText(s.text, s.format, mixed: s.mixed);
    await s.side.write(bytes);
    s.saved(bytes);
    _notify();
  }

  /// Writes [side] to the local file [path], which it then becomes.
  Future<void> saveAs(int side, String path) async {
    final s = sides[side];
    final bytes = encodeText(s.text, s.format, mixed: s.mixed);
    final target = DiffSide.source(LocalSource(path));
    await target.write(bytes);
    s.side = target;
    s.writable = true;
    s.saved(bytes);
    highlighter ??= _highlighterFor(target);
    _watch(side);
    _notify();
  }

  /// Reads both file sides from disk again. Unsaved edits are replaced;
  /// the reload is one undo step, so it can be taken back.
  Future<void> reloadAll() async {
    final edits = <(int, TextEdit)>[];
    for (var i = 0; i < 2; i++) {
      final s = sides[i];
      if (s.isMemory) continue;
      final read = await _read(s.side);
      if (read.decoded == null) {
        onNotify?.call('${s.label} can no longer be shown as text');
        continue;
      }
      final edit = _reloadEdit(i, read);
      if (edit != null) edits.add((i, edit));
    }
    if (edits.isNotEmpty) {
      applyEdits(edits, label: 'Reload from disk');
    } else {
      await rediff();
    }
    for (final s in sides) {
      s.updateDirty();
    }
    _notify();
  }

  /// Takes [read] as the saved state of [side] and returns the edit that
  /// brings the text there.
  TextEdit? _reloadEdit(int side, _Read read) {
    final s = sides[side];
    s.loaded(read.decoded!, bytes: read.bytes, exists: read.exists);
    return TextEdit.between(s.text, read.decoded!.text);
  }

  /// Loads the newer version of [side] found on disk.
  void reloadFromDisk(int side, Uint8List bytes) {
    final edit =
        _reloadEdit(side, _Read(decoded: decodeText(bytes), bytes: bytes));
    if (edit != null) {
      applyEdits([(side, edit)], label: 'Reload ${sides[side].label}');
    }
    sides[side].updateDirty();
    _notify();
  }

  /// Keeps the unsaved edits and stops offering the disk version.
  void keepMine(int side) {
    final s = sides[side];
    s.diskBytes = s.pendingDiskBytes ?? s.diskBytes;
    s.pendingDiskBytes = null;
    _notify();
  }

  void _watch(int side) {
    _watchers[side]?.dispose();
    final path = sides[side].side.localPath;
    _watchers[side] =
        path == null ? null : FileWatcher(path, () => _checkDisk(side));
  }

  Future<void> _checkDisk(int side) async {
    final s = sides[side];
    Uint8List? bytes;
    try {
      bytes = await s.side.read();
    } catch (_) {
      return;
    }
    // Deleted: keep the text; saving recreates the file.
    if (_disposed || bytes == null) return;
    if (_sameBytes(bytes, s.diskBytes) ||
        _sameBytes(bytes, s.pendingDiskBytes)) {
      return; // our own save, or a change already offered
    }
    if (bytes.length > maxDiffBytes || looksBinary(bytes)) {
      s.diskBytes = bytes;
      onNotify?.call('${s.label} changed on disk and is no longer text');
      return;
    }
    if (!s.dirty) {
      reloadFromDisk(side, bytes);
      onNotify?.call('Reloaded ${s.label}: it changed on disk');
    } else {
      s.pendingDiskBytes = bytes;
      _notify();
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List? b) =>
      b != null && a.length == b.length && listEquals(a, b);

  // ---- search ----

  void setQuery(String query) {
    if (query == this.query) return;
    this.query = query;
    _search();
    _notify();
  }

  void setMatchCase(bool value) {
    if (value == matchCase) return;
    matchCase = value;
    _search(keepCurrent: true);
    _notify();
  }

  /// Moves to the next (or previous) hit, wrapping around.
  void stepMatch(int direction) {
    if (matches.isEmpty) return;
    currentMatch = currentMatch < 0
        ? (direction > 0 ? 0 : matches.length - 1)
        : (currentMatch + direction) % matches.length;
    _notify();
  }

  /// Makes the first hit at or after [row] the current one.
  void selectMatchFromRow(int row) {
    if (matches.isEmpty) return;
    final i = matches.indexWhere((m) => _rowOf(m) >= row);
    currentMatch = i < 0 ? 0 : i;
    _notify();
  }

  int _rowOf(FindMatch m) {
    final rows = rowOfLine[m.side];
    return m.line < rows.length ? rows[m.line] : 1 << 30;
  }

  void _search({bool keepCurrent = false}) {
    final previous = currentFindMatch;
    final found = <FindMatch>[];
    if (query.isNotEmpty) {
      final pattern = RegExp(RegExp.escape(query), caseSensitive: matchCase);
      for (var side = 0; side < 2; side++) {
        final text = sides[side].text;
        var line = 0, lineStart = 0, scanned = 0;
        for (final m in pattern.allMatches(text)) {
          // Count the line breaks since the last hit.
          for (var i = scanned; i < m.start; i++) {
            if (text.codeUnitAt(i) == 0x0A) {
              line++;
              lineStart = i + 1;
            }
          }
          scanned = m.start;
          if (m.end > m.start) {
            found.add(FindMatch(
                side, line, m.start - lineStart, m.end - lineStart, m.start));
          }
          if (found.length >= maxFindMatches) break;
        }
      }
      // In reading order: by row, left before right.
      found.sort((a, b) {
        final byRow = _rowOf(a).compareTo(_rowOf(b));
        if (byRow != 0) return byRow;
        final bySide = a.side.compareTo(b.side);
        return bySide != 0 ? bySide : a.offset.compareTo(b.offset);
      });
    }
    matches = found;
    matchesByLine = [{}, {}];
    for (final m in found) {
      (matchesByLine[m.side][m.line] ??= []).add(m);
    }
    if (found.isEmpty) {
      currentMatch = -1;
    } else if (keepCurrent && previous != null) {
      final i = found.indexWhere(
          (m) => m.side == previous.side && m.offset >= previous.offset);
      currentMatch = i < 0 ? 0 : i;
    } else {
      currentMatch = 0;
    }
  }

  // ---- lines ----

  final _lineStarts = <(String, Int32List)?>[null, null];

  /// Where each line of [side] starts in its text, plus the text length.
  Int32List lineStarts(int side) {
    final text = sides[side].text;
    final cached = _lineStarts[side];
    if (cached != null && identical(cached.$1, text)) return cached.$2;
    final starts = <int>[0];
    for (var i = text.indexOf('\n'); i >= 0; i = text.indexOf('\n', i + 1)) {
      starts.add(i + 1);
    }
    // A final newline does not start another line.
    if (text.isNotEmpty && text.endsWith('\n')) starts.removeLast();
    final out = Int32List(starts.length + 1)
      ..setAll(0, starts)
      ..[starts.length] = text.length;
    _lineStarts[side] = (text, out);
    return out;
  }

  /// Number of lines on [side].
  int lineCount(int side) =>
      sides[side].text.isEmpty ? 0 : lineStarts(side).length - 1;

  /// The (zero-based) line containing text [offset] on [side]. The end of
  /// a text that ends with a newline is on the empty line after it.
  int lineAt(int side, int offset) {
    final text = sides[side].text;
    final starts = lineStarts(side);
    if (offset >= text.length && text.endsWith('\n')) {
      return starts.length - 1;
    }
    var lo = 0, hi = starts.length - 2;
    if (hi < 0) return 0;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    for (final w in _watchers) {
      w?.dispose();
    }
    for (final s in sides) {
      s.dispose();
    }
    super.dispose();
  }
}

class _Read {
  const _Read({
    this.decoded,
    this.bytes,
    this.exists = true,
    this.binary = false,
    this.tooLarge = false,
  });

  final DecodedText? decoded;
  final Uint8List? bytes;
  final bool exists;
  final bool binary;
  final bool tooLarge;
}

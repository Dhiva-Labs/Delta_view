/// Where each merge chunk sits in the merge view's list: how many rows it
/// takes, where it starts in pixels, and the line number each pane starts
/// it at. Rebuilt after every edit in O(chunks); looking up a row is a
/// binary search, so even huge files scroll without per-line bookkeeping.
library;

import 'dart:math' as math;

import '../../merge/merge_document.dart';

class MergeLayout {
  MergeLayout(
    this.document, {
    required this.rowExtent,
    required this.showBase,
    this.editing,
    this.editorLines = 0,
  }) {
    final n = document.chunks.length;
    _itemStart = List.filled(n + 1, 0);
    _offset = List.filled(n + 1, 0);
    _rows = List.filled(n, 0);
    _baseLine = List.filled(n, 0);
    _leftLine = List.filled(n, 0);
    _mergedLine = List.filled(n, 0);
    _rightLine = List.filled(n, 0);

    var item = 0, merged = 0;
    var offset = 0.0;
    for (var i = 0; i < n; i++) {
      final chunk = document.chunks[i];
      final state = document.state(i);
      _itemStart[i] = item;
      _offset[i] = offset;
      _baseLine[i] = chunk.baseStart;
      _leftLine[i] = chunk.leftStart;
      _rightLine[i] = chunk.rightStart;
      _mergedLine[i] = merged;
      // An unresolved conflict shows the base lines as a placeholder; they
      // are not lines of the result, so they get no numbers.
      if (state.isResolved) merged += state.lines.length;

      var rows = math.max(
        chunk.left.length,
        math.max(chunk.right.length, state.lines.length),
      );
      if (showBase) rows = math.max(rows, chunk.base.length);
      // A change whose every visible side is empty (both sides deleted the
      // same lines) still needs a row to show and act on.
      if (chunk.isChange || state.resolution == Resolution.edited) {
        rows = math.max(rows, 1);
      }
      if (i == editing) {
        // The editor replaces the merged lines; the sides stay as they are.
        rows = math.max(chunk.left.length, chunk.right.length);
        if (showBase) rows = math.max(rows, chunk.base.length);
        rows = math.max(rows, math.max(editorLines, 1));
        _rows[i] = rows;
        item += 1;
        offset += rows * rowExtent + editorChrome;
      } else {
        _rows[i] = rows;
        item += rows;
        offset += rows * rowExtent;
      }
    }
    _itemStart[n] = item;
    _offset[n] = offset;
    itemCount = item;
    totalExtent = offset;
  }

  /// Extra height around an inline editor for its border and hint bar.
  static const editorChrome = 30.0;

  final MergeDocument document;
  final double rowExtent;
  final bool showBase;

  /// The chunk being edited by hand: it is one list item, the editor.
  final int? editing;
  final int editorLines;

  late final List<int> _itemStart;
  late final List<double> _offset;
  late final List<int> _rows;
  late final List<int> _baseLine, _leftLine, _mergedLine, _rightLine;
  late final int itemCount;
  late final double totalExtent;

  int rowsOf(int chunk) => _rows[chunk];
  int firstItemOf(int chunk) => _itemStart[chunk];
  double offsetOf(int chunk) => _offset[chunk];
  double heightOf(int chunk) => _offset[chunk + 1] - _offset[chunk];

  /// Zero-based line index in each pane where [chunk] begins.
  int baseLineOf(int chunk) => _baseLine[chunk];
  int leftLineOf(int chunk) => _leftLine[chunk];
  int mergedLineOf(int chunk) => _mergedLine[chunk];
  int rightLineOf(int chunk) => _rightLine[chunk];

  /// The chunk that list item [item] belongs to.
  int chunkAt(int item) {
    var lo = 0, hi = document.chunks.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_itemStart[mid] <= item) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The chunk drawn at [offset] pixels from the top.
  int chunkAtOffset(double offset) {
    var lo = 0, hi = document.chunks.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_offset[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  double? extentOf(int item) {
    if (item < 0 || item >= itemCount) return null;
    final chunk = chunkAt(item);
    return chunk == editing ? heightOf(chunk) : rowExtent;
  }
}

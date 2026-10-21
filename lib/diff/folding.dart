/// Hiding long runs of unchanged rows so the changes sit close together,
/// with a few rows of context kept around each one.
library;

import 'dart:typed_data';

import 'line_diff.dart';

/// Rows `[start, end)` hidden behind one "⋯ N unchanged lines" marker.
class FoldRun {
  const FoldRun(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is FoldRun && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'FoldRun($start, $end)';
}

/// The runs of unchanged rows to hide, keeping [context] rows next to
/// every change. Runs that would hide fewer than [minHidden] rows stay
/// open: a marker in place of one or two lines saves nothing.
List<FoldRun> foldRuns(List<DiffRow> rows,
    {required int context, int minHidden = 3}) {
  final out = <FoldRun>[];
  var i = 0;
  while (i < rows.length) {
    if (rows[i].kind != DiffRowKind.same) {
      i++;
      continue;
    }
    final start = i;
    while (i < rows.length && rows[i].kind == DiffRowKind.same) {
      i++;
    }
    final hideStart = start == 0 ? 0 : start + context;
    final hideEnd = i == rows.length ? i : i - context;
    if (hideEnd - hideStart >= minHidden) {
      out.add(FoldRun(hideStart, hideEnd));
    }
  }
  return out;
}

/// What the view lists top to bottom: diff rows, with each folded run
/// replaced by a single marker item.
class FoldedLayout {
  FoldedLayout._(this.items, this.folds, this.rowCount);

  /// Every row is its own item.
  factory FoldedLayout.unfolded(int rowCount) => FoldedLayout._(
      Int32List.fromList(List.generate(rowCount, (i) => i)),
      const [],
      rowCount);

  /// [folds] must be sorted and not overlap.
  factory FoldedLayout(int rowCount, List<FoldRun> folds) {
    if (folds.isEmpty) return FoldedLayout.unfolded(rowCount);
    final hidden = folds.fold(0, (sum, f) => sum + f.length);
    final items = Int32List(rowCount - hidden + folds.length);
    var n = 0, row = 0;
    for (var f = 0; f < folds.length; f++) {
      while (row < folds[f].start) {
        items[n++] = row++;
      }
      items[n++] = -(f + 1);
      row = folds[f].end;
    }
    while (row < rowCount) {
      items[n++] = row++;
    }
    return FoldedLayout._(items, folds, rowCount);
  }

  /// A row index, or `-(k + 1)` for the marker of `folds[k]`.
  final Int32List items;
  final List<FoldRun> folds;
  final int rowCount;

  int get length => items.length;

  /// The row item [index] shows, or null for a fold marker.
  int? rowAt(int index) {
    final v = items[index];
    return v >= 0 ? v : null;
  }

  /// The fold item [index] shows, or null for a row.
  FoldRun? foldAt(int index) {
    final v = items[index];
    return v < 0 ? folds[-v - 1] : null;
  }

  /// The fold that hides [row], or null when the row is shown.
  FoldRun? foldHiding(int row) {
    for (final f in folds) {
      if (row < f.start) return null;
      if (row < f.end) return f;
    }
    return null;
  }

  /// The item that shows [row]: the row's own item, or the marker of the
  /// fold hiding it.
  int itemOfRow(int row) {
    // Items are sorted by the first row they cover; binary search on that.
    var lo = 0, hi = items.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_firstRow(mid) <= row) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  int _firstRow(int item) {
    final v = items[item];
    return v >= 0 ? v : folds[-v - 1].start;
  }
}

/// What the toolbar and keyboard need from whichever pane layout is on
/// screen (rows in view mode, editors in edit mode) to move between
/// changes relative to where the user is scrolled.
library;

import 'package:flutter/foundation.dart';

abstract interface class DiffViewport {
  /// Notifies when the panes scroll.
  Listenable get scrollListenable;

  /// The top of the visible region, in content coordinates.
  double get scrollTop;

  double get viewHeight;

  /// Where change block [index] starts, in content coordinates.
  double blockTop(int index);

  /// Scrolls so block [index] sits just below the top.
  void revealBlock(int index);
}

/// How far below the top a revealed change sits: enough to show what
/// leads into it.
double revealMargin(double viewHeight) =>
    viewHeight <= 0 ? 0 : (viewHeight / 4).clamp(0.0, 120.0);

/// The first block whose top is past [y] (block tops only grow, so this is
/// a binary search: in edit mode with wrapping each lookup asks the text
/// engine).
int _firstBlockBelow(DiffViewport viewport, int blockCount, double y) {
  var lo = 0, hi = blockCount;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (viewport.blockTop(mid) > y) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return lo;
}

/// The block next to the reading position in [direction] (+1 or -1), or
/// null when there is none.
///
/// The reading position is the [revealMargin] line under the top of the
/// view. [current] (the block last jumped to) counts while it is still on
/// screen, so repeated presses walk block by block even near the end of
/// the file, where a block can no longer scroll up to the reading line.
int? neighbourBlock(
    DiffViewport viewport, int blockCount, int current, int direction) {
  if (blockCount == 0) return null;
  final top = viewport.scrollTop, height = viewport.viewHeight;
  if (current >= 0 && current < blockCount) {
    final y = viewport.blockTop(current);
    if (y >= top - 1 && y <= top + height) {
      final next = current + direction;
      return next >= 0 && next < blockCount ? next : null;
    }
  }
  final reading = top + revealMargin(height);
  if (direction > 0) {
    // At the very top every visible block is still ahead.
    final i =
        _firstBlockBelow(viewport, blockCount, top <= 0 ? -1 : reading + 1);
    return i < blockCount ? i : null;
  }
  // The last block that starts above the reading line.
  final i = _firstBlockBelow(viewport, blockCount, reading - 1.001) - 1;
  return i >= 0 ? i : null;
}

/// The block the reading position is in or just past, for "change N of
/// M": [current] while it is on screen, else the last block that starts
/// above the reading line. -1 at the top of the file or before the first
/// block.
int blockAtReadingLine(DiffViewport viewport, int blockCount, int current) {
  final top = viewport.scrollTop, height = viewport.viewHeight;
  if (current >= 0 && current < blockCount) {
    final y = viewport.blockTop(current);
    if (y >= top - 1 && y <= top + height) return current;
  }
  if (top <= 0) return -1;
  return _firstBlockBelow(viewport, blockCount, top + revealMargin(height)) - 1;
}

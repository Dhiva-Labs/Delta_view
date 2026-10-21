/// A lazily built list whose item heights are known up front, given as a
/// table of running offsets.
///
/// [SliverVariedExtentList] also takes per-item heights, but it finds the
/// item at a scroll offset by summing every height before it, on every
/// layout. With 100 000 rows that is millions of calls per frame. Here the
/// offsets are summed once and looked up by binary search, so scrolling,
/// jumping and the scroll extent are exact and cheap however long the file.
library;

import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class SliverOffsetList extends SliverMultiBoxAdaptorWidget {
  const SliverOffsetList({
    super.key,
    required super.delegate,
    required this.offsets,
  });

  /// `offsets[i]` is where item `i` starts; the last entry is the total
  /// height. Must have one more entry than the delegate has children.
  final Float64List offsets;

  @override
  RenderSliverOffsetList createRenderObject(BuildContext context) =>
      RenderSliverOffsetList(
        childManager: context as SliverMultiBoxAdaptorElement,
        offsets: offsets,
      );

  @override
  void updateRenderObject(
          BuildContext context, RenderSliverOffsetList renderObject) =>
      renderObject.offsets = offsets;
}

class RenderSliverOffsetList extends RenderSliverFixedExtentBoxAdaptor {
  RenderSliverOffsetList({
    required super.childManager,
    required Float64List offsets,
  }) : _offsets = offsets; // ignore: prefer_initializing_formals

  Float64List get offsets => _offsets;
  Float64List _offsets;
  set offsets(Float64List value) {
    if (identical(value, _offsets)) return;
    _offsets = value;
    markNeedsLayout();
  }

  int get _count => _offsets.length - 1;

  @override
  double? get itemExtent => null;

  @override
  ItemExtentBuilder? get itemExtentBuilder => _extentOf;

  double? _extentOf(int index, SliverLayoutDimensions dimensions) =>
      index < 0 || index >= _count
          ? null
          : _offsets[index + 1] - _offsets[index];

  int _indexAt(double y) => indexAtOffset(_offsets, y);

  @override
  double indexToLayoutOffset(double itemExtent, int index) =>
      _offsets[index.clamp(0, _count)];

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _indexAt(scrollOffset);

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _indexAt(scrollOffset);

  @override
  double computeMaxScrollOffset(
          SliverConstraints constraints, double itemExtent) =>
      _offsets[_count];

  @override
  double estimateMaxScrollOffset(
    SliverConstraints constraints, {
    int? firstIndex,
    int? lastIndex,
    double? leadingScrollOffset,
    double? trailingScrollOffset,
  }) =>
      _offsets[_count];
}

/// Running offsets for items of the given [heights].
Float64List offsetsOf(int count, double Function(int index) heights) {
  final out = Float64List(count + 1);
  var y = 0.0;
  for (var i = 0; i < count; i++) {
    out[i] = y;
    y += heights(i);
  }
  out[count] = y;
  return out;
}

/// The last item starting at or before [y] in [offsets] (so the one that
/// contains it), clamped to the list.
int indexAtOffset(Float64List offsets, double y) {
  final count = offsets.length - 1;
  if (count <= 0) return 0;
  var lo = 0, hi = count - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (offsets[mid] <= y) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

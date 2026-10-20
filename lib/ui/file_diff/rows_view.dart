/// View mode: both files side by side in aligned rows, with long runs of
/// unchanged lines folded away, a connecting gutter between the panes and
/// a minimap. Rows are virtualised and their heights computed up front
/// (see line_layout.dart), so wrapped and folded files still scroll and
/// jump exactly.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../diff/folding.dart';
import '../../diff/line_diff.dart';
import '../../theme.dart';
import 'connector_gutter.dart';
import 'diff_session.dart';
import 'extent_list.dart';
import 'hscroll.dart';
import 'line_layout.dart';
import 'minimap.dart';
import 'syntax.dart';
import 'viewport.dart';

/// Space between the line-number gutter and the text.
const _textInset = 6.0;

class DiffRowsView extends StatefulWidget {
  const DiffRowsView({
    super.key,
    required this.session,
    required this.scroll,
    required this.metrics,
    required this.fold,
    required this.foldContext,
    required this.currentBlock,
    required this.onCopy,
    required this.onDelete,
    required this.onRowTap,
    this.highlightRow,
    this.onLayout,
  });

  final DiffSession session;

  /// Vertical scrolling; owned by the parent so it can follow the scroll
  /// position (to enable previous / next) from the first frame.
  final ScrollController scroll;
  final EditorMetrics metrics;
  final bool fold;
  final int foldContext;
  final int currentBlock;
  final void Function(int index, {required bool toRight}) onCopy;
  final void Function(int index, {required bool left}) onDelete;

  /// A row was clicked (to make its change the current one).
  final ValueChanged<int> onRowTap;

  /// A row to point out briefly (after "Go to line").
  final int? highlightRow;

  /// Called after a frame in which row positions changed, for widgets
  /// outside that depend on them.
  final VoidCallback? onLayout;

  @override
  State<DiffRowsView> createState() => DiffRowsViewState();
}

class DiffRowsViewState extends State<DiffRowsView> implements DiffViewport {
  ScrollController get scroll => widget.scroll;

  /// Ticks when the scroll metrics change without a scroll, for example
  /// when folding shrinks the content and the position is clamped (which
  /// does not notify the controller's listeners).
  final _metricsTick = ValueNotifier<int>(0);
  late final _scrollOrMetrics = Listenable.merge([widget.scroll, _metricsTick]);
  final _hOffset = ValueNotifier<double>(0);
  static final _noShift = ValueNotifier<double>(0);

  /// Folds the user opened, by the left line number their run starts at
  /// (which survives re-diffs better than a row index).
  final _expanded = <int>{};
  int _expandedVersion = 0;

  void _expand(FoldRun fold) {
    if (_expanded.add(_foldKey(fold))) setState(() => _expandedVersion++);
  }

  DiffSession get _session => widget.session;
  List<DiffRow> get _rows => _session.result?.rows ?? const [];

  // ---- cached layout, rebuilt when its inputs change ----
  FoldedLayout _layout = FoldedLayout.unfolded(0);
  Object? _layoutKey;
  Int32List _leftCols = Int32List(0), _rightCols = Int32List(0);
  Object? _colsKey;
  Float64List _offsets = Float64List(1);
  Object? _offsetsKey;
  int _maxCols = 0;

  /// Visual line counts of wrapped rows, for [_wrapLinesKey].
  final _wrapLines = <int, int>{};
  Object? _wrapLinesKey;
  double _viewHeight = 0;
  double _textWidth = 0;

  @override
  void dispose() {
    _metricsTick.dispose();
    _hOffset.dispose();
    super.dispose();
  }

  // ---- DiffViewport ----

  @override
  Listenable get scrollListenable => scroll;

  @override
  double get scrollTop => scroll.hasClients ? scroll.offset : 0;

  @override
  double get viewHeight => _viewHeight;

  @override
  double blockTop(int index) =>
      _offsets[_layout.itemOfRow(_session.blocks[index].firstRow)];

  @override
  void revealBlock(int index) =>
      revealRow(_session.blocks[index].firstRow, animate: true);

  /// Scrolls [row] to just below the top ([margin] below it, by default
  /// [revealMargin]) or to the middle, opening the fold that hides it.
  void revealRow(
    int row, {
    bool animate = true,
    bool center = false,
    double? margin,
  }) {
    final fold = _layout.foldHiding(row);
    if (fold != null) {
      _expand(fold);
      // The new layout exists after the rebuild.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => revealRow(row, animate: false, center: center, margin: margin),
      );
      return;
    }
    if (!scroll.hasClients) return;
    final item = _layout.itemOfRow(row);
    final y = _offsets[item];
    margin ??= center
        ? (_viewHeight - (_offsets[item + 1] - y)) / 2
        : revealMargin(_viewHeight);
    final target = (y - margin).clamp(0.0, scroll.position.maxScrollExtent);
    if (animate) {
      scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      scroll.jumpTo(target);
    }
  }

  /// Brings characters `[start, end)` of [line] into horizontal view (for
  /// search hits in long lines).
  void revealColumns(String line, int start, int end) {
    if (widget.metrics.wrap) return;
    final cw = widget.metrics.charWidth;
    final x0 =
        displayColumns(line.substring(0, start), widget.metrics.tabWidth) * cw;
    final x1 =
        displayColumns(line.substring(0, end), widget.metrics.tabWidth) * cw;
    final view = _textWidth - _textInset;
    if (x0 < _hOffset.value || x1 > _hOffset.value + view) {
      _hOffset.value = math.max(0, x0 - view / 3);
    }
  }

  /// The row at the top of the view.
  int get topRow {
    if (_layout.length == 0) return 0;
    final item = indexAtOffset(_offsets, scrollTop);
    return _layout.rowAt(item) ?? _layout.foldAt(item)!.start;
  }

  void scrollBy(double dy) {
    if (!scroll.hasClients) return;
    scroll.jumpTo(
      (scroll.offset + dy).clamp(0.0, scroll.position.maxScrollExtent),
    );
  }

  void scrollHorizontallyBy(double dx) {
    _hOffset.value = (_hOffset.value + dx).clamp(0.0, _maxH).toDouble();
  }

  double _maxH = 0;

  int _foldKey(FoldRun fold) =>
      _rows[fold.start].leftNumber ?? -(_rows[fold.start].rightNumber ?? 0);

  // ---- layout ----

  void _ensureColumns() {
    final key = (_session.version, widget.metrics.tabWidth);
    if (key == _colsKey) return;
    _colsKey = key;
    final rows = _rows, tab = widget.metrics.tabWidth;
    _leftCols = Int32List(rows.length);
    _rightCols = Int32List(rows.length);
    var maxCols = 0;
    for (var i = 0; i < rows.length; i++) {
      final l = rows[i].leftText, r = rows[i].rightText;
      if (l != null) {
        _leftCols[i] = math.min(displayColumns(l, tab), maxDisplayColumns);
      }
      if (r != null) {
        _rightCols[i] = math.min(displayColumns(r, tab), maxDisplayColumns);
      }
      maxCols = math.max(maxCols, math.max(_leftCols[i], _rightCols[i]));
    }
    _maxCols = maxCols;
  }

  void _ensureLayout() {
    final key = (
      _session.version,
      widget.fold,
      widget.foldContext,
      _expandedVersion,
    );
    if (key == _layoutKey) return;
    _layoutKey = key;
    final rows = _rows;
    _layout = widget.fold
        ? FoldedLayout(rows.length, [
            for (final f in foldRuns(rows, context: widget.foldContext))
              if (!_expanded.contains(_foldKey(f))) f,
          ])
        : FoldedLayout.unfolded(rows.length);
  }

  int? _wrapColumns(double textWidth) => widget.metrics.wrap
      ? math.max(
          8,
          ((textWidth - _textInset - 4) / widget.metrics.charWidth).floor(),
        )
      : null;

  double get _foldHeight => widget.metrics.lineHeight + 8;

  void _ensureOffsets(double textWidth) {
    final m = widget.metrics;
    final wrap = _wrapColumns(textWidth);
    final key = (_layoutKey, _colsKey, wrap, m.lineHeight, m.showWhitespace);
    if (key == _offsetsKey) return;
    _offsetsKey = key;
    final wrapKey = (_colsKey, wrap, m.showWhitespace);
    if (wrapKey != _wrapLinesKey) {
      _wrapLinesKey = wrapKey;
      _wrapLines.clear();
    }
    final rows = _rows;
    _offsets = offsetsOf(_layout.length, (item) {
      final row = _layout.rowAt(item);
      if (row == null) return _foldHeight;
      if (wrap == null) return m.lineHeight;
      return _visualLines(rows[row], row, wrap) * m.lineHeight;
    });
  }

  int _visualLines(DiffRow row, int index, int wrap) {
    if (_leftCols[index] <= wrap && _rightCols[index] <= wrap) return 1;
    return _wrapLines.putIfAbsent(index, () {
      int lines(String? text, int cols) => text == null || cols <= wrap
          ? 1
          : layoutLine(
              _stripCr(text),
              tabWidth: widget.metrics.tabWidth,
              showWhitespace: widget.metrics.showWhitespace,
              wrapColumns: wrap,
            ).visualLines;
      return math.max(
        lines(row.leftText, _leftCols[index]),
        lines(row.rightText, _rightCols[index]),
      );
    });
  }

  double _numberWidth() {
    final lines = math.max(_session.lineCount(0), _session.lineCount(1));
    final digits = math.max(3, '$lines'.length);
    return (digits + 2) * widget.metrics.charWidth * 0.86 + 10;
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows.isEmpty) {
      final pasted = _session.sides.every((s) => s.isMemory);
      return Center(
        child: Text(
          pasted
              ? 'Both sides are empty: paste or type text in Edit mode'
              : 'Both files are empty',
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - Minimap.width;
        final paneWidth = (width - ConnectorGutter.width) / 2;
        final numberWidth = _numberWidth();
        final textWidth = paneWidth - numberWidth;
        _viewHeight = constraints.maxHeight - HorizontalScrollbar.height;
        _textWidth = textWidth;
        _ensureColumns();
        _ensureLayout();
        _ensureOffsets(textWidth);

        final m = widget.metrics;
        final contentWidth =
            m.wrap ? 0.0 : _maxCols * m.charWidth + _textInset + 24;
        _maxH = math.max(0, contentWidth - textWidth);
        if (_hOffset.value > _maxH) _hOffset.value = _maxH;

        final style = _CellStyle.of(context, m, numberWidth);
        final list = Listener(
          onPointerSignal: (event) {
            if (m.wrap) return;
            final dx = horizontalScrollDelta(event);
            if (dx == 0) return;
            GestureBinding.instance.pointerSignalResolver.register(
              event,
              (_) => scrollHorizontallyBy(dx),
            );
          },
          onPointerPanZoomUpdate: (event) {
            if (!m.wrap) scrollHorizontallyBy(-event.panDelta.dx);
          },
          child: NotificationListener<ScrollMetricsNotification>(
            // Sent after layout whenever extents or the position change.
            onNotification: (_) {
              _metricsTick.value++;
              widget.onLayout?.call();
              return false;
            },
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: CustomScrollView(
                controller: scroll,
                slivers: [
                  SliverOffsetList(
                    offsets: _offsets,
                    delegate: SliverChildBuilderDelegate(
                      (context, item) =>
                          _buildItem(context, item, style, paneWidth),
                      childCount: _layout.length,
                      addAutomaticKeepAlives: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: width,
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(child: list),
                        Positioned(
                          left: paneWidth,
                          width: ConnectorGutter.width,
                          top: 0,
                          bottom: 0,
                          child: _gutter(),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      SizedBox(width: numberWidth),
                      SizedBox(
                        width: textWidth,
                        child: m.wrap
                            ? const SizedBox(height: HorizontalScrollbar.height)
                            : HorizontalScrollbar(
                                offset: _hOffset,
                                contentWidth: contentWidth,
                              ),
                      ),
                      const SizedBox(width: ConnectorGutter.width),
                      SizedBox(width: numberWidth),
                      SizedBox(
                        width: textWidth,
                        child: m.wrap
                            ? const SizedBox(height: HorizontalScrollbar.height)
                            : HorizontalScrollbar(
                                offset: _hOffset,
                                contentWidth: contentWidth,
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            AnimatedBuilder(
              animation: _scrollOrMetrics,
              builder: (context, _) => Minimap(
                // A file shorter than the view is not stretched to fill it.
                total: math.max(_offsets.last, _viewHeight),
                marks: _minimapMarks(),
                viewStart: scrollTop,
                viewExtent: _viewHeight,
                onScrollTo: (y) {
                  if (!scroll.hasClients) return;
                  scroll.jumpTo(y.clamp(0.0, scroll.position.maxScrollExtent));
                },
              ),
            ),
          ],
        );
      },
    );
  }

  List<MinimapMark>? _marks;
  Object? _marksKey;

  List<MinimapMark> _minimapMarks() {
    final key = (_offsetsKey, _session.version);
    if (key == _marksKey && _marks != null) return _marks!;
    _marksKey = key;
    return _marks = [
      for (final b in _session.blocks)
        (
          start: _offsets[_layout.itemOfRow(b.firstRow)],
          end: _offsets[_layout.itemOfRow(b.endRow - 1) + 1],
          kind: b.kind,
        ),
    ];
  }

  Widget _gutter() {
    return AnimatedBuilder(
      animation: _scrollOrMetrics,
      builder: (context, _) {
        final blocks = _session.blocks;
        final top = scrollTop, bottom = top + _viewHeight;
        final bands = <BandGeometry>[];
        // Blocks are in order: find the first one that reaches the view.
        var lo = 0, hi = blocks.length;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          final end = _offsets[_layout.itemOfRow(blocks[mid].endRow - 1) + 1];
          if (end < top) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        for (var i = lo; i < blocks.length; i++) {
          final b = blocks[i];
          final y0 = _offsets[_layout.itemOfRow(b.firstRow)];
          if (y0 > bottom) break;
          final y1 = _offsets[_layout.itemOfRow(b.endRow - 1) + 1];
          bands.add(
            BandGeometry(
              index: i,
              block: b,
              leftTop: y0 - top,
              leftBottom: y1 - top,
              rightTop: y0 - top,
              rightBottom: y1 - top,
            ),
          );
        }
        return ConnectorGutter(
          bands: bands,
          currentBlock: widget.currentBlock,
          onCopy: widget.onCopy,
          onDelete: widget.onDelete,
        );
      },
    );
  }

  Widget _buildItem(
    BuildContext context,
    int item,
    _CellStyle style,
    double paneWidth,
  ) {
    final fold = _layout.foldAt(item);
    if (fold != null) {
      return _FoldRow(
        hidden: fold.length,
        style: style,
        paneWidth: paneWidth,
        onTap: () => _expand(fold),
      );
    }
    final index = _layout.rowAt(item)!;
    final row = _rows[index];
    final wrap = _wrapColumns(_textWidth);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onRowTap(index),
      child: Container(
        foregroundDecoration: index == widget.highlightRow
            ? BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.12),
                border: Border.symmetric(
                  horizontal: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              )
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: paneWidth,
              child: _cell(context, row, left: true, style: style, wrap: wrap),
            ),
            const SizedBox(width: ConnectorGutter.width),
            SizedBox(
              width: paneWidth,
              child: _cell(context, row, left: false, style: style, wrap: wrap),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    DiffRow row, {
    required bool left,
    required _CellStyle style,
    required int? wrap,
  }) {
    final number = left ? row.leftNumber : row.rightNumber;
    final text = left ? row.leftText : row.rightText;
    if (number == null || text == null) {
      return ColoredBox(color: style.filler);
    }
    final m = widget.metrics;
    final palette = style.palette;
    final kind = row.kind;
    final background = switch (kind) {
      DiffRowKind.same => null,
      DiffRowKind.modified => palette.modifiedBg,
      DiffRowKind.removed => palette.removedBg,
      DiffRowKind.added => palette.addedBg,
    };
    // Shape as well as colour tells what happened to the line.
    final (marker, markerColor) = switch (kind) {
      DiffRowKind.same => ('', null),
      DiffRowKind.modified => ('~', palette.modified),
      DiffRowKind.removed => ('−', palette.removed),
      DiffRowKind.added => ('+', palette.added),
    };

    final source = _stripCr(text);
    final display = layoutLine(
      source,
      tabWidth: m.tabWidth,
      showWhitespace: m.showWhitespace,
      wrapColumns: wrap,
    );
    final highlighter = _session.highlighter;
    final tokens =
        m.syntax && highlighter != null && _rows.length <= maxHighlightedLines
            ? highlighter.tokens(source)
            : null;
    final side = left ? 0 : 1;
    final current = _session.currentFindMatch;
    final matches = [
      for (final f
          in _session.matchesByLine[side][number - 1] ?? const <FindMatch>[])
        (start: f.start, end: f.end, current: identical(f, current)),
    ];
    final runs = styleRuns(
      source.length,
      tokens: tokens,
      emphasis: left ? row.leftSpans : row.rightSpans,
      emphasisColor: left ? palette.removedEmphasis : palette.addedEmphasis,
      matches: matches,
      colors: style.colors,
    );
    var span = displaySpan(display, runs, style.colors);
    // When line endings count and they differ, say which is which.
    final other = left ? row.rightText : row.leftText;
    if (kind == DiffRowKind.modified &&
        other != null &&
        text.endsWith('\r') != other.endsWith('\r')) {
      span = TextSpan(
        children: [
          span,
          TextSpan(
            text: text.endsWith('\r') ? '  CRLF' : '  LF',
            style: TextStyle(
              color: style.colors.marker,
              backgroundColor:
                  left ? palette.removedEmphasis : palette.addedEmphasis,
              fontSize: m.fontSize * 0.8,
            ),
          ),
        ],
      );
    }

    return ColoredBox(
      color: background ?? Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: style.numberWidth,
            height: m.lineHeight,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$number',
                    textAlign: TextAlign.right,
                    style: style.number,
                    strutStyle: m.strut,
                  ),
                ),
                SizedBox(
                  width: m.charWidth * 1.6,
                  child: Text(
                    marker,
                    textAlign: TextAlign.center,
                    strutStyle: m.strut,
                    style: style.number.copyWith(
                      color: markerColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: HorizontalShift(
              offset: wrap == null ? _hOffset : _noShift,
              child: Padding(
                padding: const EdgeInsets.only(left: _textInset),
                child: RichText(
                  text: TextSpan(style: style.text, children: [span]),
                  softWrap: false,
                  strutStyle: m.strut,
                  textScaler: TextScaler.noScaling,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _stripCr(String s) =>
    s.endsWith('\r') ? s.substring(0, s.length - 1) : s;

/// Everything a row needs from the theme, looked up once per build.
class _CellStyle {
  _CellStyle._({
    required this.palette,
    required this.colors,
    required this.text,
    required this.number,
    required this.filler,
    required this.numberWidth,
    required this.foldText,
    required this.foldBackground,
  });

  factory _CellStyle.of(
    BuildContext context,
    EditorMetrics m,
    double numberWidth,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return _CellStyle._(
      palette: DiffPalette.of(context),
      colors: LineColors.of(context),
      text: m.style.copyWith(color: scheme.onSurface),
      number: m.style.copyWith(
        fontSize: m.fontSize * 0.86,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
      filler: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
      numberWidth: numberWidth,
      foldText: TextStyle(
        fontSize: 12,
        color: scheme.onSurfaceVariant,
        letterSpacing: 0.2,
      ),
      foldBackground: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
    );
  }

  final DiffPalette palette;
  final LineColors colors;
  final TextStyle text;
  final TextStyle number;
  final Color filler;
  final double numberWidth;
  final TextStyle foldText;
  final Color foldBackground;
}

class _FoldRow extends StatelessWidget {
  const _FoldRow({
    required this.hidden,
    required this.style,
    required this.paneWidth,
    required this.onTap,
  });

  final int hidden;
  final _CellStyle style;
  final double paneWidth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = '$hidden unchanged line${hidden == 1 ? '' : 's'}';
    Widget half() => Padding(
          padding: EdgeInsets.only(left: style.numberWidth - 22),
          child: Row(
            children: [
              Icon(Icons.unfold_more, size: 16, color: style.foldText.color),
              const SizedBox(width: 6),
              Text(label, style: style.foldText),
            ],
          ),
        );
    return Tooltip(
      message: 'Show these lines',
      waitDuration: const Duration(milliseconds: 700),
      child: Material(
        color: style.foldBackground,
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              SizedBox(width: paneWidth, child: half()),
              const SizedBox(width: ConnectorGutter.width),
              SizedBox(width: paneWidth, child: half()),
            ],
          ),
        ),
      ),
    );
  }
}

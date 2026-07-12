import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../diff/line_diff.dart';
import '../theme.dart';

const _maxDiffBytes = 8 * 1024 * 1024;
const _rowExtent = 22.0;

class FileDiffView extends StatefulWidget {
  const FileDiffView({
    super.key,
    required this.leftPath,
    required this.rightPath,
    this.title,
    this.onBack,
  });

  final String leftPath;
  final String rightPath;
  final String? title;
  final VoidCallback? onBack;

  @override
  State<FileDiffView> createState() => _FileDiffViewState();
}

class _FileDiffViewState extends State<FileDiffView> {
  DiffResult? _result;
  String? _notice;
  String? _error;
  bool _loaded = false;
  bool _editing = false;
  int _currentBlock = -1;

  final _viewScroll = ScrollController();
  final _leftEditScroll = ScrollController();
  final _rightEditScroll = ScrollController();
  bool _syncingScroll = false;

  late final _DiffEditingController _leftController;
  late final _DiffEditingController _rightController;
  String _savedLeft = '';
  String _savedRight = '';
  bool _leftExists = true;
  bool _rightExists = true;
  Timer? _debounce;
  (String, String)? _lastDiffed;

  bool get _leftDirty => _leftController.text != _savedLeft;
  bool get _rightDirty => _rightController.text != _savedRight;

  @override
  void initState() {
    super.initState();
    _leftController = _DiffEditingController();
    _rightController = _DiffEditingController();
    _leftController.addListener(_scheduleRediff);
    _rightController.addListener(_scheduleRediff);
    _leftEditScroll.addListener(() => _syncScroll(_leftEditScroll,
        _rightEditScroll));
    _rightEditScroll.addListener(() => _syncScroll(_rightEditScroll,
        _leftEditScroll));
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _viewScroll.dispose();
    _leftEditScroll.dispose();
    _rightEditScroll.dispose();
    _leftController.dispose();
    _rightController.dispose();
    super.dispose();
  }

  void _syncScroll(ScrollController from, ScrollController to) {
    if (_syncingScroll || !from.hasClients || !to.hasClients) return;
    _syncingScroll = true;
    final fromMax = from.position.maxScrollExtent;
    final fraction = fromMax == 0 ? 0.0 : from.offset / fromMax;
    to.jumpTo(fraction * to.position.maxScrollExtent);
    _syncingScroll = false;
  }

  Future<void> _load() async {
    try {
      final left = await _readSide(widget.leftPath);
      final right = await _readSide(widget.rightPath);

      if (left.binary || right.binary) {
        setState(() => _notice = 'Binary files — no text diff available.');
        return;
      }
      if (left.tooLarge || right.tooLarge) {
        setState(() =>
            _notice = 'File is larger than 8 MB — text diff is disabled.');
        return;
      }

      _leftExists = left.exists;
      _rightExists = right.exists;
      _savedLeft = left.text ?? '';
      _savedRight = right.text ?? '';
      _leftController.text = _savedLeft;
      _rightController.text = _savedRight;

      final result = await _diffInIsolate(_savedLeft, _savedRight);
      if (!mounted) return;
      setState(() {
        _result = result;
        _loaded = true;
        _applyLineKinds(result);
        _lastDiffed = (_savedLeft, _savedRight);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Static so the isolate closure captures only the two strings. A closure
  /// created inside a State method drags `this` (and with it the whole
  /// widget tree) into the isolate message, which is unsendable.
  static Future<DiffResult> _diffInIsolate(String left, String right) {
    return Isolate.run(() => buildSideBySide(left, right));
  }

  Future<_SideContent> _readSide(String path) async {
    final file = File(path);
    if (!file.existsSync()) return const _SideContent(exists: false);
    final length = await file.length();
    if (length > _maxDiffBytes) return const _SideContent(tooLarge: true);
    final bytes = await file.readAsBytes();
    final probe = math.min(bytes.length, 8192);
    for (var i = 0; i < probe; i++) {
      if (bytes[i] == 0) return const _SideContent(binary: true);
    }
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      text = latin1.decode(bytes);
    }
    return _SideContent(text: text);
  }

  void _scheduleRediff() {
    if (!_loaded) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _rediff);
    // Repaint save-button enabled state immediately.
    if (mounted) setState(() {});
  }

  Future<void> _rediff() async {
    final left = _leftController.text;
    final right = _rightController.text;
    if (_lastDiffed == (left, right)) return;
    _lastDiffed = (left, right);
    final result = (left.length + right.length) > 200 * 1024
        ? await _diffInIsolate(left, right)
        : buildSideBySide(left, right);
    if (!mounted) return;
    // Ignore stale results if the text changed while we were diffing.
    if (_leftController.text != left || _rightController.text != right) return;
    setState(() {
      _result = result;
      _currentBlock = -1;
      _applyLineKinds(result);
    });
  }

  /// Feeds per-line diff kinds into the edit controllers so the editors
  /// paint added / removed / modified line backgrounds live.
  void _applyLineKinds(DiffResult result) {
    final palette = DiffPalette.of(context);
    final leftKinds = <DiffRowKind?>[];
    final rightKinds = <DiffRowKind?>[];
    for (final row in result.rows) {
      if (row.leftNumber != null) {
        _setAt(leftKinds, row.leftNumber! - 1,
            row.kind == DiffRowKind.same ? null : row.kind);
      }
      if (row.rightNumber != null) {
        _setAt(rightKinds, row.rightNumber! - 1,
            row.kind == DiffRowKind.same ? null : row.kind);
      }
    }
    _leftController.setHighlights(leftKinds, {
      DiffRowKind.removed: palette.removedBg,
      DiffRowKind.modified: palette.modifiedBg,
      DiffRowKind.added: palette.addedBg,
    });
    _rightController.setHighlights(rightKinds, {
      DiffRowKind.added: palette.addedBg,
      DiffRowKind.modified: palette.modifiedBg,
      DiffRowKind.removed: palette.removedBg,
    });
  }

  static void _setAt(List<DiffRowKind?> list, int index, DiffRowKind? value) {
    while (list.length <= index) {
      list.add(null);
    }
    list[index] = value;
  }

  Future<void> _save({required bool left, required bool right}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = <String>[];
      if (left && _leftDirty) {
        await File(widget.leftPath).writeAsString(_leftController.text);
        _savedLeft = _leftController.text;
        _leftExists = true;
        saved.add(p.basename(widget.leftPath));
      }
      if (right && _rightDirty) {
        await File(widget.rightPath).writeAsString(_rightController.text);
        _savedRight = _rightController.text;
        _rightExists = true;
        saved.add(p.basename(widget.rightPath));
      }
      if (saved.isEmpty) return;
      if (mounted) setState(() {});
      messenger.showSnackBar(SnackBar(
        content: Text('Saved ${saved.join(' and ')}'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Save failed: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  void _jumpToBlock(int direction) {
    final result = _result;
    if (result == null || result.changeBlocks.isEmpty) return;
    var next = _currentBlock + direction;
    next = next.clamp(0, result.changeBlocks.length - 1);
    setState(() => _currentBlock = next);
    _jumpToRow(result.changeBlocks[next]);
  }

  void _jumpToRow(int rowIndex) {
    if (!_viewScroll.hasClients) return;
    final target = math.max(0.0, rowIndex * _rowExtent - 120);
    _viewScroll.animateTo(
      math.min(target, _viewScroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  String get _title => widget.title ?? p.basename(widget.leftPath);

  @override
  Widget build(BuildContext context) {
    final palette = DiffPalette.of(context);
    final result = _result;
    final scheme = Theme.of(context).colorScheme;

    if (_error != null) {
      return Center(child: Text('Could not read files:\n$_error'));
    }
    if (_notice != null) return _NoticeView(message: _notice!);
    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            _save(left: true, right: true),
      },
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
            child: Row(
              children: [
                if (widget.onBack != null)
                  IconButton(
                    tooltip: 'Change files',
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back, size: 20),
                  ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(_title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 14),
                _ChangeStats(result: result, palette: palette),
                if (_leftDirty || _rightDirty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text('● unsaved',
                        style: TextStyle(
                            fontSize: 11.5, color: palette.modified)),
                  ),
                const Spacer(),
                if (!_editing && result.changeBlocks.isNotEmpty) ...[
                  Text(
                    _currentBlock < 0
                        ? '${result.changeBlocks.length} changes'
                        : '${_currentBlock + 1} / ${result.changeBlocks.length}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  IconButton(
                    tooltip: 'Previous change',
                    onPressed:
                        _currentBlock > 0 ? () => _jumpToBlock(-1) : null,
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                  IconButton(
                    tooltip: 'Next change',
                    onPressed: _currentBlock < result.changeBlocks.length - 1
                        ? () => _jumpToBlock(1)
                        : null,
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                  const SizedBox(width: 8),
                ],
                if (_editing) ...[
                  TextButton.icon(
                    onPressed: _leftDirty
                        ? () => _save(left: true, right: false)
                        : null,
                    icon: const Icon(Icons.save_outlined, size: 17),
                    label: Text(
                        _leftExists ? 'Save left' : 'Create left'),
                  ),
                  TextButton.icon(
                    onPressed: _rightDirty
                        ? () => _save(left: false, right: true)
                        : null,
                    icon: const Icon(Icons.save_outlined, size: 17),
                    label: Text(
                        _rightExists ? 'Save right' : 'Create right'),
                  ),
                  const SizedBox(width: 8),
                ],
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(
                        value: false,
                        icon: Icon(Icons.visibility_outlined, size: 16),
                        label: Text('View')),
                    ButtonSegment(
                        value: true,
                        icon: Icon(Icons.edit_outlined, size: 16),
                        label: Text('Edit')),
                  ],
                  selected: {_editing},
                  onSelectionChanged: (selection) {
                    _debounce?.cancel();
                    setState(() => _editing = selection.first);
                    if (!selection.first) _rediff();
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 30, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _leftExists
                        ? widget.leftPath
                        : '${widget.leftPath}  (does not exist yet)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Text(
                    _rightExists
                        ? widget.rightPath
                        : '${widget.rightPath}  (does not exist yet)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _editing
                ? _editBody(scheme)
                : _viewBody(result, palette),
          ),
        ],
      ),
    );
  }

  Widget _viewBody(DiffResult result, DiffPalette palette) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: result.rows.isEmpty
              ? const Center(child: Text('Both files are empty'))
              : ListView.builder(
                  controller: _viewScroll,
                  itemExtent: _rowExtent,
                  itemCount: result.rows.length,
                  itemBuilder: (context, index) => _DiffRowWidget(
                      row: result.rows[index], palette: palette),
                ),
        ),
        _ChangeMap(result: result, palette: palette, onJump: _jumpToRow),
      ],
    );
  }

  Widget _editBody(ColorScheme scheme) {
    Widget editor(
        _DiffEditingController controller, ScrollController scroll) {
      return TextField(
        controller: controller,
        scrollController: scroll,
        maxLines: null,
        expands: true,
        style: monoStyle,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.fromLTRB(14, 10, 14, 10),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: editor(_leftController, _leftEditScroll)),
        VerticalDivider(
            width: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
        Expanded(child: editor(_rightController, _rightEditScroll)),
      ],
    );
  }
}

/// A [TextEditingController] that paints per-line diff backgrounds while
/// the user types, so added / removed / modified lines stay highlighted
/// during editing.
class _DiffEditingController extends TextEditingController {
  List<DiffRowKind?> _lineKinds = const [];
  Map<DiffRowKind, Color> _colors = const {};

  void setHighlights(List<DiffRowKind?> kinds, Map<DiffRowKind, Color> colors) {
    _lineKinds = kinds;
    _colors = colors;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final lines = text.split('\n');
    final children = <TextSpan>[];
    for (var i = 0; i < lines.length; i++) {
      final kind = i < _lineKinds.length ? _lineKinds[i] : null;
      final bg = kind == null ? null : _colors[kind];
      final chunk = i < lines.length - 1 ? '${lines[i]}\n' : lines[i];
      children.add(TextSpan(
        text: chunk,
        style: bg == null ? null : TextStyle(backgroundColor: bg),
      ));
    }
    return TextSpan(style: style, children: children);
  }
}

class _SideContent {
  const _SideContent({
    this.text,
    this.binary = false,
    this.tooLarge = false,
    this.exists = true,
  });

  final String? text;
  final bool binary;
  final bool tooLarge;
  final bool exists;
}

class _ChangeStats extends StatelessWidget {
  const _ChangeStats({required this.result, required this.palette});

  final DiffResult result;
  final DiffPalette palette;

  @override
  Widget build(BuildContext context) {
    Widget chip(String text, Color color) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(text,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
        );
    if (result.changeBlocks.isEmpty) {
      return chip('identical', palette.added);
    }
    return Row(children: [
      if (result.addedCount > 0) chip('+${result.addedCount}', palette.added),
      if (result.removedCount > 0)
        chip('−${result.removedCount}', palette.removed),
      if (result.modifiedCount > 0)
        chip('~${result.modifiedCount}', palette.modified),
    ]);
  }
}

class _DiffRowWidget extends StatelessWidget {
  const _DiffRowWidget({required this.row, required this.palette});

  final DiffRow row;
  final DiffPalette palette;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final numberStyle = monoStyle.copyWith(
      fontSize: 11.5,
      color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
    );

    return ColoredBox(
      color: palette.rowBackground(row.kind),
      child: Row(
        children: [
          _gutter(row.leftNumber, numberStyle),
          Expanded(
            child: _cell(
              context,
              text: row.leftText,
              spans: row.leftSpans,
              emphasis: palette.removedEmphasis,
              missing: row.kind == DiffRowKind.added,
            ),
          ),
          VerticalDivider(
              width: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          _gutter(row.rightNumber, numberStyle),
          Expanded(
            child: _cell(
              context,
              text: row.rightText,
              spans: row.rightSpans,
              emphasis: palette.addedEmphasis,
              missing: row.kind == DiffRowKind.removed,
            ),
          ),
        ],
      ),
    );
  }

  Widget _gutter(int? number, TextStyle style) {
    return SizedBox(
      width: 52,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Text(
          number?.toString() ?? '',
          textAlign: TextAlign.right,
          style: style,
        ),
      ),
    );
  }

  Widget _cell(
    BuildContext context, {
    required String? text,
    required List<(int, int)>? spans,
    required Color emphasis,
    required bool missing,
  }) {
    if (missing) {
      return Container(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.25),
      );
    }
    final content = text ?? '';
    if (spans == null || spans.isEmpty) {
      return Text(content,
          maxLines: 1, overflow: TextOverflow.clip, style: monoStyle);
    }
    final children = <TextSpan>[];
    var cursor = 0;
    for (final (start, end) in spans) {
      if (start > cursor) {
        children.add(TextSpan(text: content.substring(cursor, start)));
      }
      children.add(TextSpan(
        text: content.substring(start, end),
        style: TextStyle(backgroundColor: emphasis),
      ));
      cursor = end;
    }
    if (cursor < content.length) {
      children.add(TextSpan(text: content.substring(cursor)));
    }
    return Text.rich(
      TextSpan(style: monoStyle, children: children),
      maxLines: 1,
      overflow: TextOverflow.clip,
    );
  }
}

class _ChangeMap extends StatelessWidget {
  const _ChangeMap({
    required this.result,
    required this.palette,
    required this.onJump,
  });

  final DiffResult result;
  final DiffPalette palette;
  final void Function(int rowIndex) onJump;

  @override
  Widget build(BuildContext context) {
    if (result.rows.isEmpty) return const SizedBox(width: 14);
    return GestureDetector(
      onTapDown: (details) {
        final box = context.findRenderObject() as RenderBox;
        final fraction = details.localPosition.dy / box.size.height;
        onJump((fraction * result.rows.length).round());
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: CustomPaint(
          size: const Size(14, double.infinity),
          painter: _ChangeMapPainter(result: result, palette: palette),
        ),
      ),
    );
  }
}

class _ChangeMapPainter extends CustomPainter {
  _ChangeMapPainter({required this.result, required this.palette});

  final DiffResult result;
  final DiffPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final total = result.rows.length;
    if (total == 0) return;
    final paint = Paint();
    for (var i = 0; i < total; i++) {
      final kind = result.rows[i].kind;
      if (kind == DiffRowKind.same) continue;
      paint.color = switch (kind) {
        DiffRowKind.added => palette.added,
        DiffRowKind.removed => palette.removed,
        _ => palette.modified,
      };
      final top = i / total * size.height;
      final height = math.max(2.0, size.height / total);
      canvas.drawRect(Rect.fromLTWH(3, top, size.width - 6, height), paint);
    }
  }

  @override
  bool shouldRepaint(_ChangeMapPainter oldDelegate) =>
      oldDelegate.result != result;
}

class _NoticeView extends StatelessWidget {
  const _NoticeView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.visibility_off_outlined,
              size: 42, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(message, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

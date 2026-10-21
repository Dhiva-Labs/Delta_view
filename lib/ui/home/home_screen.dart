/// The home screen of a tab: pick what to compare (folders, files, pasted
/// text or a three-way merge), by browsing, typing a path or dropping
/// things onto it, and reopen recent comparisons.
library;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../../cli/user_paths.dart';
import '../../compare/comparison.dart';
import '../brand/app_info.dart';
import '../brand/app_logo.dart';
import '../shortcuts/app_shortcuts.dart';
import 'recent_list.dart';
import 'side_card.dart';
import 'side_slot.dart';
import 'text_compare_form.dart';

enum CompareMode {
  folders('Folders', Icons.folder_copy_outlined),
  files('Files', Icons.description_outlined),
  text('Text', Icons.notes),
  merge('Merge', Icons.merge_type);

  const CompareMode(this.label, this.icon);

  final String label;
  final IconData icon;

  /// What the side cards hold in this mode; null when there are none.
  SlotKind? get slotKind => switch (this) {
        folders => SlotKind.folder,
        files || merge => SlotKind.file,
        text => null,
      };
}

class PickerView extends StatefulWidget {
  const PickerView({
    super.key,
    required this.onCompare,
    this.previous,
  });

  final void Function(Comparison comparison) onCompare;

  /// The comparison this tab showed before, to start from its paths.
  final Comparison? previous;

  @override
  State<PickerView> createState() => _PickerViewState();
}

class _PickerViewState extends State<PickerView> {
  CompareMode _mode = CompareMode.folders;

  final _left = SideSlot('Left');
  final _right = SideSlot('Right');
  final _base = SideSlot('Base');
  final _output = SideSlot('Output', hint: 'Where the merged file is saved');
  final _leftText = TextEditingController();
  final _rightText = TextEditingController();

  late final List<SideSlot> _slots = [_left, _right, _base, _output];
  late final Map<SideSlot, GlobalKey> _zoneKeys = {
    for (final slot in _slots) slot: GlobalKey(),
  };

  bool _dragging = false;
  SideSlot? _dropTarget;

  @override
  void initState() {
    super.initState();
    _seedFrom(widget.previous);
    for (final slot in _slots) {
      slot.addListener(_slotChanged);
    }
  }

  @override
  void dispose() {
    for (final slot in _slots) {
      slot.dispose();
    }
    _leftText.dispose();
    _rightText.dispose();
    super.dispose();
  }

  void _slotChanged() {
    if (mounted) setState(() {});
  }

  void _seedFrom(Comparison? previous) {
    switch (previous) {
      case FolderComparison c:
        _mode = CompareMode.folders;
        _left.setSpec(c.left);
        _right.setSpec(c.right);
      case FileComparison c:
        _mode = CompareMode.files;
        _left.setSpec(c.left);
        _right.setSpec(c.right);
      case TextComparison c:
        _mode = CompareMode.text;
        _leftText.text = c.leftText;
        _rightText.text = c.rightText;
      case ThreeWayComparison c:
        _mode = CompareMode.merge;
        _left.setSpec(c.left);
        _base.setSpec(c.base);
        _right.setSpec(c.right);
        _output.setSpec(c.output);
      case null:
        break;
    }
  }

  /// Switches mode, keeping each side's path unless it no longer fits.
  void _setMode(CompareMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      final kind = mode.slotKind;
      if (kind != null) {
        for (final slot in [_left, _right, _base]) {
          slot.keepIfFits(kind);
        }
      }
    });
  }

  // ---- readiness ----

  /// Why Compare is disabled, or null when everything is in place.
  String? get _blocker {
    switch (_mode) {
      case CompareMode.text:
        return null;
      case CompareMode.folders:
      case CompareMode.files:
        return _blockerFor([_left, _right], _mode.slotKind!) ??
            (_left.spec == _right.spec ? 'Both sides are the same path' : null);
      case CompareMode.merge:
        final sides = _blockerFor([_left, _base, _right], SlotKind.file);
        if (sides != null) return sides;
        if (!_output.isEmpty &&
            _output.status(SlotKind.file, mayBeMissing: true) ==
                SlotStatus.wrongKind) {
          return 'Output must be a file path';
        }
        return null;
    }
  }

  String? _blockerFor(List<SideSlot> slots, SlotKind kind) {
    final empty = slots.where((s) => s.isEmpty).toList();
    if (empty.isNotEmpty) {
      return empty.length == slots.length
          ? 'Choose ${kind == SlotKind.folder ? 'two folders' : 'the files'} '
              'to compare'
          : 'Choose ${empty.map((s) => s.label).join(' and ')}';
    }
    for (final slot in slots) {
      switch (slot.status(kind)) {
        case SlotStatus.missing:
          return '${slot.label}: nothing at this path';
        case SlotStatus.wrongKind:
          return '${slot.label} is a ${kind == SlotKind.folder ? 'file' : 'folder'}';
        case SlotStatus.ready || SlotStatus.empty:
          break;
      }
    }
    return null;
  }

  void _compare() {
    if (_blocker != null) return;
    final comparison = switch (_mode) {
      CompareMode.folders => FolderComparison(_left.spec!, _right.spec!),
      CompareMode.files => FileComparison(_left.spec!, _right.spec!),
      CompareMode.text => TextComparison(
          leftText: _leftText.text, rightText: _rightText.text),
      CompareMode.merge => ThreeWayComparison(
          left: _left.spec!,
          base: _base.spec!,
          right: _right.spec!,
          output: _output.spec,
        ),
    };
    widget.onCompare(comparison);
  }

  // ---- drag and drop ----

  SideSlot? _slotAt(Offset global) {
    for (final entry in _zoneKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(global)) return entry.key;
    }
    return null;
  }

  void _dragUpdated(DropEventDetails details) {
    final target = _slotAt(details.globalPosition);
    if (target != _dropTarget || !_dragging) {
      setState(() {
        _dragging = true;
        _dropTarget = target;
      });
    }
  }

  void _dragExited(DropEventDetails details) {
    setState(() {
      _dragging = false;
      _dropTarget = null;
    });
  }

  void _dropped(DropDoneDetails details) {
    final target = _dropTarget ?? _slotAt(details.globalPosition);
    setState(() {
      _dragging = false;
      _dropTarget = null;
    });
    final paths = [
      for (final item in details.files)
        if (item.path.isNotEmpty) item.path,
    ];
    if (paths.isEmpty) return;
    final kinds = [for (final path in paths) pathKindOf(path)];
    if (kinds.contains(PathKind.missing)) {
      _say('Could not read what was dropped.');
      return;
    }
    final allFolders = kinds.every((k) => k == PathKind.directory);
    final allFiles = kinds.every((k) => k == PathKind.file);

    if (paths.length == 1) {
      _dropOne(paths.single, kinds.single, target);
    } else if (paths.length == 2 && (allFolders || allFiles)) {
      if (_mode != CompareMode.merge || allFolders) {
        _setMode(allFolders ? CompareMode.folders : CompareMode.files);
      }
      _left.setSpec(LocalSource(paths[0]));
      _right.setSpec(LocalSource(paths[1]));
    } else if (paths.length == 3 && allFiles) {
      _setMode(CompareMode.merge);
      _left.setSpec(LocalSource(paths[0]));
      _base.setSpec(LocalSource(paths[1]));
      _right.setSpec(LocalSource(paths[2]));
    } else {
      _say('Drop two folders or two files, or three files to merge.');
    }
  }

  void _dropOne(String path, PathKind kind, SideSlot? target) {
    if (_mode == CompareMode.merge) {
      if (kind == PathKind.directory) {
        _say('A merge needs files, not folders.');
        return;
      }
      (target ?? [_left, _base, _right].firstWhere((s) => s.isEmpty,
              orElse: () => _left))
          .setSpec(LocalSource(path));
      return;
    }
    // Follow what was dropped: a folder means folder mode.
    final wanted =
        kind == PathKind.directory ? CompareMode.folders : CompareMode.files;
    if (_mode != wanted) _setMode(wanted);
    final slot = target ??
        (_left.isEmpty
            ? _left
            : _right.isEmpty
                ? _right
                : _left);
    if (slot != _left && slot != _right) return;
    slot.setSpec(LocalSource(path));
  }

  void _say(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
    ));
  }

  DropHighlight _highlightFor(SideSlot slot) => _dropTarget == slot
      ? DropHighlight.here
      : _dragging
          ? DropHighlight.elsewhere
          : DropHighlight.none;

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: _dragUpdated,
      onDragUpdated: _dragUpdated,
      onDragExited: _dragExited,
      onDragDone: _dropped,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 640;
          final wide = constraints.maxWidth >= 840;
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
                horizontal: narrow ? 16 : 32, vertical: narrow ? 20 : 36),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 940),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Hero(),
                    SizedBox(height: narrow ? 20 : 28),
                    Center(child: _modeSelector()),
                    const SizedBox(height: 22),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: KeyedSubtree(
                        key: ValueKey(_mode),
                        child: _form(narrow: narrow, wide: wide),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _compareRow(context),
                    const SizedBox(height: 36),
                    RecentList(onOpen: widget.onCompare),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _modeSelector() {
    return SegmentedButton<CompareMode>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.standard,
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      segments: [
        for (final mode in CompareMode.values)
          ButtonSegment(
            value: mode,
            label: Text(mode.label),
            icon: Icon(mode.icon, size: 18),
          ),
      ],
      selected: {_mode},
      onSelectionChanged: (selection) => _setMode(selection.first),
    );
  }

  Widget _form({required bool narrow, required bool wide}) {
    switch (_mode) {
      case CompareMode.folders:
      case CompareMode.files:
        final kind = _mode.slotKind!;
        final left = SideCard(
          key: _zoneKeys[_left],
          slot: _left,
          kind: kind,
          highlight: _highlightFor(_left),
          onSubmit: _compare,
        );
        final right = SideCard(
          key: _zoneKeys[_right],
          slot: _right,
          kind: kind,
          highlight: _highlightFor(_right),
          onSubmit: _compare,
        );
        final swap = IconButton.filledTonal(
          tooltip: 'Swap sides',
          onPressed: _left.isEmpty && _right.isEmpty
              ? null
              : () => _left.swapWith(_right),
          icon: Icon(narrow ? Icons.swap_vert : Icons.swap_horiz),
        );
        if (narrow) {
          return Column(children: [
            left,
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 6), child: swap),
            right,
          ]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 44, 10, 0),
              child: swap,
            ),
            Expanded(child: right),
          ],
        );
      case CompareMode.text:
        return TextCompareForm(
            left: _leftText, right: _rightText, stacked: narrow);
      case CompareMode.merge:
        final cards = [
          for (final slot in [_left, _base, _right])
            SideCard(
              key: _zoneKeys[slot],
              slot: slot,
              kind: SlotKind.file,
              highlight: _highlightFor(slot),
              onSubmit: _compare,
            ),
        ];
        final output = SideCard(
          key: _zoneKeys[_output],
          slot: _output,
          kind: SlotKind.file,
          highlight: _highlightFor(_output),
          onSubmit: _compare,
          optional: true,
          mayBeMissing: true,
          saveDialog: true,
        );
        return Column(
          children: [
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(child: cards[i]),
                  ],
                ],
              )
            else
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                cards[i],
              ],
            const SizedBox(height: 12),
            output,
          ],
        );
    }
  }

  Widget _compareRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocker = _blocker;
    final ready = blocker == null;
    final isMerge = _mode == CompareMode.merge;
    return Column(
      children: [
        AnimatedScale(
          scale: ready ? 1 : 0.97,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: FilledButton.icon(
            onPressed: ready ? _compare : null,
            style: FilledButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 40, vertical: 18),
              textStyle:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            icon: Icon(isMerge ? Icons.merge_type : Icons.compare_arrows),
            label: Text(isMerge ? 'Merge' : 'Compare'),
          ),
        ),
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: Text(
            blocker ??
                switch (_mode) {
                  CompareMode.text =>
                    'Or press ${AppAction.compareClipboard.keyLabel} '
                        'anywhere to compare the clipboard.',
                  CompareMode.merge =>
                    'Drop three files anywhere on this screen: '
                        'yours, the common base, theirs.',
                  CompareMode.folders || CompareMode.files =>
                    'Drop two ${_mode == CompareMode.folders ? 'folders' : 'files'} '
                        'anywhere on this screen. '
                        '${AppAction.newTab.keyLabel} opens another tab.',
                },
            key: ValueKey(blocker ?? _mode),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const AppLogo(size: 60),
        const SizedBox(width: 18),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(appName,
                style: textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700, letterSpacing: -0.5)),
            const SizedBox(height: 2),
            Text(appTagline,
                style: textTheme.bodyLarge
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ],
    );
  }
}

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'file_diff_view.dart';
import 'folder_diff_view.dart';
import 'shell.dart';

enum CompareMode { folders, files }

enum _TabStage { pick, folder, file }

/// The content of one comparison tab: starts as a picker, becomes a folder
/// tree or file diff after Compare, and can go back for a fresh pick.
class TabRoot extends StatefulWidget {
  const TabRoot({super.key, required this.tabId});

  final int tabId;

  @override
  State<TabRoot> createState() => _TabRootState();
}

class _TabRootState extends State<TabRoot> {
  _TabStage _stage = _TabStage.pick;
  CompareMode _mode = CompareMode.folders;
  String? _leftPath;
  String? _rightPath;

  void _onCompare(CompareMode mode, String left, String right) {
    setState(() {
      _mode = mode;
      _leftPath = left;
      _rightPath = right;
      _stage = mode == CompareMode.folders ? _TabStage.folder : _TabStage.file;
    });
    TabbedShellState.of(context).updateTab(
      widget.tabId,
      title: '${p.basename(left)} ↔ ${p.basename(right)}',
      icon: mode == CompareMode.folders
          ? Icons.folder_copy_outlined
          : Icons.description_outlined,
    );
  }

  void _backToPicker() {
    setState(() => _stage = _TabStage.pick);
    TabbedShellState.of(context).updateTab(
      widget.tabId,
      title: 'New comparison',
      icon: Icons.add_circle_outline,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: switch (_stage) {
        _TabStage.pick => PickerView(
            key: const ValueKey('pick'),
            initialMode: _mode,
            initialLeft: _leftPath,
            initialRight: _rightPath,
            onCompare: _onCompare,
          ),
        _TabStage.folder => FolderDiffView(
            key: ValueKey('folder-$_leftPath-$_rightPath'),
            leftRoot: _leftPath!,
            rightRoot: _rightPath!,
            onBack: _backToPicker,
          ),
        _TabStage.file => FileDiffView(
            key: ValueKey('file-$_leftPath-$_rightPath'),
            leftPath: _leftPath!,
            rightPath: _rightPath!,
            onBack: _backToPicker,
          ),
      },
    );
  }
}

class PickerView extends StatefulWidget {
  const PickerView({
    super.key,
    required this.onCompare,
    this.initialMode = CompareMode.folders,
    this.initialLeft,
    this.initialRight,
  });

  final void Function(CompareMode mode, String left, String right) onCompare;
  final CompareMode initialMode;
  final String? initialLeft;
  final String? initialRight;

  @override
  State<PickerView> createState() => _PickerViewState();
}

class _PickerViewState extends State<PickerView> {
  late CompareMode _mode = widget.initialMode;
  late String? _leftPath = widget.initialLeft;
  late String? _rightPath = widget.initialRight;

  bool get _ready => _leftPath != null && _rightPath != null;

  Future<void> _pick(bool left) async {
    String? path;
    if (_mode == CompareMode.folders) {
      path = await getDirectoryPath();
    } else {
      final file = await openFile();
      path = file?.path;
    }
    if (path == null) return;
    setState(() {
      if (left) {
        _leftPath = path;
      } else {
        _rightPath = path;
      }
    });
  }

  void _swap() {
    setState(() {
      final tmp = _leftPath;
      _leftPath = _rightPath;
      _rightPath = tmp;
    });
  }

  void _compare() {
    if (!_ready) return;
    final left = _leftPath!;
    final right = _rightPath!;
    final exists = _mode == CompareMode.folders
        ? Directory(left).existsSync() && Directory(right).existsSync()
        : File(left).existsSync() && File(right).existsSync();
    if (!exists) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('One of the selected paths no longer exists.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    widget.onCompare(_mode, left, right);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        scheme.primary,
                        scheme.tertiary,
                      ]),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.difference_outlined,
                        color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Text('DeltaView',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Compare folders and files, beautifully.',
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 32),
              SegmentedButton<CompareMode>(
                segments: const [
                  ButtonSegment(
                    value: CompareMode.folders,
                    label: Text('Folders'),
                    icon: Icon(Icons.folder_copy_outlined),
                  ),
                  ButtonSegment(
                    value: CompareMode.files,
                    label: Text('Files'),
                    icon: Icon(Icons.description_outlined),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) {
                  setState(() {
                    _mode = selection.first;
                    _leftPath = null;
                    _rightPath = null;
                  });
                },
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                      child: _PickCard(
                    label: 'Left',
                    path: _leftPath,
                    mode: _mode,
                    onTap: () => _pick(true),
                    onClear: () => setState(() => _leftPath = null),
                  )),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: IconButton.filledTonal(
                      tooltip: 'Swap sides',
                      onPressed: _ready ? _swap : null,
                      icon: const Icon(Icons.swap_horiz),
                    ),
                  ),
                  Expanded(
                      child: _PickCard(
                    label: 'Right',
                    path: _rightPath,
                    mode: _mode,
                    onTap: () => _pick(false),
                    onClear: () => setState(() => _rightPath = null),
                  )),
                ],
              ),
              const SizedBox(height: 32),
              AnimatedScale(
                scale: _ready ? 1 : 0.97,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: FilledButton.icon(
                  onPressed: _ready ? _compare : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 40, vertical: 18),
                    textStyle: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  icon: const Icon(Icons.compare_arrows),
                  label: const Text('Compare'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Tip: open more comparisons in parallel with the + tab (Ctrl+T)',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickCard extends StatefulWidget {
  const _PickCard({
    required this.label,
    required this.path,
    required this.mode,
    required this.onTap,
    required this.onClear,
  });

  final String label;
  final String? path;
  final CompareMode mode;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  State<_PickCard> createState() => _PickCardState();
}

class _PickCardState extends State<_PickCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasPath = widget.path != null;
    final icon = widget.mode == CompareMode.folders
        ? (hasPath ? Icons.folder : Icons.folder_outlined)
        : (hasPath ? Icons.description : Icons.description_outlined);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          height: 150,
          decoration: BoxDecoration(
            color: Theme.of(context).cardTheme.color,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              width: 1.5,
              color: hasPath
                  ? scheme.primary.withValues(alpha: 0.65)
                  : _hovered
                      ? scheme.primary.withValues(alpha: 0.4)
                      : scheme.outlineVariant,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.10),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    )
                  ]
                : const [],
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(icon,
                        size: 34,
                        color:
                            hasPath ? scheme.primary : scheme.onSurfaceVariant),
                    const SizedBox(height: 12),
                    Text(
                      hasPath
                          ? p.basename(widget.path!)
                          : 'Choose ${widget.label}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color:
                            hasPath ? scheme.onSurface : scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (hasPath) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.path!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (hasPath)
                Positioned(
                  top: 6,
                  right: 6,
                  child: IconButton(
                    tooltip: 'Clear selection',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: widget.onClear,
                    icon: const Icon(Icons.close),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

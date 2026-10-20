import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../compare/comparison.dart';
import '../compare/folder_compare.dart';
import '../theme.dart';
import 'shell.dart';

enum TreeFilter { all, changes, leftOnly, rightOnly }

class FolderDiffView extends StatefulWidget {
  const FolderDiffView({
    super.key,
    required this.left,
    required this.right,
    this.onBack,
  });

  final SourceSpec left;
  final SourceSpec right;
  final VoidCallback? onBack;

  /// The local roots. Only local folders are scanned so far.
  String get leftRoot => (left as LocalSource).path;
  String get rightRoot => (right as LocalSource).path;

  @override
  State<FolderDiffView> createState() => _FolderDiffViewState();
}

class _FolderDiffViewState extends State<FolderDiffView> {
  CompareNode? _root;
  String? _error;
  CompareProgress? _progress;
  final Set<String> _expanded = {''};
  TreeFilter _filter = TreeFilter.changes;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _root = null;
      _error = null;
      _progress = null;
    });
    try {
      if (widget.left is! LocalSource || widget.right is! LocalSource) {
        throw UnsupportedError(
            'Only folders on this computer can be compared so far.');
      }
      final root = await compareFolders(
        widget.leftRoot,
        widget.rightRoot,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _root = root;
        for (final child in root.children) {
          if (child.isDirectory && child.hasChanges) {
            _expanded.add(child.relativePath);
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  bool _matchesFilter(CompareNode node) {
    final byStatus = switch (_filter) {
      TreeFilter.all => true,
      TreeFilter.changes => node.isDirectory
          ? node.hasChanges
          : node.status != EntryStatus.identical,
      TreeFilter.leftOnly => node.isDirectory
          ? node.onlyLeftCount > 0 || node.status == EntryStatus.onlyLeft
          : node.status == EntryStatus.onlyLeft,
      TreeFilter.rightOnly => node.isDirectory
          ? node.onlyRightCount > 0 || node.status == EntryStatus.onlyRight
          : node.status == EntryStatus.onlyRight,
    };
    if (!byStatus) return false;
    if (_query.isEmpty) return true;
    return _matchesQuery(node);
  }

  bool _matchesQuery(CompareNode node) {
    if (node.name.toLowerCase().contains(_query)) return true;
    return node.children.any(_matchesQuery);
  }

  void _buildVisible(
      CompareNode node, int depth, List<(CompareNode, int)> out) {
    for (final child in node.children) {
      if (!_matchesFilter(child)) continue;
      out.add((child, depth));
      if (child.isDirectory && _expanded.contains(child.relativePath)) {
        _buildVisible(child, depth + 1, out);
      }
    }
  }

  void _setAllExpanded(bool expanded) {
    setState(() {
      _expanded
        ..clear()
        ..add('');
      if (expanded && _root != null) _collectDirs(_root!);
    });
  }

  void _collectDirs(CompareNode node) {
    for (final child in node.children) {
      if (child.isDirectory) {
        _expanded.add(child.relativePath);
        _collectDirs(child);
      }
    }
  }

  void _openFile(CompareNode node) {
    // Pass both sides even when one is missing — the diff view can then
    // create the missing file on save.
    final relative = p.split(node.relativePath).join('/');
    TabbedShellState.of(context).openComparison(
      FileComparison(
        widget.left.child(relative),
        widget.right.child(relative),
        titleOverride: relative,
      ),
      title: node.name,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = DiffPalette.of(context);
    final root = _root;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
          child: Row(
            children: [
              if (widget.onBack != null)
                IconButton(
                  tooltip: 'Change folders',
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back, size: 20),
                ),
              const SizedBox(width: 4),
              Expanded(child: _PathChip(path: widget.left.description)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.compare_arrows, size: 18),
              ),
              Expanded(child: _PathChip(path: widget.right.description)),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Re-scan',
                onPressed: root == null && _error == null ? null : _run,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _error != null
                ? _ErrorView(message: _error!, onRetry: _run)
                : root == null
                    ? _ScanningView(progress: _progress)
                    : _buildResult(context, root, palette),
          ),
        ),
      ],
    );
  }

  Widget _buildResult(
      BuildContext context, CompareNode root, DiffPalette palette) {
    final visible = <(CompareNode, int)>[];
    _buildVisible(root, 0, visible);

    return Column(
      children: [
        _StatsHeader(root: root, palette: palette),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Expand all',
                visualDensity: VisualDensity.compact,
                onPressed: () => _setAllExpanded(true),
                icon: const Icon(Icons.unfold_more, size: 19),
              ),
              IconButton(
                tooltip: 'Collapse all',
                visualDensity: VisualDensity.compact,
                onPressed: () => _setAllExpanded(false),
                icon: const Icon(Icons.unfold_less, size: 19),
              ),
              const SizedBox(width: 10),
              SegmentedButton<TreeFilter>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                segments: const [
                  ButtonSegment(value: TreeFilter.all, label: Text('All')),
                  ButtonSegment(
                      value: TreeFilter.changes, label: Text('Changes')),
                  ButtonSegment(
                      value: TreeFilter.leftOnly, label: Text('Left only')),
                  ButtonSegment(
                      value: TreeFilter.rightOnly, label: Text('Right only')),
                ],
                selected: {_filter},
                onSelectionChanged: (selection) =>
                    setState(() => _filter = selection.first),
              ),
              const Spacer(),
              SizedBox(
                width: 240,
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Filter by name…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        const _ColumnHeaders(),
        const Divider(),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    _filter == TreeFilter.changes && root.changedCount == 0
                        ? 'Folders are identical 🎉'
                        : 'Nothing matches the current filter.',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  itemCount: visible.length,
                  itemExtent: 34,
                  itemBuilder: (context, index) {
                    final (node, depth) = visible[index];
                    return _TreeRow(
                      node: node,
                      depth: depth,
                      palette: palette,
                      expanded: _expanded.contains(node.relativePath),
                      onToggle: () {
                        setState(() {
                          if (!_expanded.add(node.relativePath)) {
                            _expanded.remove(node.relativePath);
                          }
                        });
                      },
                      onOpen: () => _openFile(node),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

const _sizeColWidth = 62.0;
const _timeColWidth = 116.0;

class _ColumnHeaders extends StatelessWidget {
  const _ColumnHeaders();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    );
    Widget pane() => Expanded(
          child: Row(
            children: [
              const SizedBox(width: 12),
              Expanded(child: Text('Name', style: style)),
              SizedBox(
                  width: _sizeColWidth,
                  child: Text('Size', textAlign: TextAlign.right, style: style)),
              SizedBox(
                  width: _timeColWidth,
                  child:
                      Text('Modified', textAlign: TextAlign.right, style: style)),
              const SizedBox(width: 14),
            ],
          ),
        );
    return SizedBox(
      height: 26,
      child: Row(children: [
        pane(),
        VerticalDivider(
            width: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
        pane(),
      ]),
    );
  }
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _fmtSize(int? size) {
  if (size == null) return '';
  if (size < 1000) return '$size B';
  if (size < 1000 * 1000) return '${(size / 1000).toStringAsFixed(1)} kB';
  if (size < 1000 * 1000 * 1000) {
    return '${(size / 1e6).toStringAsFixed(1)} MB';
  }
  return '${(size / 1e9).toStringAsFixed(1)} GB';
}

String _fmtTime(DateTime? time) {
  if (time == null) return '';
  final t = time.toLocal();
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  return '${t.day} ${_months[t.month - 1]} ${t.year} $hh:$mm';
}

/// Prominent change summary shown at the top of the comparison result.
class _StatsHeader extends StatelessWidget {
  const _StatsHeader({required this.root, required this.palette});

  final CompareNode root;
  final DiffPalette palette;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget card(IconData icon, int count, String label, Color color) {
      return Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 8),
              Text('$count',
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700, color: color)),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          card(Icons.edit_outlined, root.modifiedCount, 'modified',
              palette.modified),
          card(Icons.remove_circle_outline, root.onlyLeftCount, 'left only',
              palette.removed),
          card(Icons.add_circle_outline, root.onlyRightCount, 'right only',
              palette.added),
          card(Icons.check_circle_outline, root.identicalCount, 'identical',
              scheme.outline),
        ],
      ),
    );
  }
}

/// One aligned row of the Meld-style dual-pane tree: the same entry
/// rendered for the left and right folder, with size / mtime columns.
/// The pane where the entry doesn't exist renders as an empty slot.
class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.node,
    required this.depth,
    required this.palette,
    required this.expanded,
    required this.onToggle,
    required this.onOpen,
  });

  final CompareNode node;
  final int depth;
  final DiffPalette palette;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: node.isDirectory ? onToggle : onOpen,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _pane(context, left: true)),
          VerticalDivider(
              width: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          Expanded(child: _pane(context, left: false)),
        ],
      ),
    );
  }

  Widget _pane(BuildContext context, {required bool left}) {
    final scheme = Theme.of(context).colorScheme;
    final exists = left ? node.existsLeft : node.existsRight;

    if (!exists) {
      return Container(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
        padding: EdgeInsets.only(left: 34.0 + depth * 22),
        alignment: Alignment.centerLeft,
        child: Text(
          '— missing —',
          style: TextStyle(
            fontSize: 11.5,
            fontStyle: FontStyle.italic,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
          ),
        ),
      );
    }

    final color = switch (node.status) {
      EntryStatus.identical => scheme.onSurface,
      EntryStatus.modified => palette.modified,
      EntryStatus.onlyLeft => palette.removed,
      EntryStatus.onlyRight => palette.added,
    };
    final muted = node.status == EntryStatus.identical;
    final size = left ? node.leftSize : node.rightSize;
    final time = left ? node.leftModified : node.rightModified;
    final metaStyle = TextStyle(
        fontSize: 11.5,
        color: scheme.onSurfaceVariant.withValues(alpha: muted ? 0.75 : 1));

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 14),
      child: Row(
        children: [
          for (var i = 0; i < depth; i++)
            SizedBox(
              width: 22,
              child: Center(
                child: Container(
                  width: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
            ),
          if (node.isDirectory)
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.chevron_right,
                  size: 18, color: scheme.onSurfaceVariant),
            )
          else
            const SizedBox(width: 18),
          const SizedBox(width: 4),
          Icon(
            node.isDirectory
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined,
            size: 16,
            color: muted ? scheme.onSurfaceVariant : color,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              node.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: muted ? scheme.onSurfaceVariant : color,
                fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
              ),
            ),
          ),
          if (node.isDirectory && left) ...[
            if (node.modifiedCount > 0)
              _CountBadge(count: node.modifiedCount, color: palette.modified),
            if (node.onlyLeftCount > 0)
              _CountBadge(count: node.onlyLeftCount, color: palette.removed),
            if (node.onlyRightCount > 0)
              _CountBadge(count: node.onlyRightCount, color: palette.added),
          ],
          if (!node.isDirectory &&
              node.status == EntryStatus.modified &&
              !left) ...[
            if ((node.addedLines ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text('+${node.addedLines}',
                    style: monoStyle.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: palette.added)),
              ),
            if ((node.removedLines ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text('−${node.removedLines}',
                    style: monoStyle.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: palette.removed)),
              ),
          ],
          const Spacer(),
          SizedBox(
            width: _sizeColWidth,
            child: Text(_fmtSize(size),
                textAlign: TextAlign.right, style: metaStyle),
          ),
          SizedBox(
            width: _timeColWidth,
            child: Text(_fmtTime(time),
                textAlign: TextAlign.right, style: metaStyle),
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('$count',
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

class _PathChip extends StatelessWidget {
  const _PathChip({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: path,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _ScanningView extends StatelessWidget {
  const _ScanningView({this.progress});

  final CompareProgress? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
              width: 44, height: 44, child: CircularProgressIndicator()),
          const SizedBox(height: 20),
          Text('Scanning folders…',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: Text(
              progress == null
                  ? ''
                  : '${progress!.filesCompared} files · ${progress!.currentPath}',
              key: ValueKey(progress?.filesCompared),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline,
              size: 42, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          Text('Comparison failed',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

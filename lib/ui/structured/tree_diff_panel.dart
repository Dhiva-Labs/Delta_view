/// The JSON / YAML tree diff: a collapsible tree of keys and values with
/// what was added, removed and changed, each with its path.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../diff/structured/structured_compare.dart';
import '../../theme.dart';
import '../shortcuts/app_shortcuts.dart';

const _rowExtent = 28.0;
const _indent = 20.0;

class TreeDiffPanel extends StatefulWidget {
  const TreeDiffPanel({
    super.key,
    required this.result,
    required this.options,
    required this.onOptionsChanged,
  });

  final TreeDiffResult result;
  final TreeDiffOptions options;
  final ValueChanged<TreeDiffOptions> onOptionsChanged;

  @override
  State<TreeDiffPanel> createState() => _TreeDiffPanelState();
}

/// A node in the flattened, visible list.
class _Row {
  const _Row(this.node, this.depth);

  final TreeDiffNode node;
  final int depth;
}

class _TreeDiffPanelState extends State<TreeDiffPanel> {
  bool _changesOnly = true;

  /// Expanded nodes, by path, so the tree keeps its shape when the diff is
  /// recomputed with other options.
  final Set<String> _expanded = {};
  String? _selectedPath;

  /// The flattened rows on screen; rebuilt only when the tree's shape,
  /// the filter or the result changes, not on every selection.
  List<_Row>? _rows;
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'tree diff');

  /// Nodes with a change of their own, in document order, with the paths
  /// of their ancestors (to expand on the way there).
  late List<(TreeDiffNode, List<String>)> _targets;

  @override
  void initState() {
    super.initState();
    _expandChanged(widget.result.root);
    _targets = _collectTargets(widget.result.root);
  }

  @override
  void didUpdateWidget(TreeDiffPanel old) {
    super.didUpdateWidget(old);
    if (old.result != widget.result) {
      _expandChanged(widget.result.root);
      _targets = _collectTargets(widget.result.root);
      _rows = null;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Opens every container on the way to a change; whole added or removed
  /// subtrees stay closed until asked for.
  void _expandChanged(TreeDiffNode node) {
    if (node.status != TreeStatus.nested) return;
    _expanded.add(node.path);
    for (final c in node.children) {
      _expandChanged(c);
    }
  }

  static List<(TreeDiffNode, List<String>)> _collectTargets(TreeDiffNode root) {
    final out = <(TreeDiffNode, List<String>)>[];
    void walk(TreeDiffNode node, List<String> ancestors) {
      switch (node.status) {
        case TreeStatus.same:
          return;
        case TreeStatus.nested:
          for (final c in node.children) {
            walk(c, [...ancestors, node.path]);
          }
        default:
          out.add((node, ancestors));
      }
    }

    walk(root, const []);
    return out;
  }

  void _setAllExpanded(bool expand) {
    setState(() {
      _rows = null;
      _expanded.clear();
      if (expand) {
        void walk(TreeDiffNode node) {
          if (node.children.isEmpty) return;
          if (_changesOnly && node.status == TreeStatus.same) return;
          _expanded.add(node.path);
          node.children.forEach(walk);
        }

        walk(widget.result.root);
      } else {
        _expanded.add(widget.result.root.path);
      }
    });
  }

  List<_Row> _visible() => _rows ??= _flatten();

  List<_Row> _flatten() {
    final rows = <_Row>[];
    void walk(TreeDiffNode node, int depth) {
      for (final c in node.children) {
        if (_changesOnly && !c.hasChanges) continue;
        rows.add(_Row(c, depth));
        if (c.children.isNotEmpty && _expanded.contains(c.path)) {
          walk(c, depth + 1);
        }
      }
    }

    final root = widget.result.root;
    if (root.children.isEmpty && root.kind == TreeKind.scalar ||
        root.status == TreeStatus.changed) {
      // A scalar document, or one that changed type: show the root itself.
      rows.add(_Row(root, 0));
    } else {
      walk(root, 0);
    }
    return rows;
  }

  int get _currentTarget =>
      _targets.indexWhere((t) => t.$1.path == _selectedPath);

  void _go(int direction) {
    if (_targets.isEmpty) return;
    final current = _currentTarget;
    final next = current < 0
        ? (direction > 0 ? 0 : _targets.length - 1)
        : (current + direction).clamp(0, _targets.length - 1);
    final (node, ancestors) = _targets[next];
    setState(() {
      if (!_expanded.containsAll(ancestors)) _rows = null;
      _expanded.addAll(ancestors);
      _selectedPath = node.path;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(node.path));
  }

  void _reveal(String path) {
    if (!_scroll.hasClients) return;
    final index = _visible().indexWhere((r) => r.node.path == path);
    if (index < 0) return;
    final position = _scroll.position;
    final top = index * _rowExtent;
    if (top >= position.pixels &&
        top + _rowExtent <= position.pixels + position.viewportDimension) {
      return;
    }
    _scroll.animateTo(
      (top - position.viewportDimension / 3)
          .clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Copied $what'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _contextMenu(TreeDiffNode node, Offset position) async {
    setState(() => _selectedPath = node.path);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          position & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(value: 'path', child: Text('Copy path')),
        if (!identical(node.oldValue, Absent.value))
          const PopupMenuItem(value: 'old', child: Text('Copy left value')),
        if (!identical(node.newValue, Absent.value))
          const PopupMenuItem(value: 'new', child: Text('Copy right value')),
      ],
    );
    switch (choice) {
      case 'path':
        _copy(node.path, node.path);
      case 'old':
        _copy(valueToText(node.oldValue), 'the left value');
      case 'new':
        _copy(valueToText(node.newValue), 'the right value');
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visible();
    final selected = _selectedPath == null
        ? null
        : rows.where((r) => r.node.path == _selectedPath).firstOrNull?.node;
    final scheme = Theme.of(context).colorScheme;

    return CallbackShortcuts(
      bindings: bindActions({
        AppAction.nextChange: () => _go(1),
        AppAction.previousChange: () => _go(-1),
      }),
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Column(
          children: [
            _toolbar(context),
            const Divider(),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        widget.result.root.hasChanges
                            ? 'Nothing to show.'
                            : 'Both documents hold the same data.',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : Listener(
                      onPointerDown: (_) => _focus.requestFocus(),
                      child: ListView.builder(
                        controller: _scroll,
                        itemExtent: _rowExtent,
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          final node = row.node;
                          return _TreeRow(
                            node: node,
                            depth: row.depth,
                            expanded: _expanded.contains(node.path),
                            selected: node.path == _selectedPath,
                            onTap: () {
                              setState(() {
                                _selectedPath = node.path;
                                if (node.children.isNotEmpty) {
                                  _rows = null;
                                  if (!_expanded.add(node.path)) {
                                    _expanded.remove(node.path);
                                  }
                                }
                              });
                            },
                            onCopyPath: () => _copy(node.path, node.path),
                            onContextMenu: (p) => _contextMenu(node, p),
                          );
                        },
                      ),
                    ),
            ),
            if (selected != null) _PathBar(node: selected, onCopy: _copy),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final options = widget.options;
    final used = widget.result.arrayKeysUsed;
    final current = _currentTarget;
    final small = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        children: [
          // On a narrow window the options scroll rather than overflow.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  FilterChip(
                    label: const Text('Changes only'),
                    selected: _changesOnly,
                    visualDensity: VisualDensity.compact,
                    onSelected: (v) => setState(() {
                      _changesOnly = v;
                      _rows = null;
                    }),
                  ),
                  const SizedBox(width: 6),
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
                  const SizedBox(width: 12),
                  Text('Arrays', style: small),
                  const SizedBox(width: 8),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('By position'),
                        tooltip: 'Element 0 matches element 0, and so on',
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text('By key'),
                        tooltip: 'Match objects in arrays by an id-like key, '
                            'wherever they moved',
                      ),
                    ],
                    selected: {options.matchArraysByKey},
                    onSelectionChanged: (s) => widget.onOptionsChanged(
                        TreeDiffOptions(
                            matchArraysByKey: s.first,
                            arrayKey: options.arrayKey)),
                  ),
                  if (options.matchArraysByKey) ...[
                    const SizedBox(width: 6),
                    _KeyPicker(
                      value: options.arrayKey,
                      used: used,
                      onChanged: (key) => widget.onOptionsChanged(
                          TreeDiffOptions(
                              matchArraysByKey: true, arrayKey: key)),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_targets.isNotEmpty) ...[
            Text(
              current < 0
                  ? '${_targets.length} changes'
                  : '${current + 1} / ${_targets.length}',
              style: small,
            ),
            IconButton(
              tooltip: 'Previous change (${AppAction.previousChange.keyLabel})',
              onPressed: current > 0 || current < 0 ? () => _go(-1) : null,
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: 'Next change (${AppAction.nextChange.keyLabel})',
              onPressed: current < _targets.length - 1 ? () => _go(1) : null,
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
          ],
        ],
      ),
    );
  }
}

/// Picks the key arrays of objects match by: automatic, a common one, or
/// any key the user types.
class _KeyPicker extends StatelessWidget {
  const _KeyPicker({
    required this.value,
    required this.used,
    required this.onChanged,
  });

  final String? value;
  final Set<String> used;
  final ValueChanged<String?> onChanged;

  Future<void> _askCustom(BuildContext context) async {
    final controller = TextEditingController(text: value ?? '');
    final key = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Match array items by'),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Key',
              hintText: 'e.g. sku',
            ),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Match')),
        ],
      ),
    );
    controller.dispose();
    if (key != null) onChanged(key.isEmpty ? null : key);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = value == null
        ? (used.isEmpty ? 'Auto: no key found' : 'Auto: ${used.join(', ')}')
        : used.contains(value)
            ? value!
            : '$value (not found)';
    return PopupMenuButton<String>(
      tooltip: 'The key to match by',
      onSelected: (v) {
        if (v == '\u0000auto') {
          onChanged(null);
        } else if (v == '\u0000custom') {
          _askCustom(context);
        } else {
          onChanged(v);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
            value: '\u0000auto', child: Text('Automatic (id, key or name)')),
        const PopupMenuDivider(),
        for (final k in TreeDiffOptions.autoKeys)
          PopupMenuItem(value: k, child: Text(k)),
        const PopupMenuItem(value: '\u0000custom', child: Text('Other key…')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.key, size: 14, color: scheme.primary),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12.5)),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

class _TreeRow extends StatefulWidget {
  const _TreeRow({
    required this.node,
    required this.depth,
    required this.expanded,
    required this.selected,
    required this.onTap,
    required this.onCopyPath,
    required this.onContextMenu,
  });

  final TreeDiffNode node;
  final int depth;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onCopyPath;
  final ValueChanged<Offset> onContextMenu;

  @override
  State<_TreeRow> createState() => _TreeRowState();
}

class _TreeRowState extends State<_TreeRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final depth = widget.depth;
    final expanded = widget.expanded;
    final selected = widget.selected;
    final hovered = _hovered;
    final scheme = Theme.of(context).colorScheme;
    final palette = DiffPalette.of(context);
    final (Color bg, Color fg, String glyph) = switch (node.status) {
      TreeStatus.added => (palette.addedBg, palette.added, '+'),
      TreeStatus.removed => (palette.removedBg, palette.removed, '−'),
      TreeStatus.changed => (palette.modifiedBg, palette.modified, '~'),
      TreeStatus.nested => (Colors.transparent, palette.modified, ''),
      TreeStatus.same => (Colors.transparent, scheme.onSurfaceVariant, ''),
    };
    final muted = node.status == TreeStatus.same;
    final keyStyle = monoStyle.copyWith(
      fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
      color: muted ? scheme.onSurfaceVariant : scheme.onSurface,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapUp: (d) => widget.onContextMenu(d.globalPosition),
        child: Container(
          color: selected
              ? Color.alphaBlend(
                  scheme.primaryContainer.withValues(alpha: 0.6), bg)
              : hovered
                  ? Color.alphaBlend(
                      scheme.surfaceContainerHighest.withValues(alpha: 0.5), bg)
                  : bg,
          padding: const EdgeInsets.only(left: 12, right: 8),
          child: Row(
            children: [
              for (var i = 0; i < depth; i++)
                SizedBox(
                  width: _indent,
                  child: Center(
                    child: Container(
                      width: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              SizedBox(
                width: 18,
                child: node.children.isEmpty
                    ? null
                    : AnimatedRotation(
                        turns: expanded ? 0.25 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: Icon(Icons.chevron_right,
                            size: 18, color: scheme.onSurfaceVariant),
                      ),
              ),
              SizedBox(
                width: 16,
                child: Text(glyph,
                    textAlign: TextAlign.center,
                    style: monoStyle.copyWith(
                        fontWeight: FontWeight.w700, color: fg)),
              ),
              const SizedBox(width: 4),
              Flexible(
                flex: 0,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(node.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: keyStyle),
                ),
              ),
              if (node.matchedBy != null)
                _Tag(text: node.matchedBy!, color: scheme.primary),
              if (node.movedFrom != null)
                _Tag(
                    text: 'moved from [${node.movedFrom}]',
                    color: scheme.tertiary),
              Text(':  ',
                  style: monoStyle.copyWith(color: scheme.onSurfaceVariant)),
              Expanded(child: _value(context, palette, scheme)),
              if (node.status == TreeStatus.nested) ...[
                if (node.added > 0) _Count('+${node.added}', palette.added),
                if (node.removed > 0)
                  _Count('−${node.removed}', palette.removed),
                if (node.changed > 0)
                  _Count('~${node.changed}', palette.modified),
              ],
              SizedBox(
                width: 30,
                child: hovered || selected
                    ? IconButton(
                        tooltip: 'Copy path ${node.path}',
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        iconSize: 15,
                        onPressed: widget.onCopyPath,
                        icon: const Icon(Icons.content_copy),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _value(BuildContext context, DiffPalette palette, ColorScheme scheme) {
    final node = widget.node;
    final base = monoStyle;
    final summary = node.isContainer;
    switch (node.status) {
      case TreeStatus.changed:
        return Text.rich(
          TextSpan(children: [
            TextSpan(
              text: describeValue(node.oldValue),
              style: TextStyle(
                color: palette.removed,
                decoration: TextDecoration.lineThrough,
                decorationColor: palette.removed.withValues(alpha: 0.6),
              ),
            ),
            TextSpan(
                text: '  →  ',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            TextSpan(
                text: describeValue(node.newValue),
                style: TextStyle(color: palette.added)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: base,
        );
      case TreeStatus.added:
      case TreeStatus.removed:
        final added = node.status == TreeStatus.added;
        return Text(
          describeValue(node.value),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: base.copyWith(
            color: summary
                ? scheme.onSurfaceVariant
                : (added ? palette.added : palette.removed),
            decoration: added || summary ? null : TextDecoration.lineThrough,
            decorationColor: palette.removed.withValues(alpha: 0.6),
          ),
        );
      case TreeStatus.nested:
      case TreeStatus.same:
        return Text(
          describeValue(node.value),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: base.copyWith(
              color: summary
                  ? scheme.onSurfaceVariant.withValues(alpha: 0.8)
                  : scheme.onSurfaceVariant),
        );
    }
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child:
          Text(text, maxLines: 1, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(text,
          style: monoStyle.copyWith(
              fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

/// The selected node's path, ready to copy, with its values.
class _PathBar extends StatelessWidget {
  const _PathBar({required this.node, required this.onCopy});

  final TreeDiffNode node;
  final void Function(String text, String what) onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final removed = node.status == TreeStatus.removed;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5))),
      ),
      child: Row(
        children: [
          Text(removed ? 'Path in the left file' : 'Path',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              node.path,
              maxLines: 1,
              style: monoStyle.copyWith(fontSize: 12.5),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => onCopy(node.path, node.path),
            icon: const Icon(Icons.content_copy, size: 15),
            label: const Text('Copy path'),
          ),
          if (node.status == TreeStatus.changed) ...[
            TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () =>
                  onCopy(valueToText(node.oldValue), 'the left value'),
              child: const Text('Copy left'),
            ),
            TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () =>
                  onCopy(valueToText(node.newValue), 'the right value'),
              child: const Text('Copy right'),
            ),
          ],
        ],
      ),
    );
  }
}

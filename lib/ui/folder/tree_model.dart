/// What the folder tree shows: which entries pass the filter and the name
/// search, in which order, and which folders are open. Rows are computed
/// once per change and cached, so moving the selection through a tree of
/// a hundred thousand entries costs nothing.
library;

import '../../compare/folder_compare.dart';
import '../../compare/folder_format.dart';
import '../../settings/app_settings.dart';

enum TreeFilter {
  all('All entries'),
  changes('Changes only'),
  leftOnly('Left only'),
  rightOnly('Right only');

  const TreeFilter(this.label);

  final String label;

  static TreeFilter fromSetting(FolderFilterDefault value) => switch (value) {
        FolderFilterDefault.all => all,
        FolderFilterDefault.changes => changes,
        FolderFilterDefault.leftOnly => leftOnly,
        FolderFilterDefault.rightOnly => rightOnly,
      };
}

enum SortColumn { name, size, modified }

/// Sort order of the tree. Folders always come before files. Size and
/// date sort by the [side] whose column header was clicked, falling back
/// to the other side where the entry is missing.
class TreeSort {
  const TreeSort(this.column, {this.ascending = true, this.side = Side.left});

  static const byName = TreeSort(SortColumn.name);

  final SortColumn column;
  final bool ascending;
  final Side side;

  bool get isDefault => column == SortColumn.name && ascending;

  int compare(CompareNode a, CompareNode b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    final c = switch (column) {
      SortColumn.name => 0,
      SortColumn.size => _cmp(a.sizeOn(side) ?? a.sizeOn(side.other),
          b.sizeOn(side) ?? b.sizeOn(side.other)),
      SortColumn.modified => _cmp(
          a.modifiedOn(side) ?? a.modifiedOn(side.other),
          b.modifiedOn(side) ?? b.modifiedOn(side.other)),
    };
    final byName = c != 0 ? c : compareNatural(a.name, b.name);
    return ascending ? byName : -byName;
  }

  /// Missing values sort first ascending.
  static int _cmp<T extends Comparable<Object>>(T? a, T? b) {
    if (a == null) return b == null ? 0 : -1;
    if (b == null) return 1;
    return a.compareTo(b);
  }

  @override
  bool operator ==(Object other) =>
      other is TreeSort &&
      other.column == column &&
      other.ascending == ascending &&
      other.side == side;

  @override
  int get hashCode => Object.hash(column, ascending, side);
}

typedef TreeRow = ({CompareNode node, int depth});

class FolderTreeModel {
  CompareNode? _root;
  var _byPath = <String, CompareNode>{};

  TreeFilter _filter = TreeFilter.changes;
  String _query = '';
  TreeSort _sort = TreeSort.byName;

  /// Open folders, by path. Kept across rescans.
  final expanded = <String>{};

  /// Folders the user closed while a search had them open.
  final _closedInSearch = <String>{};

  List<TreeRow>? _rows;
  Map<String, int>? _rowIndex;
  Set<CompareNode>? _hits;
  final _sorted = <CompareNode, List<CompareNode>>{};

  CompareNode? get root => _root;
  TreeFilter get filter => _filter;
  String get query => _query;
  TreeSort get sort => _sort;

  set root(CompareNode? root) {
    _root = root;
    _byPath = {};
    if (root != null) _index(root);
    _sorted.clear();
    _hits = null;
    _invalidate();
  }

  void _index(CompareNode node) {
    _byPath[node.relativePath] = node;
    if (!node.isDirectory) return;
    for (final child in node.children) {
      _index(child);
    }
  }

  set filter(TreeFilter value) {
    if (value == _filter) return;
    _filter = value;
    _hits = null;
    _invalidate();
  }

  set query(String value) {
    final q = value.trim().toLowerCase();
    if (q == _query) return;
    _query = q;
    _hits = null;
    _closedInSearch.clear();
    _invalidate();
  }

  set sort(TreeSort value) {
    if (value == _sort) return;
    _sort = value;
    _sorted.clear();
    _invalidate();
  }

  void _invalidate() {
    _rows = null;
    _rowIndex = null;
  }

  /// Call after changing [expanded] directly.
  void expansionChanged() => _invalidate();

  CompareNode? nodeAt(String path) => _byPath[path];

  bool contains(String path) => _byPath.containsKey(path);

  List<TreeRow> get rows => _rows ??= _build();

  int indexOf(String path) {
    final index = _rowIndex ??= {
      for (var i = 0; i < rows.length; i++) rows[i].node.relativePath: i,
    };
    return index[path] ?? -1;
  }

  bool get searching => _query.isNotEmpty;

  bool isExpanded(CompareNode node) {
    if (!node.isDirectory) return false;
    if (searching && _hitsSet.contains(node) && !_nameHit(node)) {
      return !_closedInSearch.contains(node.relativePath);
    }
    return expanded.contains(node.relativePath);
  }

  void setExpanded(CompareNode node, bool open) {
    if (!node.isDirectory) return;
    if (searching && _hitsSet.contains(node) && !_nameHit(node)) {
      open
          ? _closedInSearch.remove(node.relativePath)
          : _closedInSearch.add(node.relativePath);
    } else {
      open
          ? expanded.add(node.relativePath)
          : expanded.remove(node.relativePath);
    }
    _invalidate();
  }

  void expandAll() {
    _closedInSearch.clear();
    for (final node in _byPath.values) {
      if (node.isDirectory && node.relativePath.isNotEmpty) {
        expanded.add(node.relativePath);
      }
    }
    _invalidate();
  }

  void collapseAll() {
    expanded.clear();
    if (searching) {
      for (final node in _hitsSet) {
        if (node.isDirectory) _closedInSearch.add(node.relativePath);
      }
    }
    _invalidate();
  }

  /// Opens the folders above [path] so its row shows.
  void reveal(String path) {
    var i = path.lastIndexOf('/');
    while (i > 0) {
      final node = _byPath[path.substring(0, i)];
      if (node != null && !isExpanded(node)) setExpanded(node, true);
      i = path.lastIndexOf('/', i - 1);
    }
  }

  /// The status filter alone.
  bool passesFilter(CompareNode node) => switch (_filter) {
        TreeFilter.all => true,
        TreeFilter.changes => node.hasChanges,
        TreeFilter.leftOnly => node.isDirectory
            ? node.onlyLeftCount > 0 || node.status == EntryStatus.onlyLeft
            : node.status == EntryStatus.onlyLeft,
        TreeFilter.rightOnly => node.isDirectory
            ? node.onlyRightCount > 0 || node.status == EntryStatus.onlyRight
            : node.status == EntryStatus.onlyRight,
      };

  /// The filter and the search together, as shown (used for exports).
  bool isShown(CompareNode node) =>
      passesFilter(node) && (!searching || _visibleInSearch(node));

  bool _visibleInSearch(CompareNode node) {
    if (_hitsSet.contains(node)) return true;
    // Inside a folder whose name matched, everything shows.
    var i = node.relativePath.lastIndexOf('/');
    while (i > 0) {
      final parent = _byPath[node.relativePath.substring(0, i)];
      if (parent != null && _nameHit(parent)) return true;
      i = node.relativePath.lastIndexOf('/', i - 1);
    }
    return false;
  }

  bool _nameHit(CompareNode node) => node.name.toLowerCase().contains(_query);

  /// Entries whose name matches the search, and folders holding one.
  Set<CompareNode> get _hitsSet => _hits ??= _collectHits();

  Set<CompareNode> _collectHits() {
    final hits = <CompareNode>{};
    final root = _root;
    if (root == null || !searching) return hits;
    bool visit(CompareNode node) {
      var hit = _nameHit(node);
      if (node.isDirectory) {
        for (final child in node.children) {
          if (passesFilter(child) && visit(child)) hit = true;
        }
      }
      if (hit) hits.add(node);
      return hit;
    }

    for (final child in root.children) {
      if (passesFilter(child)) visit(child);
    }
    return hits;
  }

  List<CompareNode> childrenOf(CompareNode node) {
    if (_sort.isDefault) return node.children; // the scan's own order
    return _sorted[node] ??= List.of(node.children)..sort(_sort.compare);
  }

  List<TreeRow> _build() {
    final out = <TreeRow>[];
    final root = _root;
    if (root == null) return out;
    void walk(CompareNode node, int depth, bool insideHit) {
      for (final child in childrenOf(node)) {
        if (!passesFilter(child)) continue;
        if (searching && !insideHit && !_hitsSet.contains(child)) continue;
        out.add((node: child, depth: depth));
        if (child.isDirectory && isExpanded(child)) {
          walk(child, depth + 1,
              insideHit || (searching && _nameHit(child)));
        }
      }
    }

    walk(root, 0, false);
    return out;
  }
}

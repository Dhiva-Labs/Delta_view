/// A key-aware diff of two JSON / YAML documents: object keys match by
/// name whatever their order, arrays by position or, optionally, by an
/// id-like key of their objects.
///
/// Pure Dart; runs in an isolate for big documents.
library;

import 'dart:convert';

import 'structured_parse.dart';

enum TreeStatus {
  /// The same on both sides.
  same,

  /// Only on the right.
  added,

  /// Only on the left.
  removed,

  /// A value that differs (or changed type, say object → array).
  changed,

  /// An object or array that is on both sides with changes inside.
  nested,
}

enum TreeKind { object, array, scalar }

TreeKind kindOf(Object? value) => value is Map
    ? TreeKind.object
    : value is List
        ? TreeKind.array
        : TreeKind.scalar;

class TreeDiffOptions {
  const TreeDiffOptions({this.matchArraysByKey = false, this.arrayKey});

  /// Match arrays of objects by [arrayKey] instead of by position.
  final bool matchArraysByKey;

  /// The key to match by; null tries [autoKeys] in order, per array.
  final String? arrayKey;

  static const autoKeys = ['id', 'key', 'name'];

  @override
  bool operator ==(Object other) =>
      other is TreeDiffOptions &&
      other.matchArraysByKey == matchArraysByKey &&
      other.arrayKey == arrayKey;

  @override
  int get hashCode => Object.hash(matchArraysByKey, arrayKey);
}

class TreeDiffNode {
  TreeDiffNode({
    required this.label,
    required this.path,
    required this.status,
    required this.oldValue,
    required this.newValue,
    this.children = const [],
    this.matchedBy,
    this.movedFrom,
  });

  /// The key or `[index]` this node sits at; `$` for the root.
  final String label;

  /// JSONPath-style location, e.g. `$.server.ports[2]`. Array indexes are
  /// the right side's, or the left side's for removed elements.
  final String path;
  final TreeStatus status;

  /// [Absent.value] on the side the node is missing from.
  final Object? oldValue;
  final Object? newValue;
  final List<TreeDiffNode> children;

  /// For arrays matched by key: `id: 42`.
  final String? matchedBy;

  /// For arrays matched by key: the left index when the element moved.
  final int? movedFrom;

  int added = 0, removed = 0, changed = 0;

  bool get hasChanges => status != TreeStatus.same;
  int get changeCount => added + removed + changed;

  /// The value shown for the node: the new one unless it was removed.
  Object? get value => status == TreeStatus.removed ? oldValue : newValue;

  TreeKind get kind => kindOf(value);

  bool get isContainer =>
      status != TreeStatus.changed && kind != TreeKind.scalar;
}

class TreeDiffResult {
  const TreeDiffResult(this.root, {this.arrayKeysUsed = const {}});

  final TreeDiffNode root;

  /// Keys the arrays were matched by, for the "by key" picker.
  final Set<String> arrayKeysUsed;
}

/// Diffs two parsed documents ([parseTree] output; [Absent.value] for a
/// missing one).
TreeDiffResult diffTrees(Object? left, Object? right,
    [TreeDiffOptions options = const TreeDiffOptions()]) {
  final used = <String>{};
  final root = _diff(r'$', r'$', left, right, options, used);
  return TreeDiffResult(root, arrayKeysUsed: used);
}

TreeDiffNode _diff(String label, String path, Object? left, Object? right,
    TreeDiffOptions options, Set<String> used,
    {String? matchedBy, int? movedFrom}) {
  if (identical(left, Absent.value)) {
    return _oneSided(label, path, right, added: true, matchedBy: matchedBy);
  }
  if (identical(right, Absent.value)) {
    return _oneSided(label, path, left, added: false, matchedBy: matchedBy);
  }
  final lk = kindOf(left), rk = kindOf(right);
  if (lk != rk || lk == TreeKind.scalar) {
    final same = lk == rk && _scalarEquals(left, right);
    final node = TreeDiffNode(
      label: label,
      path: path,
      status: same ? TreeStatus.same : TreeStatus.changed,
      oldValue: left,
      newValue: right,
      matchedBy: matchedBy,
      movedFrom: movedFrom,
    );
    if (!same) node.changed = 1;
    return node;
  }

  final children = lk == TreeKind.object
      ? _diffObjects(path, left as Map, right as Map, options, used)
      : _diffArrays(path, left as List, right as List, options, used);
  final node = TreeDiffNode(
    label: label,
    path: path,
    status:
        children.any((c) => c.hasChanges) ? TreeStatus.nested : TreeStatus.same,
    oldValue: left,
    newValue: right,
    children: children,
    matchedBy: matchedBy,
    movedFrom: movedFrom,
  );
  for (final c in children) {
    node.added += c.added;
    node.removed += c.removed;
    node.changed += c.changed;
  }
  return node;
}

/// A subtree on one side only. Its children are listed too, so the view
/// can expand it, but the whole subtree counts as one addition or removal.
TreeDiffNode _oneSided(String label, String path, Object? value,
    {required bool added, String? matchedBy}) {
  List<TreeDiffNode> children = const [];
  if (value is Map) {
    children = [
      for (final e in value.entries)
        _oneSided('${e.key}', _childPath(path, '${e.key}'), e.value,
            added: added),
    ];
  } else if (value is List) {
    children = [
      for (var i = 0; i < value.length; i++)
        _oneSided('[$i]', '$path[$i]', value[i], added: added),
    ];
  }
  final node = TreeDiffNode(
    label: label,
    path: path,
    status: added ? TreeStatus.added : TreeStatus.removed,
    oldValue: added ? Absent.value : value,
    newValue: added ? value : Absent.value,
    children: children,
    matchedBy: matchedBy,
  );
  if (added) {
    node.added = 1;
  } else {
    node.removed = 1;
  }
  return node;
}

List<TreeDiffNode> _diffObjects(String path, Map left, Map right,
    TreeDiffOptions options, Set<String> used) {
  // Left's order, then keys only the right has, in its order.
  final keys = [
    ...left.keys,
    for (final k in right.keys)
      if (!left.containsKey(k)) k,
  ];
  return [
    for (final k in keys)
      _diff(
        '$k',
        _childPath(path, '$k'),
        left.containsKey(k) ? left[k] : Absent.value,
        right.containsKey(k) ? right[k] : Absent.value,
        options,
        used,
      ),
  ];
}

List<TreeDiffNode> _diffArrays(String path, List left, List right,
    TreeDiffOptions options, Set<String> used) {
  final key = options.matchArraysByKey
      ? _matchKey(left, right, options.arrayKey)
      : null;
  if (key == null) {
    final n = left.length > right.length ? left.length : right.length;
    return [
      for (var i = 0; i < n; i++)
        _diff(
          '[$i]',
          '$path[$i]',
          i < left.length ? left[i] : Absent.value,
          i < right.length ? right[i] : Absent.value,
          options,
          used,
        ),
    ];
  }
  used.add(key);

  final leftIndex = <Object?, int>{
    for (var i = 0; i < left.length; i++) _keyValue(left[i], key): i,
  };
  final matchedLeft = <int>{};
  // Right's order; each removed element follows the element that came
  // before it on the left, so it shows up roughly where it was.
  final out = <TreeDiffNode>[];
  final afterLeft = <int, List<TreeDiffNode>>{};
  final rightNodes = <(int?, TreeDiffNode)>[];
  for (var r = 0; r < right.length; r++) {
    final kv = _keyValue(right[r], key);
    final l = leftIndex[kv];
    final match = '$key: ${_preview(kv)}';
    if (l == null) {
      rightNodes.add((
        null,
        _oneSided('[$r]', '$path[$r]', right[r], added: true, matchedBy: match)
      ));
    } else {
      matchedLeft.add(l);
      rightNodes.add((
        l,
        _diff('[$r]', '$path[$r]', left[l], right[r], options, used,
            matchedBy: match, movedFrom: l == r ? null : l),
      ));
    }
  }
  final leading = <TreeDiffNode>[];
  int? anchor;
  for (var l = 0; l < left.length; l++) {
    if (matchedLeft.contains(l)) {
      anchor = l;
      continue;
    }
    final node = _oneSided('[$l]', '$path[$l]', left[l],
        added: false, matchedBy: '$key: ${_preview(_keyValue(left[l], key))}');
    if (anchor == null) {
      leading.add(node);
    } else {
      (afterLeft[anchor] ??= []).add(node);
    }
  }
  out.addAll(leading);
  for (final (l, node) in rightNodes) {
    out.add(node);
    if (l != null) out.addAll(afterLeft[l] ?? const []);
  }
  return out;
}

/// The key to match two arrays by: every element on both sides is an
/// object with that key, holding a scalar, unique within its side. Null
/// when no key qualifies (then the arrays match by position).
String? _matchKey(List left, List right, String? preferred) {
  if (left.isEmpty && right.isEmpty) return null;
  final candidates = preferred == null || preferred.isEmpty
      ? TreeDiffOptions.autoKeys
      : [preferred];
  for (final key in candidates) {
    if (_qualifies(left, key) && _qualifies(right, key)) return key;
  }
  return null;
}

bool _qualifies(List items, String key) {
  final seen = <Object?>{};
  for (final item in items) {
    if (item is! Map || !item.containsKey(key)) return false;
    final v = item[key];
    if (v is Map || v is List) return false;
    if (!seen.add(_keyValue(item, key))) return false;
  }
  return true;
}

/// Key values compare by JSON text, so 1 and "1" stay different keys.
Object? _keyValue(Object? item, String key) {
  final value = (item as Map)[key];
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    return '$value'; // YAML's .inf and .nan have no JSON form.
  }
}

String _preview(Object? jsonText) => '$jsonText';

final _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

String _childPath(String path, String key) => _identifier.hasMatch(key)
    ? '$path.$key'
    : "$path['${key.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}']";

bool _scalarEquals(Object? a, Object? b) {
  // 1 and 1.0 are the same number in JSON.
  if (a is num && b is num) return a == b;
  return a.runtimeType == b.runtimeType && a == b;
}

/// One line of text for a value: scalars as JSON, containers summarised.
String describeValue(Object? value, {int maxLength = 120}) {
  if (identical(value, Absent.value)) return '';
  String text;
  if (value is Map) {
    text = value.isEmpty
        ? '{}'
        : '{${value.length} ${value.length == 1 ? 'key' : 'keys'}}';
  } else if (value is List) {
    text = value.isEmpty
        ? '[]'
        : '[${value.length} ${value.length == 1 ? 'item' : 'items'}]';
  } else {
    try {
      text = jsonEncode(value);
    } on JsonUnsupportedObjectError {
      text = '$value';
    }
  }
  return text.length > maxLength ? '${text.substring(0, maxLength)}…' : text;
}

/// The value as pretty JSON, for "copy value".
String valueToText(Object? value) {
  if (identical(value, Absent.value)) return '';
  if (value is String) return value;
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } on JsonUnsupportedObjectError {
    return '$value';
  }
}

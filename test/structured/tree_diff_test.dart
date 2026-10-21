import 'dart:convert';

import 'package:delta_view/diff/structured/structured_compare.dart';
import 'package:flutter_test/flutter_test.dart';

TreeDiffNode diff(Object? a, Object? b,
        [TreeDiffOptions options = const TreeDiffOptions()]) =>
    diffTrees(a, b, options).root;

TreeDiffNode child(TreeDiffNode node, String label) =>
    node.children.singleWhere((c) => c.label == label);

/// Every node with changes of its own (not just nested ones), by path.
Map<String, TreeStatus> changes(TreeDiffNode node) => {
      if (node.status != TreeStatus.same && node.status != TreeStatus.nested)
        node.path: node.status,
      if (node.status == TreeStatus.nested || node.status == TreeStatus.same)
        for (final c in node.children) ...changes(c),
    };

void main() {
  group('diffTrees', () {
    test('object keys match by name, whatever their order', () {
      final root = diff(jsonDecode('{"a": 1, "b": {"c": true}}'),
          jsonDecode('{"b": {"c": true}, "a": 1}'));
      expect(root.status, TreeStatus.same);
      expect(root.changeCount, 0);
    });

    test('added, removed and changed values with paths and counts', () {
      final root = diff(
        jsonDecode('{"name": "x", "server": {"host": "a", "port": 80}, '
            '"debug": true}'),
        jsonDecode('{"name": "x", "server": {"host": "b", "port": 80, '
            '"tls": {"on": true}}}'),
      );
      expect(root.status, TreeStatus.nested);
      expect(changes(root), {
        r'$.server.host': TreeStatus.changed,
        r'$.server.tls': TreeStatus.added,
        r'$.debug': TreeStatus.removed,
      });
      expect((root.added, root.removed, root.changed), (1, 1, 1));
      final host = child(child(root, 'server'), 'host');
      expect((host.oldValue, host.newValue), ('a', 'b'));
      // An added subtree counts once but can still be expanded.
      final tls = child(child(root, 'server'), 'tls');
      expect(tls.children.single.status, TreeStatus.added);
      expect(child(root, 'server').changeCount, 2);
    });

    test('arrays match by index by default', () {
      final root = diff([1, 2, 3], [1, 5, 3, 4]);
      expect(changes(root), {
        r'$[1]': TreeStatus.changed,
        r'$[3]': TreeStatus.added,
      });
    });

    test('arrays of objects match by an id-like key when asked', () {
      final left = jsonDecode('[{"id": 1, "v": "a"}, {"id": 2, "v": "b"}, '
          '{"id": 3, "v": "c"}]');
      final right = jsonDecode('[{"id": 3, "v": "C"}, {"id": 1, "v": "a"}, '
          '{"id": 4, "v": "d"}]');

      final byIndex = diff(left, right);
      expect(byIndex.changed, greaterThan(1));

      final result =
          diffTrees(left, right, const TreeDiffOptions(matchArraysByKey: true));
      final root = result.root;
      expect(result.arrayKeysUsed, {'id'});
      expect(changes(root), {
        r'$[0].v': TreeStatus.changed, // id 3, now first
        r'$[1]': TreeStatus.removed, // id 2, was at index 1
        r'$[2]': TreeStatus.added, // id 4
      });
      expect([for (final c in root.children) c.matchedBy],
          ['id: 3', 'id: 1', 'id: 2', 'id: 4']);
      // id 3 moved from index 2; id 1 from index 0.
      expect(root.children[0].movedFrom, 2);
      expect(root.children[1].movedFrom, 0);
    });

    test('auto key falls back to "key" and "name", or to position', () {
      final byName = diffTrees(
        [
          {'name': 'a', 'v': 1},
          {'name': 'b', 'v': 2},
        ],
        [
          {'name': 'b', 'v': 2},
          {'name': 'a', 'v': 1},
        ],
        const TreeDiffOptions(matchArraysByKey: true),
      );
      expect(byName.root.status, TreeStatus.same);
      expect(byName.arrayKeysUsed, {'name'});

      // Duplicate keys do not qualify: back to positions.
      final duplicates = diffTrees(
        [
          {'id': 1},
          {'id': 1, 'x': 0},
        ],
        [
          {'id': 1, 'x': 0},
          {'id': 1},
        ],
        const TreeDiffOptions(matchArraysByKey: true),
      );
      expect(duplicates.arrayKeysUsed, isEmpty);
      expect(duplicates.root.status, TreeStatus.nested);
    });

    test('a user-picked key', () {
      final result = diffTrees(
        [
          {'sku': 'x', 'id': 2},
          {'sku': 'y', 'id': 1},
        ],
        [
          {'sku': 'y', 'id': 1},
          {'sku': 'x', 'id': 3},
        ],
        const TreeDiffOptions(matchArraysByKey: true, arrayKey: 'sku'),
      );
      expect(result.arrayKeysUsed, {'sku'});
      expect(changes(result.root), {r'$[1].id': TreeStatus.changed});
    });

    test('type changes and number equality', () {
      final root = diff({
        'a': 1,
        'b': '1',
        'c': [1],
        'd': 1.0
      }, {
        'a': 1.0,
        'b': 1,
        'c': {'0': 1},
        'd': 1
      });
      expect(changes(root), {
        r'$.b': TreeStatus.changed,
        r'$.c': TreeStatus.changed,
      });
    });

    test('paths quote keys that are not identifiers', () {
      final root = diff({'a b': 1, "it's": 1}, {'a b': 2, "it's": 2});
      expect(changes(root).keys, [r"$['a b']", r"$['it\'s']"]);
    });

    test('a missing document is all added', () {
      final root = diff(Absent.value, {'a': 1});
      expect(root.status, TreeStatus.added);
      expect(root.added, 1);
      expect(root.children.single.path, r'$.a');
    });
  });

  group('parseTree', () {
    test('reads YAML with any key order and plain values', () {
      final left = parseTree('a: 1\nb:\n  - x\n  - y\n', StructuredFormat.yaml);
      final right =
          parseTree('{"b": ["x", "y"], "a": 1}', StructuredFormat.json);
      expect(left, {
        'a': 1,
        'b': ['x', 'y'],
      });
      expect(diff(left, right).status, TreeStatus.same);
    });

    test('JSON errors say where they are', () {
      expect(
        () => parseTree(
            '{\n  "a": 1,\n  "b": [1, 2,,]\n}', StructuredFormat.json),
        throwsA(isA<StructuredParseException>()
            .having((e) => e.line, 'line', 3)
            .having((e) => e.column, 'column', 14)),
      );
    });

    test('YAML errors say where they are', () {
      expect(
        () => parseTree('a: 1\nb: [1, 2\nc: 3\n', StructuredFormat.yaml),
        throwsA(isA<StructuredParseException>()
            .having((e) => e.line, 'line', isNotNull)),
      );
    });

    test('blank text is an absent document, and BOMs are dropped', () {
      expect(parseTree('  \n', StructuredFormat.json), same(Absent.value));
      expect(decodeText([0xEF, 0xBB, 0xBF, 0x7B, 0x7D]), '{}');
      expect(decodeText([0x63, 0x61, 0x66, 0xE9]), 'café');
    });

    test('several YAML documents become a list', () {
      expect(parseTree('a: 1\n---\nb: 2\n', StructuredFormat.yaml), [
        {'a': 1},
        {'b': 2},
      ]);
    });
  });

  test('compareStructured reports which side failed to parse', () {
    final outcome = compareStructured(
      leftText: '{}',
      rightText: '{"a": ',
      leftFormat: StructuredFormat.json,
      rightFormat: StructuredFormat.json,
    );
    expect(outcome, isA<ParseFailure>());
    expect((outcome as ParseFailure).leftSide, isFalse);
    expect(
      compareStructured(
        leftText: 'a,b',
        rightText: '{}',
        leftFormat: StructuredFormat.csv,
        rightFormat: StructuredFormat.json,
      ),
      isA<FormatMismatch>(),
    );
  });

  test('describeValue summarises containers', () {
    expect(describeValue({'a': 1, 'b': 2}), '{2 keys}');
    expect(describeValue([1]), '[1 item]');
    expect(describeValue('hi'), '"hi"');
    expect(describeValue(null), 'null');
    expect(describeValue(Absent.value), '');
  });
}

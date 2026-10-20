import 'package:delta_view/compare/folder_compare.dart';
import 'package:delta_view/compare/folder_report.dart';
import 'package:flutter_test/flutter_test.dart';

import 'memory_source.dart';

Future<FolderReport> _report({bool Function(CompareNode)? include}) async {
  final left = MemorySource({}, name: 'L')
    ..put('src/<b>&"x".txt', 'one\n', modified: DateTime(2026, 10, 21, 14, 5))
    ..put('same.txt', 's')
    ..put('=cmd.csv', 'l');
  final right = MemorySource({}, name: 'R')
    ..put('src/<b>&"x".txt', 'two\n')
    ..put('same.txt', 's')
    ..put('new, file.txt', 'r');
  final result = await FolderScanner(left, right).run();
  return FolderReport(
    result: result,
    leftDescription: '/home/me/left',
    rightDescription: 'me@host:/srv/right',
    generated: DateTime(2026, 10, 21, 15),
    include: include,
  );
}

void main() {
  test('rows follow the tree and honour the filter', () async {
    final all = await _report();
    expect(all.rows().map((r) => '${r.$2}:${r.$1.name}'), [
      '0:src',
      '1:<b>&"x".txt',
      '0:=cmd.csv',
      '0:new, file.txt',
      '0:same.txt',
    ]);
    final changes = await _report(include: (n) => n.hasChanges);
    expect(changes.rows().map((r) => r.$1.name), isNot(contains('same.txt')));
  });

  test('HTML is self-contained, escaped and labelled', () async {
    final html = (await _report()).toHtml();
    expect(html, startsWith('<!doctype html>'));
    expect(html, contains('<style>'));
    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('http://')));
    expect(html, isNot(contains('https://')));
    expect(html, contains('&lt;b&gt;&amp;&quot;x&quot;.txt'));
    expect(html, isNot(contains('<b>&')));
    expect(html, contains('/home/me/left'));
    expect(html, contains('me@host:/srv/right'));
    // Status in words and symbols, not colour alone.
    expect(html, contains('class="sr">modified</span>'));
    expect(html, contains('class="sr">left only</span>'));
    expect(html, contains('<span class="add">+1</span>'));
    expect(html, contains('2026-10-21 14:05'));
    expect(html, contains('prefers-color-scheme: dark'));
  });

  test('CSV quotes, neutralises formulas and uses CRLF', () async {
    final csv = (await _report()).toCsv();
    expect(csv, startsWith('﻿Path,Type,Status,'));
    final lines = csv.substring(1).split('\r\n');
    expect(lines.last, isEmpty, reason: 'ends with a line break');
    expect(lines[1], startsWith('src/,folder,modified,'));
    expect(lines[2],
        startsWith('"src/<b>&""x"".txt",file,modified,4,2026-10-21 14:05:00,4,'));
    expect(lines[2], endsWith(',1,1'));
    expect(lines[3], startsWith("'=cmd.csv,file,left only,1,"));
    expect(lines[4], startsWith('"new, file.txt",file,right only,,,1,'));
  });

  test('csvCell', () {
    expect(csvCell('plain'), 'plain');
    expect(csvCell('a,b'), '"a,b"');
    expect(csvCell('say "hi"'), '"say ""hi"""');
    expect(csvCell('two\nlines'), '"two\nlines"');
    expect(csvCell(' padded'), '" padded"');
    expect(csvCell('-1'), "'-1");
    expect(csvCell('@sum'), "'@sum");
  });
}

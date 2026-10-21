/// Exports a folder comparison as a self-contained HTML page (styled,
/// readable offline, light and dark) or as CSV for spreadsheets.
library;

import 'dart:convert';

import 'folder_compare.dart';
import 'folder_format.dart';

class FolderReport {
  FolderReport({
    required this.result,
    required this.leftDescription,
    required this.rightDescription,
    DateTime? generated,
    this.include,
    this.scopeLabel = 'All entries',
  }) : generated = generated ?? DateTime.now();

  final ScanResult result;
  final String leftDescription;
  final String rightDescription;
  final DateTime generated;

  /// Which entries to list (the view's current filter). A folder that is
  /// left out takes its contents with it. Null lists everything.
  final bool Function(CompareNode node)? include;

  /// Says which entries are listed, e.g. `Changes only`.
  final String scopeLabel;

  CompareNode get root => result.root;

  /// The listed entries in tree order, with their depth.
  List<(CompareNode, int)> rows() {
    final out = <(CompareNode, int)>[];
    void walk(CompareNode node, int depth) {
      for (final child in node.children) {
        if (include != null && !include!(child)) continue;
        out.add((child, depth));
        if (child.isDirectory) walk(child, depth + 1);
      }
    }

    walk(root, 0);
    return out;
  }

  String get _method => result.options.quick
      ? 'Quick (size and modification time)'
      : 'Full content';

  // ---- CSV ----

  /// RFC 4180 CSV with a header row, CRLF line ends and a byte order mark
  /// so spreadsheet apps read non-ASCII names correctly.
  String toCsv() {
    final out = StringBuffer('﻿');
    void line(List<Object?> cells) {
      out
        ..write(cells.map((c) => csvCell(c == null ? '' : '$c')).join(','))
        ..write('\r\n');
    }

    line([
      'Path', 'Type', 'Status', 'Left size', 'Left modified', 'Right size',
      'Right modified', 'Lines added', 'Lines removed',
    ]);
    for (final (node, _) in rows()) {
      line([
        node.isDirectory ? '${node.relativePath}/' : node.relativePath,
        _type(node),
        statusLabel(node.status),
        node.existsLeft ? node.leftSize : null,
        _csvDate(node.existsLeft ? node.leftModified : null),
        node.existsRight ? node.rightSize : null,
        _csvDate(node.existsRight ? node.rightModified : null),
        node.addedLines,
        node.removedLines,
      ]);
    }
    return out.toString();
  }

  static String _csvDate(DateTime? time) {
    if (time == null) return '';
    final t = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // ---- HTML ----

  String toHtml() {
    const esc = HtmlEscape(_textEscape);
    final root = this.root;
    final rows = this.rows();
    final out = StringBuffer();
    final title = 'Folder comparison: ${_tail(leftDescription)} ↔ '
        '${_tail(rightDescription)}';

    out.write('''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="DeltaView">
<title>${esc.convert(title)}</title>
<style>$_css</style>
</head>
<body>
<main>
<header>
<h1>Folder comparison</h1>
<p class="meta">Generated ${esc.convert(formatDateIso(generated))} by DeltaView
 · ${esc.convert(_method)} · ${esc.convert(scopeLabel)}</p>
<div class="paths">
<div class="path"><span class="side">Left</span>
${esc.convert(leftDescription)}</div>
<div class="arrow" aria-hidden="true">↔</div>
<div class="path"><span class="side">Right</span>
${esc.convert(rightDescription)}</div>
</div>
</header>
<section class="cards" aria-label="Summary">
${_card('modified', root.modifiedCount)}
${_card('left-only', root.onlyLeftCount)}
${_card('right-only', root.onlyRightCount)}
${_card('identical', root.identicalCount)}
</section>
''');
    if (result.ignoredCount > 0) {
      out.write('<p class="meta">${formatCount(result.ignoredCount)} '
          '${result.ignoredCount == 1 ? 'entry' : 'entries'} left out by '
          'ignore rules.</p>\n');
    }
    if (rows.isEmpty) {
      final empty = root.changedCount == 0
          ? 'The folders are identical.'
          : 'No entries to list.';
      out.write('<p class="empty">$empty</p>\n');
    } else {
      out.write('''<label class="toggle"><input type="checkbox" id="hide-identical">
 Hide identical entries</label>
<table>
<thead><tr>
<th class="st"><span class="sr">Status</span></th><th>Name</th>
<th class="num">Left size</th><th>Left modified</th>
<th class="num">Right size</th><th>Right modified</th><th class="num">Lines</th>
</tr></thead>
<tbody>
''');
      for (final (node, depth) in rows) {
        final key = _statusKey(node.status);
        final label = statusLabel(node.status);
        out
          ..write('<tr class="$key${node.isDirectory ? ' dir' : ''}">')
          ..write('<td class="st" title="$label"><span aria-hidden="true">'
              '${_symbol(node.status)}</span>'
              '<span class="sr">$label</span></td>')
          ..write('<td class="name" style="padding-left:${10 + depth * 18}px">')
          ..write(esc.convert(node.name))
          ..write(node.isDirectory ? '/' : '')
          ..write(node.isTypeConflict
              ? ' <span class="note">'
                  '(file on one side, folder on the other)</span>'
              : '')
          ..write('</td>')
          ..write(_sideCells(node, left: true))
          ..write(_sideCells(node, left: false))
          ..write('<td class="num lines">${_lines(node)}</td>')
          ..write('</tr>\n');
      }
      out.write('</tbody>\n</table>\n');
    }
    out.write('</main>\n</body>\n</html>\n');
    return out.toString();
  }

  static String _tail(String description) {
    final parts = description.split(RegExp(r'[/\\]'))
      ..removeWhere((s) => s.isEmpty);
    return parts.isEmpty ? description : parts.last;
  }

  String _sideCells(CompareNode node, {required bool left}) {
    final exists = left ? node.existsLeft : node.existsRight;
    if (!exists) {
      return '<td class="num missing">—</td><td class="missing">missing</td>';
    }
    final size = left ? node.leftSize : node.rightSize;
    final time = left ? node.leftModified : node.rightModified;
    return '<td class="num">${formatSize(size)}</td>'
        '<td>${time == null ? '' : formatDateIso(time)}</td>';
  }

  static String _lines(CompareNode node) {
    final added = node.addedLines ?? 0, removed = node.removedLines ?? 0;
    return [
      if (added > 0) '<span class="add">+$added</span>',
      if (removed > 0) '<span class="del">−$removed</span>',
    ].join(' ');
  }

  static String _card(String key, int count) {
    final status = switch (key) {
      'modified' => EntryStatus.modified,
      'left-only' => EntryStatus.onlyLeft,
      'right-only' => EntryStatus.onlyRight,
      _ => EntryStatus.identical,
    };
    return '<div class="card $key"><span class="sym" aria-hidden="true">'
        '${_symbol(status)}</span><b>${formatCount(count)}</b> '
        '${statusLabel(status)}</div>';
  }

  static String _type(CompareNode node) => node.isTypeConflict
      ? 'file vs folder'
      : node.isDirectory
          ? 'folder'
          : 'file';

  static String _statusKey(EntryStatus status) => switch (status) {
        EntryStatus.identical => 'identical',
        EntryStatus.modified => 'modified',
        EntryStatus.onlyLeft => 'left-only',
        EntryStatus.onlyRight => 'right-only',
      };

  static String _symbol(EntryStatus status) => switch (status) {
        EntryStatus.identical => '=',
        EntryStatus.modified => '≠',
        EntryStatus.onlyLeft => '−',
        EntryStatus.onlyRight => '+',
      };
}

/// Escapes markup and quotes but leaves `/` alone, so paths stay readable
/// in the page source.
const _textEscape = HtmlEscapeMode(
  name: 'text',
  escapeLtGt: true,
  escapeQuot: true,
  escapeApos: true,
);

/// The word used for [status] in reports and tooltips.
String statusLabel(EntryStatus status) => switch (status) {
      EntryStatus.identical => 'identical',
      EntryStatus.modified => 'modified',
      EntryStatus.onlyLeft => 'left only',
      EntryStatus.onlyRight => 'right only',
    };

/// One CSV field, quoted when needed. A leading `=`, `+`, `-` or `@` gets
/// a `'` in front so spreadsheet apps do not run a file name as a formula.
String csvCell(String value) {
  var v = value;
  if (v.isNotEmpty && '=+-@\t\r'.contains(v[0])) v = "'$v";
  if (v.contains(RegExp(r'[",\r\n]')) || v != v.trim()) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

const _css = '''
:root {
  --bg: #f6f7fb; --card: #ffffff; --text: #1d2130; --muted: #5d6475;
  --line: #e4e6ee; --head: #f0f1f6;
  --mod: #b45309; --left: #b91c1c; --right: #15803d; --same: #6b7280;
  --mod-bg: rgba(245, 158, 11, .08); --left-bg: rgba(239, 68, 68, .07);
  --right-bg: rgba(34, 197, 94, .08);
  color-scheme: light dark;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1117; --card: #181b24; --text: #e6e8ef; --muted: #9aa1b2;
    --line: #2a2e3b; --head: #1d2029;
    --mod: #fbbf24; --left: #f87171; --right: #4ade80; --same: #9ca3af;
    --mod-bg: rgba(251, 191, 36, .07); --left-bg: rgba(248, 113, 113, .07);
    --right-bg: rgba(74, 222, 128, .07);
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--text);
  font: 14px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, Ubuntu,
    Cantarell, sans-serif;
}
main { max-width: 1280px; margin: 0 auto; padding: 32px 24px 56px; }
h1 { font-size: 22px; margin: 0 0 4px; letter-spacing: -.01em; }
.meta { color: var(--muted); font-size: 12.5px; margin: 4px 0; }
.paths {
  display: grid; grid-template-columns: 1fr auto 1fr; gap: 10px;
  align-items: center; margin: 18px 0;
}
.path {
  background: var(--card); border: 1px solid var(--line); border-radius: 10px;
  padding: 8px 12px; font: 12.5px/1.4 ui-monospace, "JetBrains Mono",
    "Fira Code", Consolas, Menlo, monospace;
  overflow-wrap: anywhere;
}
.side {
  display: block; font: 600 11px/1.6 system-ui, sans-serif;
  color: var(--muted); text-transform: uppercase; letter-spacing: .06em;
}
.arrow { color: var(--muted); font-size: 18px; }
.cards {
  display: grid; grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 10px; margin: 6px 0 18px;
}
.card {
  border-radius: 12px; padding: 10px 14px; border: 1px solid var(--line);
  background: var(--card); color: var(--muted); font-size: 13px;
}
.card b { font-size: 19px; margin-right: 4px; }
.card .sym { font-weight: 700; margin-right: 8px; }
.card.modified b, .card.modified .sym { color: var(--mod); }
.card.left-only b, .card.left-only .sym { color: var(--left); }
.card.right-only b, .card.right-only .sym { color: var(--right); }
.card.identical b, .card.identical .sym { color: var(--same); }
.toggle { display: inline-block; margin: 0 0 10px; color: var(--muted); font-size: 13px; }
table {
  width: 100%; border-collapse: separate; border-spacing: 0;
  background: var(--card); border: 1px solid var(--line); border-radius: 12px;
  font-size: 13px;
}
thead th:first-child { border-top-left-radius: 12px; }
thead th:last-child { border-top-right-radius: 12px; }
th, td { padding: 4px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }
tr:last-child td { border-bottom: 0; }
th {
  position: sticky; top: 0; background: var(--head); text-align: left;
  font-size: 11.5px; font-weight: 600; color: var(--muted);
}
td.name { white-space: normal; overflow-wrap: anywhere; width: 40%; }
.num { text-align: right; font-variant-numeric: tabular-nums; }
td.st { width: 28px; text-align: center; font-weight: 700; }
tr.dir td.name { font-weight: 600; }
tr.modified td.st, tr.modified td.name { color: var(--mod); }
tr.left-only td.st, tr.left-only td.name { color: var(--left); }
tr.right-only td.st, tr.right-only td.name { color: var(--right); }
tr.modified { background: var(--mod-bg); }
tr.left-only { background: var(--left-bg); }
tr.right-only { background: var(--right-bg); }
tr.identical td { color: var(--muted); }
td.missing { color: var(--muted); font-style: italic; opacity: .7; }
.note { font-weight: 400; color: var(--muted); font-size: 12px; }
.lines { font: 12px ui-monospace, Consolas, Menlo, monospace; }
.add { color: var(--right); font-weight: 700; }
.del { color: var(--left); font-weight: 700; margin-left: 4px; }
.empty { color: var(--muted); font-size: 15px; margin: 32px 0; text-align: center; }
.sr {
  position: absolute; width: 1px; height: 1px; overflow: hidden;
  clip: rect(0 0 0 0); white-space: nowrap;
}
body:has(#hide-identical:checked) tr.identical { display: none; }
@media (max-width: 760px) {
  .paths { grid-template-columns: 1fr; }
  .arrow { display: none; }
  .cards { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  table { display: block; overflow-x: auto; }
}
@media print {
  body { background: #fff; color: #000; }
  main { padding: 0; max-width: none; }
  .toggle { display: none; }
  th { position: static; }
  table, .card, .path { border-color: #ccc; }
}
''';

/// Reading JSON, YAML, CSV and TSV into plain Dart values for the
/// structured diff, with parse errors that say where they are.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'csv.dart';

enum StructuredFormat {
  json('JSON'),
  yaml('YAML'),
  csv('CSV'),
  tsv('TSV');

  const StructuredFormat(this.label);

  final String label;

  bool get isTable => this == csv || this == tsv;

  /// The format a file name says, or null when it is not one of these.
  static StructuredFormat? of(String name) =>
      switch (p.extension(name).toLowerCase()) {
        '.json' => json,
        '.yaml' || '.yml' => yaml,
        '.csv' => csv,
        '.tsv' => tsv,
        _ => null,
      };
}

class StructuredParseException implements Exception {
  const StructuredParseException(this.message, {this.line, this.column});

  final String message;

  /// 1-based position of the problem, when known.
  final int? line;
  final int? column;

  String get location => line == null
      ? ''
      : column == null
          ? 'line $line'
          : 'line $line, column $column';

  @override
  String toString() => line == null ? message : '$message ($location)';
}

/// Marks a document that does not exist (a missing file, or one with
/// nothing but whitespace), as opposed to one holding `null`.
class Absent {
  const Absent._();

  static const value = Absent._();

  @override
  String toString() => 'absent';
}

/// Decodes UTF-8 (dropping a byte-order mark), or Latin-1 when the bytes
/// are not valid UTF-8.
String decodeText(List<int> bytes) {
  try {
    final text = utf8.decode(bytes);
    return text.startsWith('﻿') ? text.substring(1) : text;
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// Parses a JSON or YAML document into maps (string keys), lists and
/// scalars. Blank text is [Absent.value]. Several YAML documents in one
/// file become a list of documents.
Object? parseTree(String text, StructuredFormat format) {
  if (text.trim().isEmpty) return Absent.value;
  return switch (format) {
    StructuredFormat.json => _parseJson(text),
    StructuredFormat.yaml => _parseYaml(text),
    _ => throw ArgumentError.value(format, 'format', 'not a tree format'),
  };
}

Object? _parseJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException catch (e) {
    final offset = e.offset;
    if (offset == null) throw StructuredParseException(e.message);
    final (line, column) = lineAndColumn(text, offset);
    throw StructuredParseException(e.message, line: line, column: column);
  }
}

Object? _parseYaml(String text) {
  try {
    final documents = loadYamlDocuments(text);
    if (documents.length == 1) return _plain(documents.single.contents);
    return [for (final d in documents) _plain(d.contents)];
  } on YamlException catch (e) {
    final start = e.span?.start;
    throw StructuredParseException(
      e.message,
      line: start == null ? null : start.line + 1,
      column: start == null ? null : start.column + 1,
    );
  }
}

/// YAML nodes to plain values. Keys become strings (YAML allows any
/// scalar, even a list, as a key; a diff path needs text).
Object? _plain(Object? node) {
  if (node is YamlMap) {
    return <String, Object?>{
      for (final e in node.nodes.entries) _keyText(e.key): _plain(e.value),
    };
  }
  if (node is YamlList) return [for (final n in node.nodes) _plain(n)];
  if (node is YamlScalar) return node.value;
  return node;
}

String _keyText(Object? key) {
  final value = key is YamlNode ? _plain(key) : key;
  return value is String ? value : jsonEncode(value);
}

/// 1-based line and column of [offset] in [text].
(int, int) lineAndColumn(String text, int offset) {
  var line = 1, lineStart = 0;
  final end = offset.clamp(0, text.length);
  for (var i = 0; i < end; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      line++;
      lineStart = i + 1;
    }
  }
  return (line, end - lineStart + 1);
}

/// Parses a CSV or TSV table. A `.csv` file whose first line has more
/// semicolons (or pipes, or tabs) than commas uses that instead, as
/// spreadsheets in many locales write it.
List<List<String>> parseTable(String text, StructuredFormat format) {
  final delimiter =
      format == StructuredFormat.tsv ? '\t' : sniffDelimiter(text);
  try {
    return parseCsv(text, delimiter: delimiter);
  } on CsvParseException catch (e) {
    throw StructuredParseException(e.message, line: e.line, column: e.column);
  }
}

/// Reading and writing text files without changing them behind the user's
/// back: the encoding, byte order mark and line endings a file was read
/// with are remembered and used again when it is saved.
///
/// Text inside the app always uses `\n` line breaks. CRLF files are
/// converted on the way in and back on the way out; files that mix both
/// keep each unchanged line's own ending (see [MixedEndings]).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'line_diff.dart';

enum TextEncoding {
  utf8('UTF-8'),
  utf16le('UTF-16 LE'),
  utf16be('UTF-16 BE'),
  latin1('Latin-1');

  const TextEncoding(this.label);

  final String label;
}

enum LineEnding {
  lf('LF', 'Unix and macOS'),
  crlf('CRLF', 'Windows'),

  /// Both kinds in one file. Only offered for files read that way: saving
  /// keeps each line's own ending.
  mixed('Mixed', 'as read');

  const LineEnding(this.label, this.description);

  final String label;
  final String description;
}

/// How a text is stored as bytes.
class TextFormat {
  const TextFormat({
    this.encoding = TextEncoding.utf8,
    this.bom = false,
    this.lineEnding = LineEnding.lf,
  });

  final TextEncoding encoding;

  /// Whether the file starts with a byte order mark. Always true for
  /// UTF-16 (files without one cannot be recognised when read back) and
  /// false for Latin-1, which has none.
  final bool bom;

  final LineEnding lineEnding;

  /// The encodings offered when the user picks one for the next save.
  static const choices = [
    TextFormat(),
    TextFormat(bom: true),
    TextFormat(encoding: TextEncoding.utf16le, bom: true),
    TextFormat(encoding: TextEncoding.utf16be, bom: true),
    TextFormat(encoding: TextEncoding.latin1),
  ];

  /// e.g. `UTF-8`, `UTF-8 with BOM`, `UTF-16 LE`.
  String get encodingLabel =>
      encoding == TextEncoding.utf8 && bom ? 'UTF-8 with BOM' : encoding.label;

  bool sameEncoding(TextFormat other) =>
      other.encoding == encoding && other.bom == bom;

  TextFormat copyWith({
    TextEncoding? encoding,
    bool? bom,
    LineEnding? lineEnding,
  }) =>
      TextFormat(
        encoding: encoding ?? this.encoding,
        bom: bom ?? this.bom,
        lineEnding: lineEnding ?? this.lineEnding,
      );

  @override
  bool operator ==(Object other) =>
      other is TextFormat &&
      other.encoding == encoding &&
      other.bom == bom &&
      other.lineEnding == lineEnding;

  @override
  int get hashCode => Object.hash(encoding, bom, lineEnding);

  @override
  String toString() => '$encodingLabel ${lineEnding.label}';
}

/// The result of reading a text: the text with `\n` breaks and the format
/// it was stored in.
class DecodedText {
  const DecodedText(this.text, this.format, {this.mixed});

  final String text;
  final TextFormat format;

  /// Each line's original ending, when [format] has mixed line endings.
  final MixedEndings? mixed;
}

/// Thrown by [encodeText] when the text holds a character the chosen
/// encoding cannot store (anything past U+00FF in Latin-1).
class UnencodableTextException implements Exception {
  const UnencodableTextException(this.encoding, this.offset, this.character);

  final TextEncoding encoding;

  /// Where the first such character is, as an index into the text.
  final int offset;
  final String character;

  @override
  String toString() => '"$character" cannot be stored in ${encoding.label}';
}

const _utf8Bom = [0xEF, 0xBB, 0xBF];

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

/// The UTF-16 byte order a byte order mark announces, or null. An odd
/// byte count cannot be UTF-16, whatever the first two bytes say.
TextEncoding? _utf16Bom(List<int> bytes) {
  if (bytes.length < 2 || bytes.length.isOdd) return null;
  if (bytes[0] == 0xFF && bytes[1] == 0xFE) return TextEncoding.utf16le;
  if (bytes[0] == 0xFE && bytes[1] == 0xFF) return TextEncoding.utf16be;
  return null;
}

/// True for content that is not text: a NUL byte near the start, unless
/// the file is UTF-16 (where NULs are normal).
bool looksBinary(List<int> bytes) {
  if (_utf16Bom(bytes) != null) return false;
  final probe = bytes.length < 8192 ? bytes.length : 8192;
  for (var i = 0; i < probe; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

/// Decodes [bytes]: UTF-8 (with or without a byte order mark), UTF-16 LE
/// or BE (with a byte order mark), and Latin-1 for anything else. Latin-1
/// maps every byte to a character, so even a misdetected file is written
/// back byte for byte.
DecodedText decodeText(List<int> bytes) {
  final utf16 = _utf16Bom(bytes);
  if (utf16 != null) {
    final units = Uint16List(bytes.length ~/ 2 - 1);
    final le = utf16 == TextEncoding.utf16le;
    for (var i = 0; i < units.length; i++) {
      final lo = bytes[2 + i * 2], hi = bytes[3 + i * 2];
      units[i] = le ? (hi << 8) | lo : (lo << 8) | hi;
    }
    return _withLineEndings(
        String.fromCharCodes(units), TextFormat(encoding: utf16, bom: true));
  }
  final bom = _startsWith(bytes, _utf8Bom);
  try {
    final text = utf8.decode(bom ? bytes.sublist(3) : bytes);
    return _withLineEndings(text, TextFormat(bom: bom));
  } on FormatException {
    return _withLineEndings(
        latin1.decode(bytes), const TextFormat(encoding: TextEncoding.latin1));
  }
}

/// Text that did not come from a file (pasted text): only its line
/// endings need detecting. It saves as UTF-8.
DecodedText decodeString(String raw) =>
    _withLineEndings(raw, const TextFormat());

DecodedText _withLineEndings(String raw, TextFormat format) {
  var crlf = 0, lf = 0;
  for (var i = raw.indexOf('\n'); i >= 0; i = raw.indexOf('\n', i + 1)) {
    if (i > 0 && raw.codeUnitAt(i - 1) == 0x0D) {
      crlf++;
    } else {
      lf++;
    }
  }
  if (crlf == 0) {
    return DecodedText(raw, format.copyWith(lineEnding: LineEnding.lf));
  }
  final text = raw.replaceAll('\r\n', '\n');
  if (lf == 0) {
    return DecodedText(text, format.copyWith(lineEnding: LineEnding.crlf));
  }
  final parts = raw.split('\n');
  return DecodedText(
    text,
    format.copyWith(lineEnding: LineEnding.mixed),
    mixed: MixedEndings(
      [
        for (final p in parts)
          p.endsWith('\r') ? p.substring(0, p.length - 1) : p
      ],
      [for (final p in parts) p.endsWith('\r')],
    ),
  );
}

/// The line endings of a file that mixes LF and CRLF, kept so a save can
/// write every line the user did not touch with the ending it had.
class MixedEndings {
  MixedEndings(this.lines, this.crlf) : assert(lines.length == crlf.length);

  /// The text as read, split at `\n` (so the last entry is what follows
  /// the final line break, usually empty).
  final List<String> lines;

  /// Whether each of [lines] ended with CRLF.
  final List<bool> crlf;

  /// The ending most lines use, for lines that are new. (The last entry
  /// never has an ending, so it does not vote.)
  bool get mostlyCrlf => crlf.where((c) => c).length * 2 > crlf.length - 1;

  /// Whether each of [current] (text split at `\n`) should end with CRLF:
  /// lines matched to an original line keep its ending, a replaced line
  /// takes the ending of the line it replaced, and new lines take the most
  /// common one.
  List<bool> endingsFor(List<String> current) {
    final out = <bool>[];
    final fallback = mostlyCrlf;
    final chunks = diffLines(lines, current);
    var a = 0;
    for (var c = 0; c < chunks.length; c++) {
      final chunk = chunks[c];
      switch (chunk.op) {
        case DiffOp.equal:
          for (var i = 0; i < chunk.lines.length; i++) {
            out.add(crlf[a++]);
          }
        case DiffOp.delete:
          final next = c + 1 < chunks.length ? chunks[c + 1] : null;
          if (next != null && next.op == DiffOp.insert) {
            for (var i = 0; i < next.lines.length; i++) {
              out.add(i < chunk.lines.length ? crlf[a + i] : fallback);
            }
            c++;
          }
          a += chunk.lines.length;
        case DiffOp.insert:
          for (var i = 0; i < chunk.lines.length; i++) {
            out.add(fallback);
          }
      }
    }
    return out;
  }
}

/// [text] (with `\n` breaks) with the line breaks [ending] calls for.
/// [mixed] supplies the per-line endings for [LineEnding.mixed]; without
/// it, mixed text keeps `\n`.
String applyLineEndings(String text, LineEnding ending, {MixedEndings? mixed}) {
  switch (ending) {
    case LineEnding.lf:
      return text;
    case LineEnding.crlf:
      return text.replaceAll('\n', '\r\n');
    case LineEnding.mixed:
      if (mixed == null) return text;
      final parts = text.split('\n');
      final crlf = mixed.endingsFor(parts);
      final out = StringBuffer();
      for (var i = 0; i < parts.length; i++) {
        out.write(parts[i]);
        if (i < parts.length - 1) out.write(crlf[i] ? '\r\n' : '\n');
      }
      return out.toString();
  }
}

/// Encodes [text] (with `\n` breaks) in [format]. Throws
/// [UnencodableTextException] instead of silently replacing characters the
/// encoding cannot store.
Uint8List encodeText(String text, TextFormat format, {MixedEndings? mixed}) {
  final raw = applyLineEndings(text, format.lineEnding, mixed: mixed);
  switch (format.encoding) {
    case TextEncoding.utf8:
      final body = utf8.encode(raw);
      if (!format.bom) return body;
      return Uint8List(body.length + 3)
        ..setAll(0, _utf8Bom)
        ..setAll(3, body);
    case TextEncoding.utf16le:
    case TextEncoding.utf16be:
      final le = format.encoding == TextEncoding.utf16le;
      final units = raw.codeUnits;
      final start = format.bom ? 2 : 0;
      final out = Uint8List(start + units.length * 2);
      if (format.bom) {
        out[0] = le ? 0xFF : 0xFE;
        out[1] = le ? 0xFE : 0xFF;
      }
      for (var i = 0; i < units.length; i++) {
        final u = units[i];
        out[start + i * 2] = le ? u & 0xFF : u >> 8;
        out[start + i * 2 + 1] = le ? u >> 8 : u & 0xFF;
      }
      return out;
    case TextEncoding.latin1:
      final out = Uint8List(raw.length);
      for (var i = 0; i < raw.length; i++) {
        final u = raw.codeUnitAt(i);
        if (u > 0xFF) {
          throw UnencodableTextException(TextEncoding.latin1,
              _textOffset(text, raw, i), String.fromCharCode(u));
        }
        out[i] = u;
      }
      return out;
  }
}

/// Maps an index into the line-ending-converted [raw] back to [text].
int _textOffset(String text, String raw, int rawIndex) {
  if (raw.length == text.length) return rawIndex;
  var crs = 0;
  for (var i = 0; i < rawIndex; i++) {
    if (raw.codeUnitAt(i) == 0x0D &&
        i + 1 < raw.length &&
        raw.codeUnitAt(i + 1) == 0x0A) {
      crs++;
    }
  }
  return rawIndex - crs;
}

/// The first character of [text] that [encoding] cannot store, or null.
int? firstUnencodable(String text, TextEncoding encoding) {
  if (encoding != TextEncoding.latin1) return null;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) > 0xFF) return i;
  }
  return null;
}

/// Turning file bytes into lines for merging and back again, so the saved
/// result looks like the base file did: same line endings, same final
/// newline, same encoding and byte-order mark.
library;

import 'dart:convert';

enum LineEnding {
  lf('\n'),
  crlf('\r\n'),
  cr('\r');

  const LineEnding(this.text);

  final String text;
}

enum TextEncodingKind { utf8, latin1 }

/// How a file's text is laid out, apart from its lines.
class TextFormat {
  const TextFormat({
    this.lineEnding = LineEnding.lf,
    this.finalNewline = true,
    this.encoding = TextEncodingKind.utf8,
    this.bom = false,
  });

  final LineEnding lineEnding;

  /// Whether the last line ends with a line ending.
  final bool finalNewline;
  final TextEncodingKind encoding;

  /// A UTF-8 byte-order mark at the start of the file.
  final bool bom;

  /// Joins [lines] into file bytes in this format. Falls back to UTF-8 when
  /// a Latin-1 file gained characters Latin-1 cannot hold (say, from a
  /// UTF-8 side of the merge).
  List<int> encode(List<String> lines) {
    final text = joinLines(lines);
    if (encoding == TextEncodingKind.latin1) {
      try {
        return latin1.encode(text);
      } on ArgumentError {
        // Fall through to UTF-8.
      }
    }
    return [if (bom) ...const [0xEF, 0xBB, 0xBF], ...utf8.encode(text)];
  }

  String joinLines(List<String> lines) {
    if (lines.isEmpty) return '';
    final eol = lineEnding.text;
    return finalNewline ? '${lines.join(eol)}$eol' : lines.join(eol);
  }
}

/// A decoded file: its lines without line endings, and its [format].
class DecodedText {
  const DecodedText(this.lines, this.format);

  final List<String> lines;
  final TextFormat format;

  static const empty = DecodedText([], TextFormat());

  /// Whether [bytes] look like a binary file: a NUL byte near the start.
  static bool looksBinary(List<int> bytes) {
    final probe = bytes.length < 8192 ? bytes.length : 8192;
    for (var i = 0; i < probe; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  /// Decodes UTF-8 (dropping a byte-order mark), falling back to Latin-1
  /// for bytes that are not valid UTF-8. Lines are split on any line
  /// ending; the most common one is kept in [format] for saving.
  factory DecodedText.decode(List<int> bytes) {
    var bom = false;
    var body = bytes;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      bom = true;
      body = bytes.sublist(3);
    }
    String text;
    var encoding = TextEncodingKind.utf8;
    try {
      text = utf8.decode(body);
    } on FormatException {
      text = latin1.decode(bytes);
      encoding = TextEncodingKind.latin1;
      bom = false;
    }
    return DecodedText.fromString(text, encoding: encoding, bom: bom);
  }

  factory DecodedText.fromString(String text,
      {TextEncodingKind encoding = TextEncodingKind.utf8, bool bom = false}) {
    var crlf = 0, lf = 0, cr = 0;
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x0A) {
        lf++;
        lines.add(text.substring(start, i));
        start = i + 1;
      } else if (c == 0x0D) {
        lines.add(text.substring(start, i));
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) {
          crlf++;
          i++;
        } else {
          cr++;
        }
        start = i + 1;
      }
    }
    final finalNewline = start == text.length && text.isNotEmpty;
    if (start < text.length) lines.add(text.substring(start));

    final ending = crlf >= lf && crlf >= cr && crlf > 0
        ? LineEnding.crlf
        : cr > lf && cr > crlf
            ? LineEnding.cr
            : LineEnding.lf;
    return DecodedText(
      lines,
      TextFormat(
        lineEnding: ending,
        // An empty file has no last line; give it a newline once it
        // gains one, which is what nearly every text file wants.
        finalNewline: text.isEmpty || finalNewline,
        encoding: encoding,
        bom: bom,
      ),
    );
  }
}

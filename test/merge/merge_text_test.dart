import 'dart:convert';

import 'package:delta_view/merge/merge_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DecodedText', () {
    test('splits on any line ending and keeps the most common one', () {
      final crlf = DecodedText.decode(utf8.encode('a\r\nb\r\nc\r\n'));
      expect(crlf.lines, ['a', 'b', 'c']);
      expect(crlf.format.lineEnding, LineEnding.crlf);
      expect(crlf.format.finalNewline, isTrue);
      expect(utf8.decode(crlf.format.encode(['x', 'y'])), 'x\r\ny\r\n');

      final lf = DecodedText.decode(utf8.encode('a\nb'));
      expect(lf.lines, ['a', 'b']);
      expect(lf.format.lineEnding, LineEnding.lf);
      expect(lf.format.finalNewline, isFalse);
      expect(utf8.decode(lf.format.encode(['x', 'y'])), 'x\ny');

      final mixed = DecodedText.decode(utf8.encode('a\r\nb\nc\r\n'));
      expect(mixed.lines, ['a', 'b', 'c']);
      expect(mixed.format.lineEnding, LineEnding.crlf);

      final cr = DecodedText.decode(utf8.encode('a\rb\r'));
      expect(cr.lines, ['a', 'b']);
      expect(cr.format.lineEnding, LineEnding.cr);
    });

    test('keeps blank lines', () {
      expect(DecodedText.decode(utf8.encode('a\n\n\nb\n')).lines,
          ['a', '', '', 'b']);
      expect(DecodedText.decode(utf8.encode('\n')).lines, ['']);
    });

    test('empty files give no lines and end new text with a newline', () {
      final empty = DecodedText.decode(const []);
      expect(empty.lines, isEmpty);
      expect(utf8.decode(empty.format.encode(['a'])), 'a\n');
      expect(empty.format.encode(const []), isEmpty);
    });

    test('falls back to Latin-1 and writes Latin-1 back', () {
      final bytes = [0x63, 0x61, 0x66, 0xE9, 0x0A]; // "café\n" in Latin-1
      final decoded = DecodedText.decode(bytes);
      expect(decoded.lines, ['café']);
      expect(decoded.format.encoding, TextEncodingKind.latin1);
      expect(decoded.format.encode(decoded.lines), bytes);
      // Characters Latin-1 cannot hold fall back to UTF-8.
      expect(utf8.decode(decoded.format.encode(['→'])), '→\n');
    });

    test('drops and restores a UTF-8 byte-order mark', () {
      final decoded =
          DecodedText.decode([0xEF, 0xBB, 0xBF, ...utf8.encode('hé\n')]);
      expect(decoded.lines, ['hé']);
      expect(decoded.format.bom, isTrue);
      expect(decoded.format.encode(['x']), [0xEF, 0xBB, 0xBF, 0x78, 0x0A]);
    });

    test('spots binary content', () {
      expect(DecodedText.looksBinary([0x89, 0x50, 0x00, 0x01]), isTrue);
      expect(DecodedText.looksBinary(utf8.encode('plain text')), isFalse);
    });
  });
}

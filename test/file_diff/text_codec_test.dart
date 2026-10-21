import 'dart:convert';
import 'dart:typed_data';

import 'package:delta_view/diff/text_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _utf16(String s, {required bool le}) {
  final out = <int>[le ? 0xFF : 0xFE, le ? 0xFE : 0xFF];
  for (final u in s.codeUnits) {
    out.addAll(le ? [u & 0xFF, u >> 8] : [u >> 8, u & 0xFF]);
  }
  return Uint8List.fromList(out);
}

void main() {
  group('decodeText', () {
    test('plain UTF-8 without a BOM', () {
      final d = decodeText(utf8.encode('héllo\nworld\n'));
      expect(d.text, 'héllo\nworld\n');
      expect(d.format.encoding, TextEncoding.utf8);
      expect(d.format.bom, isFalse);
      expect(d.format.lineEnding, LineEnding.lf);
    });

    test('UTF-8 with a BOM drops the mark from the text', () {
      final d = decodeText([0xEF, 0xBB, 0xBF, ...utf8.encode('x\n')]);
      expect(d.text, 'x\n');
      expect(d.format.bom, isTrue);
      expect(d.format.encodingLabel, 'UTF-8 with BOM');
    });

    test('UTF-16 LE and BE by their BOM, including surrogate pairs', () {
      const text = 'a😀b\r\nc\r\n';
      final le = decodeText(_utf16(text, le: true));
      expect(le.format.encoding, TextEncoding.utf16le);
      expect(le.text, 'a😀b\nc\n');
      expect(le.format.lineEnding, LineEnding.crlf);
      final be = decodeText(_utf16(text, le: false));
      expect(be.format.encoding, TextEncoding.utf16be);
      expect(be.text, 'a😀b\nc\n');
    });

    test('invalid UTF-8 falls back to Latin-1', () {
      final d = decodeText([0x63, 0x61, 0x66, 0xE9, 0x0A]); // "café" in Latin-1
      expect(d.format.encoding, TextEncoding.latin1);
      expect(d.text, 'café\n');
    });

    test('UTF-16 is not mistaken for binary', () {
      expect(looksBinary(_utf16('abc', le: true)), isFalse);
      expect(looksBinary([0x61, 0x00, 0x62]), isTrue);
      expect(looksBinary(utf8.encode('plain')), isFalse);
    });
  });

  group('line endings', () {
    test('detects LF, CRLF and mixed', () {
      expect(decodeString('a\nb\n').format.lineEnding, LineEnding.lf);
      expect(decodeString('a\r\nb\r\n').format.lineEnding, LineEnding.crlf);
      expect(decodeString('a\r\nb\n').format.lineEnding, LineEnding.mixed);
      expect(decodeString('no breaks').format.lineEnding, LineEnding.lf);
    });

    test('text inside the app always uses \\n', () {
      expect(decodeString('a\r\nb\r\n').text, 'a\nb\n');
      expect(decodeString('a\r\nb\nc').text, 'a\nb\nc');
    });

    test('mixed endings survive an edit: untouched lines keep theirs', () {
      final d = decodeString('one\r\ntwo\nthree\r\n');
      final edited = d.text
          .replaceFirst('two', 'TWO')
          .replaceFirst('three\n', 'three\nfour\n');
      final raw = applyLineEndings(edited, LineEnding.mixed, mixed: d.mixed);
      // "TWO" replaced "two" and keeps its LF; "four" is new and takes the
      // most common ending (CRLF).
      expect(raw, 'one\r\nTWO\nthree\r\nfour\r\n');
    });
  });

  group('encodeText round-trips', () {
    final samples = <String, List<int>>{
      'utf-8': utf8.encode('héllo\nwörld\n'),
      'utf-8 bom crlf': [0xEF, 0xBB, 0xBF, ...utf8.encode('a\r\nb\r\n')],
      'utf-16 le': _utf16('x😀\r\ny\r\n', le: true),
      'utf-16 be': _utf16('x😀\ny', le: false),
      'latin-1': [0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0xFF],
      'mixed': utf8.encode('one\r\ntwo\nthree\r\nfour'),
      'empty': const [],
    };
    for (final MapEntry(key: name, value: bytes) in samples.entries) {
      test(name, () {
        final d = decodeText(bytes);
        expect(encodeText(d.text, d.format, mixed: d.mixed), bytes);
      });
    }

    test('changing the format for the next save', () {
      final d = decodeText(utf8.encode('a\nb\n'));
      final out = encodeText(
          d.text, d.format.copyWith(lineEnding: LineEnding.crlf, bom: true));
      expect(out, [0xEF, 0xBB, 0xBF, ...utf8.encode('a\r\nb\r\n')]);
    });

    test('Latin-1 refuses characters it cannot store instead of mangling', () {
      const format = TextFormat(encoding: TextEncoding.latin1);
      expect(encodeText('café', format), [0x63, 0x61, 0x66, 0xE9]);
      expect(
        () => encodeText('ok\n€uro', format),
        throwsA(isA<UnencodableTextException>()
            .having((e) => e.offset, 'offset', 3)
            .having((e) => e.character, 'character', '€')),
      );
      expect(firstUnencodable('ok\n€', TextEncoding.latin1), 3);
      expect(firstUnencodable('ok\n€', TextEncoding.utf8), isNull);
    });
  });
}

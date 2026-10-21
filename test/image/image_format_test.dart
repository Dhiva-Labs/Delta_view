import 'package:delta_view/ui/image/image_compare_view.dart';
import 'package:delta_view/ui/image/image_format.dart'
    show ImageFormat, formatByteSize, sniffImageFormat;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isImageFile goes by extension, in any case', () {
    for (final name in [
      'a.png',
      'b.JPG',
      'c.jpeg',
      'd.Gif',
      'e.webp',
      'f.BMP',
      'dir/with.dots/g.png',
    ]) {
      expect(isImageFile(name), isTrue, reason: name);
    }
    for (final name in ['a.svg', 'b.txt', 'png', 'c.png.bak', 'd.tiff', '']) {
      expect(isImageFile(name), isFalse, reason: name);
    }
  });

  test('sniffImageFormat reads signatures, not names', () {
    expect(sniffImageFormat([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        ImageFormat.png);
    expect(sniffImageFormat([0xFF, 0xD8, 0xFF, 0xE0]), ImageFormat.jpeg);
    expect(sniffImageFormat('GIF89a...'.codeUnits), ImageFormat.gif);
    expect(sniffImageFormat('GIF87a...'.codeUnits), ImageFormat.gif);
    expect(sniffImageFormat('RIFF\x00\x00\x00\x00WEBPVP8 '.codeUnits),
        ImageFormat.webp);
    expect(sniffImageFormat('RIFF\x00\x00\x00\x00WAVE'.codeUnits),
        ImageFormat.unknown);
    expect(sniffImageFormat('BM......'.codeUnits), ImageFormat.bmp);
    expect(sniffImageFormat('hello'.codeUnits), ImageFormat.unknown);
    expect(sniffImageFormat(const []), ImageFormat.unknown);
  });

  test('formatByteSize', () {
    expect(formatByteSize(999), '999 B');
    expect(formatByteSize(24100), '24.1 kB');
    expect(formatByteSize(3200000), '3.2 MB');
  });
}

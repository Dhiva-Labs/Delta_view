/// Which files are images, and what an image file says about itself.
library;

import 'package:path/path.dart' as p;

const _imageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

/// Whether [name] is an image the image compare view can show: png, jpeg,
/// gif, webp or bmp, by extension, in any case.
bool isImageFile(String name) =>
    _imageExtensions.contains(p.extension(name).toLowerCase());

enum ImageFormat {
  png('PNG'),
  jpeg('JPEG'),
  gif('GIF'),
  webp('WebP'),
  bmp('BMP'),
  unknown('Unknown format');

  const ImageFormat(this.label);

  final String label;
}

/// The format [bytes] really are, from their signature rather than the
/// file name (a `.png` that is really a JPEG says so).
ImageFormat sniffImageFormat(List<int> bytes) {
  bool starts(List<int> signature, [int at = 0]) {
    if (bytes.length < at + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[at + i] != signature[i]) return false;
    }
    return true;
  }

  if (starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return ImageFormat.png;
  }
  if (starts(const [0xFF, 0xD8, 0xFF])) return ImageFormat.jpeg;
  if (starts('GIF87a'.codeUnits) || starts('GIF89a'.codeUnits)) {
    return ImageFormat.gif;
  }
  if (starts('RIFF'.codeUnits) && starts('WEBP'.codeUnits, 8)) {
    return ImageFormat.webp;
  }
  if (starts('BM'.codeUnits)) return ImageFormat.bmp;
  return ImageFormat.unknown;
}

/// `24.1 kB`-style sizes, matching the folder view.
String formatByteSize(int size) {
  if (size < 1000) return '$size B';
  if (size < 1000 * 1000) return '${(size / 1000).toStringAsFixed(1)} kB';
  if (size < 1000 * 1000 * 1000) {
    return '${(size / 1e6).toStringAsFixed(1)} MB';
  }
  return '${(size / 1e9).toStringAsFixed(1)} GB';
}

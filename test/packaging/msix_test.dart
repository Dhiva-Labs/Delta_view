// The Microsoft Store package is only built on Windows (packaging/windows/msix);
// these checks catch a broken manifest or a missing image on any machine.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _dir = 'packaging/windows/msix';

String _read(String path) => File(path).readAsStringSync();

/// Width and height of a PNG, from its IHDR chunk.
(int, int) _pngSize(File file) {
  final b = file.readAsBytesSync();
  int be32(int at) =>
      b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];
  expect(String.fromCharCodes(b.sublist(1, 4)), 'PNG', reason: file.path);
  return (be32(16), be32(20));
}

/// Fails unless every tag in [xml] is closed in order and every attribute is
/// quoted: enough to catch a broken edit without an XML parser.
void _expectBalancedXml(String xml) {
  final body = xml
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
      .replaceAll(RegExp(r'<\?.*?\?>', dotAll: true), '');
  final tag = RegExp(r'<(/?)([\w:.-]+)((?:\s+[\w:.-]+="[^"<]*")*)\s*(/?)>');
  final open = <String>[];
  var at = 0;
  for (final m in tag.allMatches(body)) {
    expect(
      body.substring(at, m.start).contains('<'),
      isFalse,
      reason: 'unparsed markup before ${m.group(0)}',
    );
    at = m.end;
    final name = m.group(2)!;
    if (m.group(1) == '/') {
      expect(open, isNotEmpty, reason: 'stray </$name>');
      expect(open.removeLast(), name, reason: '</$name> closes the wrong tag');
    } else if (m.group(4) != '/') {
      open.add(name);
    }
  }
  expect(body.substring(at).contains('<'), isFalse);
  expect(open, isEmpty, reason: 'unclosed tags');
}

void main() {
  final manifest = _read('$_dir/AppxManifest.xml.in');

  test('the manifest is well-formed once build-msix.ps1 fills it in', () {
    // The placeholders build-msix.ps1 replaces, and no others.
    final placeholders = RegExp(
      r'@[A-Z_]+@',
    ).allMatches(manifest).map((m) => m.group(0)).toSet();
    final script = _read('$_dir/build-msix.ps1');
    final filled = RegExp(
      r"^\s*'(@[A-Z_]+@)'\s*=",
      multiLine: true,
    ).allMatches(script).map((m) => m.group(1)).toSet();
    expect(placeholders, filled);

    _expectBalancedXml(manifest.replaceAll(RegExp(r'@[A-Z_]+@'), 'x'));
  });

  test(
    'the manifest starts delta_view.exe and declares the delta-view alias',
    () {
      final binary = RegExp(
        r'set\(BINARY_NAME "(\w+)"\)',
      ).firstMatch(_read('windows/CMakeLists.txt'))!.group(1);
      expect(manifest, contains('Executable="$binary.exe"'));
      expect(
        manifest,
        contains('<desktop:ExecutionAlias Alias="delta-view.exe" />'),
      );
      // The package and its tile carry the name reserved in Partner Center.
      final package = RegExp(
        r'<DisplayName>([^<]+)</DisplayName>',
      ).firstMatch(manifest)!.group(1);
      final tile = RegExp(
        r'\sDisplayName="([^"]+)"',
      ).firstMatch(manifest)!.group(1);
      expect(tile, package);
      expect(manifest, contains('<Capability Name="internetClient" />'));
      expect(manifest, contains('<rescap:Capability Name="runFullTrust" />'));
    },
  );

  test('every image the manifest names is there, at every scale and size', () {
    const sizes = {
      'StoreLogo': (50, 50),
      'Square44x44Logo': (44, 44),
      'Square150x150Logo': (150, 150),
      'Wide310x150Logo': (310, 150),
    };
    final named = RegExp(
      r'Assets\\(\w+)\.png',
    ).allMatches(manifest).map((m) => m.group(1)!).toSet();
    expect(named, sizes.keys.toSet());

    for (final MapEntry(key: name, value: (w, h)) in sizes.entries) {
      for (final scale in [100, 200, 400]) {
        final file = File('$_dir/Assets/$name.scale-$scale.png');
        expect(file.existsSync(), isTrue, reason: file.path);
        expect(_pngSize(file), (
          w * scale ~/ 100,
          h * scale ~/ 100,
        ), reason: file.path);
      }
    }
    // Taskbar, Start and File Explorer sizes, with and without the plate and
    // for light mode.
    for (final size in [
      16,
      20,
      24,
      30,
      32,
      36,
      40,
      48,
      60,
      64,
      72,
      80,
      96,
      256,
    ]) {
      for (final variant in [
        '',
        '_altform-unplated',
        '_altform-lightunplated',
      ]) {
        final file = File(
          '$_dir/Assets/Square44x44Logo.targetsize-$size$variant.png',
        );
        expect(file.existsSync(), isTrue, reason: file.path);
        expect(_pngSize(file), (size, size), reason: file.path);
      }
    }
  });

  test('the Store listing logos have the sizes Partner Center asks for', () {
    for (final (name, w, h) in [
      ('app-tile-icon-300', 300, 300),
      ('box-art-1080', 1080, 1080),
      ('poster-art-1440x2160', 1440, 2160),
    ]) {
      expect(_pngSize(File('$_dir/store-logos/$name.png')), (
        w,
        h,
      ), reason: name);
    }
  });

  test('pubspec.yaml version gives a Store version ending in .0', () {
    // build-msix.ps1 drops the build number and adds a fourth field of 0,
    // which the Store keeps for itself.
    final version = RegExp(
      r'^version:\s*([^\s+]+)',
      multiLine: true,
    ).firstMatch(_read('pubspec.yaml'))!.group(1)!;
    final fields = version.split('.').map(int.parse).toList();
    expect(fields, hasLength(3));
    expect(fields.every((f) => f <= 65535), isTrue);
  });
}

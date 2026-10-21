import 'dart:typed_data';

import 'sources/file_source.dart';

/// One side of a two-file text comparison: a file reachable through a
/// [SourceSpec], or text held in memory (clipboard compare).
class DiffSide {
  DiffSide.source(SourceSpec this.spec)
      : initialText = null,
        memoryLabel = null;

  DiffSide.memory({required String text, required String label})
      : spec = null,
        initialText = text,
        memoryLabel = label;

  final SourceSpec? spec;

  /// The starting text of a memory side.
  final String? initialText;

  /// The name shown for a memory side.
  final String? memoryLabel;

  bool get isMemory => spec == null;

  String get label => memoryLabel ?? spec!.label;

  String get description => memoryLabel ?? spec!.description;

  /// The path on this machine when the side is a local file.
  String? get localPath => switch (spec) {
        LocalSource s => s.path,
        _ => null,
      };

  /// The file's bytes, or null when it does not exist (yet). Memory sides
  /// return null; use [initialText].
  Future<Uint8List?> read() async {
    final spec = this.spec;
    if (spec == null) return null;
    final source = await FileSource.open(spec);
    try {
      final entry = await source.stat('');
      if (entry == null) return null;
      return await source.read('');
    } finally {
      await source.close();
    }
  }

  /// Whether [write] can succeed: memory sides and read-only sources
  /// (archives) cannot be written in place.
  Future<bool> canWrite() async {
    final spec = this.spec;
    if (spec == null) return false;
    final source = await FileSource.open(spec);
    try {
      return source.writable;
    } finally {
      await source.close();
    }
  }

  Future<void> write(List<int> bytes) async {
    final spec = this.spec;
    if (spec == null) {
      throw UnsupportedError('This side is not a file; use Save as.');
    }
    final source = await FileSource.open(spec);
    try {
      await source.write('', bytes);
    } finally {
      await source.close();
    }
  }
}

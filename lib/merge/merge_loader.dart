/// Reads the three sides of a merge and runs the merge, off the UI thread
/// when the files are big.
library;

import 'dart:isolate';

import '../compare/comparison.dart';
import '../compare/diff_side.dart';
import 'merge_document.dart';
import 'merge_text.dart';

export 'merge_document.dart';
export 'merge_text.dart';

/// Above this many bytes in total, decoding and diffing move to an isolate.
/// Below it the isolate's start-up costs more than the work, and
/// `git mergetool` users notice every millisecond before the window shows.
const _isolateThreshold = 256 * 1024;

const _maxFileBytes = 32 * 1024 * 1024;

class MergeLoadException implements Exception {
  const MergeLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LoadedMerge {
  const LoadedMerge({
    required this.document,
    required this.format,
    required this.baseMissing,
    required this.leftMissing,
    required this.rightMissing,
    this.outputBytes,
  });

  final MergeDocument document;

  /// How the result is written: the base file's line endings, final
  /// newline and encoding (or the left file's when there is no base).
  final TextFormat format;

  final bool baseMissing;
  final bool leftMissing;
  final bool rightMissing;

  /// What the output file holds now, to tell whether the merge result is
  /// already saved. Null when there is no output or it does not exist.
  final List<int>? outputBytes;
}

Future<LoadedMerge> loadMerge(ThreeWayComparison comparison) async {
  Future<List<int>?> read(SourceSpec spec, String role) async {
    final bytes = await DiffSide.source(spec).read();
    if (bytes == null) return null;
    if (bytes.length > _maxFileBytes) {
      throw MergeLoadException(
          'The $role file is larger than 32 MB, too big to merge as text.');
    }
    if (DecodedText.looksBinary(bytes)) {
      throw MergeLoadException(
          'The $role file (${spec.label}) is binary and cannot be merged as '
          'text.');
    }
    return bytes;
  }

  final output = comparison.output;
  final results = await Future.wait([
    read(comparison.base, 'base'),
    read(comparison.left, 'left'),
    read(comparison.right, 'right'),
    if (output != null) DiffSide.source(output).read(),
  ]);
  final base = results[0], left = results[1], right = results[2];
  if (left == null && right == null) {
    throw const MergeLoadException(
        'Neither the left nor the right file exists.');
  }
  final total = (base?.length ?? 0) + (left?.length ?? 0) + (right?.length ?? 0);
  final merged = total > _isolateThreshold
      ? await _mergeInIsolate(base, left, right)
      : _decodeAndMerge(base, left, right);
  return LoadedMerge(
    document: merged.$1,
    format: merged.$2,
    baseMissing: base == null,
    leftMissing: left == null,
    rightMissing: right == null,
    outputBytes: output == null ? null : results[3],
  );
}

/// Top-level so the isolate closure captures only the byte lists.
Future<(MergeDocument, TextFormat)> _mergeInIsolate(
        List<int>? base, List<int>? left, List<int>? right) =>
    Isolate.run(() => _decodeAndMerge(base, left, right));

(MergeDocument, TextFormat) _decodeAndMerge(
    List<int>? base, List<int>? left, List<int>? right) {
  DecodedText decode(List<int>? bytes) =>
      bytes == null ? DecodedText.empty : DecodedText.decode(bytes);
  final b = decode(base), l = decode(left), r = decode(right);
  // A missing or empty base says nothing about how lines should end, so
  // take the format from a side that has text.
  final format = b.lines.isNotEmpty
      ? b.format
      : l.lines.isNotEmpty
          ? l.format
          : r.format;
  return (MergeDocument.merge(b.lines, l.lines, r.lines), format);
}

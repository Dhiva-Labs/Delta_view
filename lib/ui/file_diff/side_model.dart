/// One side of a file comparison as the view edits it: its text, the
/// format it will be saved in, and what is on disk.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../compare/diff_side.dart';
import '../../diff/line_diff.dart';
import '../../diff/text_codec.dart';

class SideModel {
  SideModel(this.side);

  /// Where the text came from. Replaced when a pasted side is saved to a
  /// file, after which it behaves like any file side.
  DiffSide side;

  /// Holds the side's current text, in view mode as well as edit mode.
  final controller = DiffEditingController();
  final focusNode = FocusNode(debugLabel: 'diff editor');

  /// The text as last loaded or saved.
  String savedText = '';

  /// The format the next save writes, and the one on disk.
  TextFormat format = const TextFormat();
  TextFormat savedFormat = const TextFormat();

  /// Per-line endings when the file mixes LF and CRLF.
  MixedEndings? mixed;

  bool exists = true;

  /// Whether a save can write back in place (false for archives and
  /// read-only places; those, and pasted text, save with "Save as").
  bool writable = false;

  /// The bytes last read from or written to disk, to tell our own saves
  /// from changes made by other programs.
  Uint8List? diskBytes;

  /// A newer version on disk while this side has unsaved edits.
  Uint8List? pendingDiskBytes;

  bool _dirty = false;
  bool get dirty => _dirty;

  String get text => controller.text;
  String get label => side.label;
  bool get isMemory => side.isMemory;
  bool get canSaveInPlace => !isMemory && writable;

  /// Recomputes [dirty]; returns true when it changed.
  bool updateDirty() {
    final dirty =
        text != savedText || (!isMemory && exists && format != savedFormat);
    if (dirty == _dirty) return false;
    _dirty = dirty;
    return true;
  }

  /// The text as the diff should see it: with its real line endings when
  /// line endings count, so CRLF and LF lines differ.
  String diffText(CompareOptions options) => options.ignoreLineEndings
      ? text
      : applyLineEndings(text, format.lineEnding, mixed: mixed);

  /// Takes [decoded] as the saved state. The caller sets the controller's
  /// text.
  void loaded(DecodedText decoded, {Uint8List? bytes, bool exists = true}) {
    savedText = decoded.text;
    format = savedFormat = decoded.format;
    mixed = decoded.mixed;
    diskBytes = bytes;
    pendingDiskBytes = null;
    this.exists = exists;
  }

  /// Records a successful save of [bytes] in [format].
  void saved(Uint8List bytes) {
    savedText = text;
    savedFormat = format;
    // Re-read the endings from what was written, so the next save of a
    // mixed file starts from the new lines.
    mixed =
        format.lineEnding == LineEnding.mixed ? decodeText(bytes).mixed : null;
    diskBytes = bytes;
    pendingDiskBytes = null;
    exists = true;
    updateDirty();
  }

  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}

/// Paints the text of an editor line by line. Set by the edit view.
typedef EditorSpanBuilder = TextSpan Function(
    BuildContext context, String text, TextStyle? style);

/// A [TextEditingController] whose text is painted by the edit view
/// (syntax colours, change emphasis, search matches, tab stops).
class DiffEditingController extends TextEditingController {
  EditorSpanBuilder? spanBuilder;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final builder = spanBuilder;
    // While an input method is composing, let the default show it.
    if (builder == null || (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    return builder(context, text, style);
  }
}

/// Watches one local file for changes by other programs. Watches the
/// folder rather than the file, because editors often save by writing a
/// new file and renaming it over the old one, which ends a file watch.
class FileWatcher {
  FileWatcher(String path, this.onChange) : path = p.normalize(path) {
    _start();
  }

  final String path;
  final VoidCallback onChange;
  StreamSubscription<FileSystemEvent>? _sub;
  Timer? _debounce;

  void _start() {
    if (!FileSystemEntity.isWatchSupported) return;
    final dir = Directory(p.dirname(path));
    try {
      _sub = dir.watch().listen((event) {
        final hit = p.equals(p.normalize(event.path), path) ||
            (event is FileSystemMoveEvent &&
                event.destination != null &&
                p.equals(p.normalize(event.destination!), path));
        if (!hit) return;
        // A save is often several events (truncate, write, rename).
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 300), onChange);
      }, onError: (Object _) {});
    } on FileSystemException {
      // Out of watches, or the folder is gone: changes go unnoticed.
    }
  }

  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
  }
}

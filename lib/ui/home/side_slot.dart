/// One side of the home screen's form: the [SourceSpec] it holds plus the
/// text in its path field. Local sources are what the user typed (after
/// `~` expansion); archive and remote sources come from their pickers.
library;

import 'package:flutter/widgets.dart';

import '../../cli/user_paths.dart';
import '../../compare/comparison.dart';

/// What a slot must hold for the chosen mode.
enum SlotKind { folder, file }

/// Why a slot is not ready, for the status line and the Compare button.
enum SlotStatus {
  empty,
  ready,
  missing,

  /// A folder where a file is wanted, or the other way round.
  wrongKind,
}

class SideSlot extends ChangeNotifier {
  SideSlot(this.label, {this.hint});

  /// "Left", "Base", "Output"…
  final String label;

  /// Replaces the generic "Drop a folder here" hint.
  final String? hint;

  final controller = TextEditingController();

  SourceSpec? _spec;
  SourceSpec? get spec => _spec;

  bool get isEmpty => _spec == null;

  /// What the user picked through a dialog (archive, remote) rather than
  /// typed; the path field then shows the description read-only.
  bool get isPicked => _spec != null && _spec is! LocalSource;

  String? get localPath => switch (_spec) {
        LocalSource s => s.path,
        _ => null,
      };

  /// Sets the source, mirroring a local path into the field. Null clears.
  void setSpec(SourceSpec? spec) {
    _spec = spec;
    final text = spec is LocalSource ? spec.path : '';
    if (controller.text != text) {
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    notifyListeners();
  }

  /// Called as the user types: the field keeps what was typed and the
  /// source is the expanded path.
  void setTypedPath(String text) {
    final expanded = expandUserPath(text);
    final next = expanded.isEmpty ? null : LocalSource(expanded);
    if (next == _spec) return;
    _spec = next;
    notifyListeners();
  }

  void clear() => setSpec(null);

  /// Drops a local source that cannot be used for [kind] (keeps archive
  /// and remote sources: whether they fit is only known once opened).
  void keepIfFits(SlotKind kind) {
    final path = localPath;
    if (path == null) return;
    if (status(kind) == SlotStatus.wrongKind) clear();
  }

  SlotStatus status(SlotKind kind, {bool mayBeMissing = false}) {
    final spec = _spec;
    if (spec == null) return SlotStatus.empty;
    if (spec is! LocalSource) return SlotStatus.ready;
    return switch (pathKindOf(spec.path)) {
      PathKind.directory =>
        kind == SlotKind.folder ? SlotStatus.ready : SlotStatus.wrongKind,
      PathKind.file =>
        kind == SlotKind.file ? SlotStatus.ready : SlotStatus.wrongKind,
      PathKind.missing => mayBeMissing ? SlotStatus.ready : SlotStatus.missing,
    };
  }

  void swapWith(SideSlot other) {
    final mine = _spec;
    final myText = controller.text;
    final theirText = other.controller.text;
    _spec = other._spec;
    other._spec = mine;
    controller.text = theirText;
    other.controller.text = myText;
    notifyListeners();
    other.notifyListeners();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

/// What a tab compares. Plain data: it can be saved to JSON (recent
/// comparisons, session restore) and turned into a view by
/// `buildComparisonView` in ui/comparison_view.dart.
library;

import 'sources/source_spec.dart';

export 'sources/source_spec.dart';

sealed class Comparison {
  const Comparison();

  /// Tab title, e.g. `app ↔ app-v2`.
  String get title;

  Map<String, Object?> toJson();

  /// False for comparisons that should not appear in recents or be
  /// restored (e.g. large pasted text).
  bool get rememberable => true;

  static Comparison? fromJson(Object? json) {
    if (json is! Map) return null;
    SourceSpec? s(String key) => SourceSpec.fromJson(json[key]);
    switch (json['type']) {
      case 'folders':
        final l = s('left'), r = s('right');
        return l == null || r == null ? null : FolderComparison(l, r);
      case 'files':
        final l = s('left'), r = s('right');
        return l == null || r == null ? null : FileComparison(l, r);
      case 'text':
        return TextComparison(
          leftText: '${json['leftText'] ?? ''}',
          rightText: '${json['rightText'] ?? ''}',
        );
      case 'threeWay':
        final l = s('left'), b = s('base'), r = s('right');
        if (l == null || b == null || r == null) return null;
        return ThreeWayComparison(
            left: l, base: b, right: r, output: s('output'));
    }
    return null;
  }
}

class FolderComparison extends Comparison {
  const FolderComparison(this.left, this.right);

  final SourceSpec left;
  final SourceSpec right;

  @override
  String get title => '${left.label} ↔ ${right.label}';

  @override
  Map<String, Object?> toJson() =>
      {'type': 'folders', 'left': left.toJson(), 'right': right.toJson()};
}

class FileComparison extends Comparison {
  const FileComparison(this.left, this.right, {this.titleOverride});

  final SourceSpec left;
  final SourceSpec right;

  /// e.g. the relative path when opened from a folder comparison.
  final String? titleOverride;

  @override
  String get title => titleOverride ?? '${left.label} ↔ ${right.label}';

  @override
  Map<String, Object?> toJson() =>
      {'type': 'files', 'left': left.toJson(), 'right': right.toJson()};
}

/// Two pieces of text that are not files (pasted from the clipboard).
class TextComparison extends Comparison {
  const TextComparison({
    this.leftText = '',
    this.rightText = '',
    this.leftLabel = 'Left text',
    this.rightLabel = 'Right text',
  });

  final String leftText;
  final String rightText;
  final String leftLabel;
  final String rightLabel;

  @override
  String get title => 'Text compare';

  @override
  bool get rememberable => leftText.length + rightText.length < 256 * 1024;

  @override
  Map<String, Object?> toJson() =>
      {'type': 'text', 'leftText': leftText, 'rightText': rightText};
}

/// A three-way merge: [left] and [right] both changed [base]; the result is
/// written to [output] (or, when null, to whichever side the user picks).
class ThreeWayComparison extends Comparison {
  const ThreeWayComparison({
    required this.left,
    required this.base,
    required this.right,
    this.output,
  });

  final SourceSpec left;
  final SourceSpec base;
  final SourceSpec right;
  final SourceSpec? output;

  @override
  String get title => 'Merge ${output?.label ?? base.label}';

  @override
  Map<String, Object?> toJson() => {
        'type': 'threeWay',
        'left': left.toJson(),
        'base': base.toJson(),
        'right': right.toJson(),
        'output': output?.toJson(),
      };
}

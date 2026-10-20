/// Turns a [Comparison] into the view that shows it. The one place that
/// decides which view handles what.
library;

import 'package:flutter/material.dart';

import '../compare/comparison.dart';
import '../compare/diff_side.dart';
import 'file_diff_view.dart';
import 'folder_diff_view.dart';
import 'image/image_compare_view.dart';
import 'merge/three_way_view.dart';
import 'structured/structured_diff_view.dart';

IconData comparisonIcon(Comparison comparison) => switch (comparison) {
      FolderComparison c => c.left is ArchiveSource || c.right is ArchiveSource
          ? Icons.inventory_2_outlined
          : c.left is SftpSource || c.right is SftpSource
              ? Icons.cloud_outlined
              : Icons.folder_copy_outlined,
      FileComparison c => isImageFile(c.left.label) && isImageFile(c.right.label)
          ? Icons.image_outlined
          : isStructuredFile(c.left.label) && isStructuredFile(c.right.label)
              ? Icons.account_tree_outlined
              : Icons.description_outlined,
      TextComparison _ => Icons.content_paste_outlined,
      ThreeWayComparison _ => Icons.merge_type,
    };

Widget buildComparisonView(Comparison comparison, {VoidCallback? onBack}) {
  switch (comparison) {
    case FolderComparison c:
      return FolderDiffView(left: c.left, right: c.right, onBack: onBack);
    case FileComparison c:
      final left = DiffSide.source(c.left);
      final right = DiffSide.source(c.right);
      final title = c.titleOverride;
      if (isImageFile(c.left.label) && isImageFile(c.right.label)) {
        return ImageCompareView(
            left: left, right: right, title: title, onBack: onBack);
      }
      if (isStructuredFile(c.left.label) && isStructuredFile(c.right.label)) {
        return StructuredDiffView(
            left: left, right: right, title: title, onBack: onBack);
      }
      return FileDiffView(
          left: left, right: right, title: title, onBack: onBack);
    case TextComparison c:
      return FileDiffView(
        left: DiffSide.memory(text: c.leftText, label: c.leftLabel),
        right: DiffSide.memory(text: c.rightText, label: c.rightLabel),
        title: c.title,
        startEditing: c.leftText.isEmpty && c.rightText.isEmpty,
        onBack: onBack,
      );
    case ThreeWayComparison c:
      return ThreeWayMergeView(comparison: c, onBack: onBack);
  }
}

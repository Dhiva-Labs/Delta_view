import 'package:flutter/material.dart';

import '../../compare/diff_side.dart';
import '../file_diff_view.dart';

/// Whether [name] is a JSON / YAML / CSV file the structured view handles.
/// Placeholder: returns false until structured diff lands.
bool isStructuredFile(String name) => false;

/// Key-aware comparison of JSON, YAML and CSV, with a switch back to the
/// plain text diff. Placeholder that shows the text diff view.
class StructuredDiffView extends StatelessWidget {
  const StructuredDiffView({
    super.key,
    required this.left,
    required this.right,
    this.title,
    this.onBack,
  });

  final DiffSide left;
  final DiffSide right;
  final String? title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) =>
      FileDiffView(left: left, right: right, title: title, onBack: onBack);
}

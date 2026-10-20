import 'package:flutter/material.dart';

import '../../compare/diff_side.dart';
import '../file_diff_view.dart';

/// Whether [name] is an image the image compare view can show.
/// Placeholder: returns false until image compare lands, so images keep
/// going to the text diff view.
bool isImageFile(String name) => false;

/// Side-by-side, swipe, onion-skin and difference views of two images.
/// Placeholder that shows the text diff view.
class ImageCompareView extends StatelessWidget {
  const ImageCompareView({
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

import 'package:flutter/material.dart';

import '../../compare/comparison.dart';

/// Three-way merge: left and right changes against a common base, merged
/// into an editable result. Placeholder until the merge view lands.
class ThreeWayMergeView extends StatelessWidget {
  const ThreeWayMergeView({super.key, required this.comparison, this.onBack});

  final ThreeWayComparison comparison;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.merge_type, size: 42),
          const SizedBox(height: 12),
          Text('Three-way merge is not available yet.',
              style: Theme.of(context).textTheme.titleMedium),
          if (onBack != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onBack, child: const Text('Back')),
          ],
        ],
      ),
    );
  }
}

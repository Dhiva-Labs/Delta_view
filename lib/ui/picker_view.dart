/// The content of one comparison tab. The home screen itself lives in
/// ui/home/; this file keeps [TabRoot] and re-exports [PickerView] so
/// existing imports keep working.
library;

import 'package:flutter/material.dart';

import '../compare/comparison.dart';
import 'comparison_view.dart';
import 'home/home_screen.dart';
import 'shell.dart';
import 'sources/source_pickers.dart';

export 'home/home_screen.dart' show CompareMode, PickerView;

/// Starts as a picker (or straight at [initial]), becomes a comparison
/// view, and can go back for a fresh pick. Every comparison passes through
/// [ensureComparisonReady] first, so remote sides restored from recents or
/// the last session get their password asked for again.
class TabRoot extends StatefulWidget {
  const TabRoot({super.key, required this.tabId, this.initial});

  final int tabId;
  final Comparison? initial;

  @override
  State<TabRoot> createState() => _TabRootState();
}

class _TabRootState extends State<TabRoot> {
  Comparison? _comparison;

  /// The last comparison, kept so the picker can start from its paths.
  Comparison? _previous;

  /// True while [initial] is being readied: nothing is shown yet rather
  /// than a picker that flashes before the view appears.
  bool _readyingInitial = false;

  /// Ignores the result of a readying that a newer one superseded.
  int _request = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _readyingInitial = true;
      // ensureComparisonReady may show a dialog, which needs the tree built.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(initial);
      });
    }
  }

  Future<void> _open(Comparison comparison) async {
    final request = ++_request;
    Comparison? ready;
    try {
      ready = await ensureComparisonReady(context, comparison);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text('Could not open the comparison: $e'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
    if (!mounted || request != _request) return;
    setState(() {
      _readyingInitial = false;
      if (ready == null) {
        // Cancelled: stay on the picker, seeded with what was asked for.
        _previous = comparison;
        _comparison = null;
      } else {
        _comparison = ready;
      }
    });
    TabScope.maybeOf(context)?.setComparison(ready);
  }

  void _backToPicker() {
    setState(() {
      _previous = _comparison;
      _comparison = null;
    });
    TabScope.maybeOf(context)?.setComparison(null);
  }

  @override
  Widget build(BuildContext context) {
    final comparison = _comparison;
    final Widget child;
    if (_readyingInitial) {
      child = const SizedBox.shrink(key: ValueKey('readying'));
    } else if (comparison == null) {
      child = PickerView(
        key: const ValueKey('pick'),
        previous: _previous,
        onCompare: _open,
      );
    } else {
      child = KeyedSubtree(
        key: ValueKey(comparisonKey(comparison)),
        child: buildComparisonView(comparison, onBack: _backToPicker),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: child,
    );
  }
}

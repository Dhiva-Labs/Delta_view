/// The toolbar popover for this view's compare rules. They start as the
/// app's defaults (Settings) and can be changed here for one comparison.
library;

import 'package:flutter/material.dart';

import '../../diff/compare_options.dart';

class CompareRulesButton extends StatelessWidget {
  const CompareRulesButton({
    super.key,
    required this.options,
    required this.overridden,
    required this.onChanged,
    required this.onReset,
  });

  final CompareOptions options;

  /// Whether this view uses its own rules rather than the defaults.
  final bool overridden;
  final ValueChanged<CompareOptions> onChanged;
  final VoidCallback onReset;

  static const _whitespaceLabels = {
    WhitespaceMode.exact: 'Compare all whitespace',
    WhitespaceMode.trailing: 'Ignore trailing whitespace',
    WhitespaceMode.changes: 'Ignore changes in whitespace',
    WhitespaceMode.all: 'Ignore all whitespace',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      menuChildren: [
        for (final mode in WhitespaceMode.values)
          RadioMenuButton<WhitespaceMode>(
            value: mode,
            groupValue: options.whitespace,
            closeOnActivate: false,
            onChanged: (m) => onChanged(options.copyWith(whitespace: m)),
            child: Text(_whitespaceLabels[mode]!),
          ),
        const Divider(height: 8),
        CheckboxMenuButton(
          value: options.ignoreCase,
          closeOnActivate: false,
          onChanged: (v) => onChanged(options.copyWith(ignoreCase: v)),
          child: const Text('Ignore case'),
        ),
        CheckboxMenuButton(
          value: options.ignoreLineEndings,
          closeOnActivate: false,
          onChanged: (v) => onChanged(options.copyWith(ignoreLineEndings: v)),
          child: const Text('Ignore line endings (CRLF / LF)'),
        ),
        CheckboxMenuButton(
          value: options.ignoreBlankLines,
          closeOnActivate: false,
          onChanged: (v) => onChanged(options.copyWith(ignoreBlankLines: v)),
          child: const Text('Ignore blank lines'),
        ),
        const Divider(height: 8),
        MenuItemButton(
          onPressed: overridden ? onReset : null,
          leadingIcon: const Icon(Icons.restart_alt, size: 18),
          child: const Text('Use the default rules'),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: 'Compare rules: ${options.summary}',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: Badge(
          isLabelVisible: overridden,
          smallSize: 7,
          backgroundColor: scheme.primary,
          child: const Icon(Icons.tune, size: 20),
        ),
      ),
    );
  }
}

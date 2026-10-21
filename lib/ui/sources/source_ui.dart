/// Small pieces shared by the archive and remote pickers.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';

/// Runs [task] behind a small "working" dialog with a Cancel button. The
/// dialog only appears when the task takes longer than a moment, so quick
/// tasks do not flash it. Returns null when the user cancels; a result
/// that arrives after that is handed to [discard] (to close a connection,
/// say). Errors from [task] are rethrown.
Future<T?> runWithProgress<T>(
  BuildContext context, {
  required String message,
  required Future<T> Function() task,
  void Function(T value)? discard,
}) async {
  final navigator = Navigator.of(context);
  var cancelled = false;
  final cancelSignal = Completer<void>();
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ProgressDialog(
      message: message,
      onCancel: () {
        cancelled = true;
        cancelSignal.complete();
      },
    ),
  );
  final show = Timer(const Duration(milliseconds: 180), () {
    if (!cancelled) navigator.push(route);
  });
  final work = task();
  try {
    final value = await Future.any([
      work,
      cancelSignal.future.then((_) => null),
    ]);
    if (cancelled) {
      unawaited(work.then((v) => discard?.call(v), onError: (_) {}));
      return null;
    }
    return value as T;
  } finally {
    show.cancel();
    if (route.isActive) navigator.removeRoute(route);
  }
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.message, required this.onCancel});

  final String message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
        child: Row(
          children: [
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 18),
            Expanded(child: Text(message)),
          ],
        ),
      ),
      actions: [TextButton(onPressed: onCancel, child: const Text('Cancel'))],
    );
  }
}

/// Explains why something could not be opened.
Future<void> showSourceError(
    BuildContext context, String title, Object error) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.error_outline,
          color: Theme.of(context).colorScheme.error),
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text('$error'),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// An error message in a tinted, rounded box, for dialogs.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: TextStyle(color: scheme.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}

/// A host key fingerprint: monospace, selectable, with a copy button.
class FingerprintView extends StatelessWidget {
  const FingerprintView({
    super.key,
    required this.label,
    required this.fingerprint,
    this.emphasis,
  });

  final String label;

  /// Without the `SHA256:` prefix; it is shown with it, as ssh prints it.
  final String fingerprint;

  /// Tints the box, e.g. red for a key that was refused.
  final Color? emphasis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = 'SHA256:$fingerprint';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: (emphasis ?? scheme.primary).withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: (emphasis ?? scheme.outlineVariant).withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                SelectableText(text, style: monoStyle),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy fingerprint',
            iconSize: 18,
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
    );
  }
}

String formatBytes(int bytes) {
  const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  if (bytes < 1024) return bytes == 1 ? '1 byte' : '$bytes bytes';
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

String formatShortDate(DateTime date) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final local = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.day} ${months[local.month - 1]} ${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

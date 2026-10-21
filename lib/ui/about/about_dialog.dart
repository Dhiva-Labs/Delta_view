import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../brand/app_info.dart';
import '../brand/app_logo.dart';
import 'open_url.dart';

Future<void> showAboutDeltaView(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _AboutDialog(),
  );
}

class _AboutDialog extends StatelessWidget {
  const _AboutDialog();

  Future<void> _openRepository(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (await openUrl(appRepositoryUrl)) return;
    await Clipboard.setData(const ClipboardData(text: appRepositoryUrl));
    messenger?.showSnackBar(const SnackBar(
      content: Text('No browser found. The link was copied instead.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const AppLogo(size: 64),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(appName,
                            style: textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer
                                    .withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text('Version $appVersion',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: scheme.onPrimaryContainer)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(appDescription,
                  style: textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant, height: 1.45)),
              const SizedBox(height: 18),
              _LinkRow(
                icon: Icons.code,
                label: 'Source and issues',
                value: appRepositoryUrl.replaceFirst('https://', ''),
                onTap: () => _openRepository(context),
                onCopy: () async {
                  await Clipboard.setData(
                      const ClipboardData(text: appRepositoryUrl));
                },
              ),
              const SizedBox(height: 8),
              _LinkRow(
                icon: Icons.gavel_outlined,
                label: 'Licence',
                value: appLicense,
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: appName,
                  applicationVersion: appVersion,
                  applicationLegalese: appCopyright,
                  applicationIcon: const Padding(
                    padding: EdgeInsets.all(8),
                    child: AppLogo(size: 48),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Text(appCopyright,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.onCopy,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: Row(
            children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500)),
                    Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5)),
                  ],
                ),
              ),
              if (onCopy != null)
                IconButton(
                  tooltip: 'Copy link',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_outlined),
                )
              else
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

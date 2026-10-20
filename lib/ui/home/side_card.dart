/// The Left / Right (and Base / Output) cards on the home screen: a path
/// field with a Browse button, a status line, and a drop target.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../cli/user_paths.dart';
import '../../compare/comparison.dart';
import '../sources/source_pickers.dart';
import 'side_slot.dart';

/// How a drag in progress relates to this card.
enum DropHighlight { none, elsewhere, here }

class SideCard extends StatefulWidget {
  const SideCard({
    super.key,
    required this.slot,
    required this.kind,
    this.highlight = DropHighlight.none,
    this.onSubmit,
    this.optional = false,
    this.mayBeMissing = false,
    this.saveDialog = false,
  });

  final SideSlot slot;
  final SlotKind kind;
  final DropHighlight highlight;

  /// Enter in the path field.
  final VoidCallback? onSubmit;

  /// Shown as "(optional)" and never blocks the Compare button.
  final bool optional;

  /// A path that does not exist yet is fine (merge output).
  final bool mayBeMissing;

  /// Browse with a save dialog instead of an open dialog.
  final bool saveDialog;

  @override
  State<SideCard> createState() => _SideCardState();
}

class _SideCardState extends State<SideCard> {
  bool _hovered = false;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.slot.addListener(_changed);
  }

  @override
  void didUpdateWidget(SideCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slot != widget.slot) {
      oldWidget.slot.removeListener(_changed);
      widget.slot.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.slot.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _browse() async {
    final slot = widget.slot;
    final current = slot.localPath;
    final startIn = current == null
        ? null
        : pathKindOf(current) == PathKind.directory
            ? current
            : p.dirname(current);
    String? path;
    if (widget.saveDialog) {
      final location = await getSaveLocation(
        initialDirectory: startIn,
        suggestedName: current == null ? null : p.basename(current),
      );
      path = location?.path;
    } else if (widget.kind == SlotKind.folder) {
      path = await getDirectoryPath(initialDirectory: startIn);
    } else {
      final file = await openFile(initialDirectory: startIn);
      path = file?.path;
    }
    if (path == null || !mounted) return;
    slot.setSpec(LocalSource(path));
  }

  Future<void> _pickArchive() async {
    final source = await pickArchiveSource(context);
    if (source != null && mounted) widget.slot.setSpec(source);
  }

  Future<void> _pickRemote() async {
    final source = await pickRemoteSource(context,
        folder: widget.kind == SlotKind.folder);
    if (source != null && mounted) widget.slot.setSpec(source);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final slot = widget.slot;
    final status = slot.status(widget.kind, mayBeMissing: widget.mayBeMissing);
    final here = widget.highlight == DropHighlight.here;
    final elsewhere = widget.highlight == DropHighlight.elsewhere;
    final ready = status == SlotStatus.ready;
    final showMenu = archivePickerAvailable || remotePickerAvailable;

    final borderColor = here
        ? scheme.primary
        : ready
            ? scheme.primary.withValues(alpha: 0.5)
            : elsewhere
                ? scheme.primary.withValues(alpha: 0.35)
                : _hovered || _focus.hasFocus
                    ? scheme.outline.withValues(alpha: 0.6)
                    : scheme.outlineVariant.withValues(alpha: 0.8);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: here
              ? scheme.primaryContainer.withValues(alpha: 0.35)
              : Theme.of(context).cardTheme.color,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(width: here ? 2 : 1.5, color: borderColor),
          boxShadow: _hovered && !here
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  )
                ]
              : const [],
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _icon(status),
                        size: 20,
                        color: ready ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        slot.label.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                          color: ready ? scheme.primary : scheme.onSurfaceVariant,
                        ),
                      ),
                      if (widget.optional) ...[
                        const SizedBox(width: 6),
                        Text('optional',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant
                                    .withValues(alpha: 0.8))),
                      ],
                      const Spacer(),
                      if (showMenu)
                        MenuAnchor(
                          menuChildren: [
                            if (archivePickerAvailable)
                              MenuItemButton(
                                leadingIcon:
                                    const Icon(Icons.inventory_2_outlined),
                                onPressed: _pickArchive,
                                child: const Text('Archive…'),
                              ),
                            if (remotePickerAvailable)
                              MenuItemButton(
                                leadingIcon: const Icon(Icons.cloud_outlined),
                                onPressed: _pickRemote,
                                child: const Text('Remote (SFTP)…'),
                              ),
                          ],
                          builder: (context, controller, _) => IconButton(
                            tooltip: 'Other sources',
                            iconSize: 18,
                            visualDensity: VisualDensity.compact,
                            onPressed: () => controller.isOpen
                                ? controller.close()
                                : controller.open(),
                            icon: const Icon(Icons.more_horiz),
                          ),
                        ),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 120),
                        opacity: slot.isEmpty ? 0 : 1,
                        child: IconButton(
                          tooltip: 'Clear',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          onPressed: slot.isEmpty ? null : slot.clear,
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(
                      children: [
                        Expanded(child: _field(context, status)),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _browse,
                          style: OutlinedButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            minimumSize: const Size(0, 40),
                          ),
                          icon: Icon(
                              widget.kind == SlotKind.folder
                                  ? Icons.folder_open_outlined
                                  : Icons.file_open_outlined,
                              size: 18),
                          label: const Text('Browse'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _statusLine(context, status),
                ],
              ),
            ),
            if (here)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.download_outlined, color: scheme.primary),
                        const SizedBox(width: 8),
                        Text('Drop to use as ${slot.label}',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: scheme.primary)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  IconData _icon(SlotStatus status) {
    final spec = widget.slot.spec;
    if (spec is ArchiveSource) return Icons.inventory_2_outlined;
    if (spec is SftpSource) return Icons.cloud_outlined;
    final ready = status == SlotStatus.ready;
    return widget.kind == SlotKind.folder
        ? (ready ? Icons.folder : Icons.folder_outlined)
        : (ready ? Icons.description : Icons.description_outlined);
  }

  Widget _field(BuildContext context, SlotStatus status) {
    final scheme = Theme.of(context).colorScheme;
    final slot = widget.slot;
    final picked = slot.isPicked;
    final (statusIcon, statusColor) = switch (status) {
      SlotStatus.ready => (Icons.check_circle, scheme.primary),
      SlotStatus.missing => (Icons.error_outline, scheme.error),
      SlotStatus.wrongKind => (Icons.warning_amber_rounded, scheme.tertiary),
      SlotStatus.empty => (null, scheme.onSurfaceVariant),
    };
    if (picked) {
      return InputDecorator(
        decoration: _decoration(context, statusIcon, statusColor),
        child: Text(slot.spec!.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13)),
      );
    }
    return TextField(
      controller: slot.controller,
      focusNode: _focus,
      style: const TextStyle(fontSize: 13),
      onChanged: slot.setTypedPath,
      onSubmitted: (_) => widget.onSubmit?.call(),
      decoration: _decoration(context, statusIcon, statusColor).copyWith(
        hintText: widget.slot.hint ??
            (widget.kind == SlotKind.folder
                ? 'Type or paste a folder path (~ works)'
                : 'Type or paste a file path (~ works)'),
      ),
    );
  }

  InputDecoration _decoration(
      BuildContext context, IconData? statusIcon, Color statusColor) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerLowest.withValues(alpha: 0.6),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      hintStyle: TextStyle(
          fontSize: 13, color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      suffixIcon: statusIcon == null
          ? null
          : Icon(statusIcon, size: 18, color: statusColor),
      suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 0),
    );
  }

  Widget _statusLine(BuildContext context, SlotStatus status) {
    final scheme = Theme.of(context).colorScheme;
    final slot = widget.slot;
    final spec = slot.spec;
    final noun = widget.kind == SlotKind.folder ? 'folder' : 'file';
    final (text, color) = switch (status) {
      SlotStatus.empty => (
          widget.optional
              ? 'Leave empty to save over ${widget.kind == SlotKind.folder ? "the left side" : "Left"}'
              : 'Drop a $noun here, paste a path or browse',
          scheme.onSurfaceVariant
        ),
      SlotStatus.missing => (
          widget.mayBeMissing ? 'Will be created' : 'Nothing at this path',
          scheme.error
        ),
      SlotStatus.wrongKind => (
          widget.kind == SlotKind.folder
              ? 'This is a file. Switch to Files to compare it.'
              : 'This is a folder. Switch to Folders to compare it.',
          scheme.tertiary
        ),
      SlotStatus.ready => (
          switch (spec) {
            ArchiveSource _ => 'Inside an archive',
            SftpSource s => 'On ${s.authority}',
            LocalSource s => widget.mayBeMissing &&
                    pathKindOf(s.path) == PathKind.missing
                ? 'Will be created'
                : '${abbreviateHome(p.dirname(s.path))}${p.separator}',
            _ => '',
          },
          scheme.onSurfaceVariant
        ),
    };
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 8),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: color),
      ),
    );
  }
}

/// A small file browser over any [FileSource], for choosing a folder inside
/// an archive or a folder or file on a server.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../compare/sources/file_source.dart';
import 'source_ui.dart';

/// Shows the browser and returns the chosen path relative to [source]'s
/// root ('' for the root itself), or null when cancelled.
Future<String?> showSourceBrowser(
  BuildContext context, {
  required FileSource source,
  required String title,
  required String rootLabel,
  String initialPath = '',
  bool pickFolder = true,
  String? subtitle,
  String Function(String relative)? displayPath,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => SourceBrowserDialog(
      source: source,
      title: title,
      subtitle: subtitle,
      rootLabel: rootLabel,
      initialPath: initialPath,
      pickFolder: pickFolder,
      displayPath: displayPath,
    ),
  );
}

class SourceBrowserDialog extends StatefulWidget {
  const SourceBrowserDialog({
    super.key,
    required this.source,
    required this.title,
    required this.rootLabel,
    this.subtitle,
    this.initialPath = '',
    this.pickFolder = true,
    this.displayPath,
  });

  final FileSource source;
  final String title;
  final String? subtitle;

  /// The first breadcrumb, e.g. the archive's name or `/`.
  final String rootLabel;

  /// Relative to the source root, with `/` separators.
  final String initialPath;

  /// Choose a folder (files are shown dimmed) or a file.
  final bool pickFolder;

  /// How a relative path is shown and typed in the path field, e.g. as an
  /// absolute path on a server. Defaults to the relative path itself.
  final String Function(String relative)? displayPath;

  @override
  State<SourceBrowserDialog> createState() => _SourceBrowserDialogState();
}

class _SourceBrowserDialogState extends State<SourceBrowserDialog> {
  late String _path = widget.initialPath;
  List<SourceEntry>? _entries;
  Object? _error;

  /// The folder that failed to load, for "Try again".
  String? _failedPath;
  bool _loading = false;
  String? _selectedFile;
  bool _editingPath = false;
  final _pathController = TextEditingController();
  final _pathFocus = FocusNode();

  /// Stops a slow listing from overwriting a newer one.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  @override
  void dispose() {
    _pathController.dispose();
    _pathFocus.dispose();
    super.dispose();
  }

  String _display(String relative) =>
      widget.displayPath?.call(relative) ??
      (relative.isEmpty ? widget.rootLabel : relative);

  Future<void> _load(String path) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.source.list(path);
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted || generation != _generation) return;
      setState(() {
        _path = path;
        _entries = entries;
        _failedPath = null;
        _selectedFile = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e;
        _failedPath = path;
        _loading = false;
      });
    }
  }

  void _open(String path) {
    _editingPath = false;
    _load(path);
  }

  String _child(String name) => _path.isEmpty ? name : '$_path/$name';

  String get _parent {
    final i = _path.lastIndexOf('/');
    return i < 0 ? '' : _path.substring(0, i);
  }

  void _submitPath(String typed) {
    var text = typed.trim();
    if (widget.displayPath != null && text.startsWith('/')) {
      // Typed as an absolute server path; the root is '/'.
      text = text.substring(1);
    }
    final parts = [
      for (final part in text.replaceAll('\\', '/').split('/'))
        if (part.isNotEmpty && part != '.') part,
    ];
    final normalized = <String>[];
    for (final part in parts) {
      if (part == '..') {
        if (normalized.isNotEmpty) normalized.removeLast();
      } else {
        normalized.add(part);
      }
    }
    _open(normalized.join('/'));
  }

  void _confirm() {
    if (widget.pickFolder) {
      Navigator.pop(context, _path);
    } else if (_selectedFile != null) {
      Navigator.pop(context, _child(_selectedFile!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canConfirm = widget.pickFolder
        ? _error == null && _entries != null
        : _selectedFile != null;
    final folderName = _path.isEmpty ? widget.rootLabel : p.posix.basename(_path);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title,
                  style: Theme.of(context).textTheme.titleLarge),
              if (widget.subtitle != null) ...[
                const SizedBox(height: 4),
                Text(widget.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
              const SizedBox(height: 14),
              _toolbar(context),
              const SizedBox(height: 8),
              Expanded(child: _listing(context)),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.pickFolder
                          ? 'Compare the contents of “$folderName”.'
                          : _selectedFile == null
                              ? 'Choose a file.'
                              : 'Compare “$_selectedFile”.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: canConfirm ? _confirm : null,
                    icon: Icon(widget.pickFolder
                        ? Icons.folder_open_outlined
                        : Icons.description_outlined),
                    label: Text(
                        widget.pickFolder ? 'Use this folder' : 'Use this file'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Up one folder',
            iconSize: 20,
            onPressed: _path.isEmpty ? null : () => _open(_parent),
            icon: const Icon(Icons.arrow_upward),
          ),
          Expanded(
            child: _editingPath ? _pathField() : _breadcrumbs(context),
          ),
          IconButton(
            tooltip: _editingPath ? 'Show breadcrumbs' : 'Type a path',
            iconSize: 20,
            onPressed: () {
              setState(() {
                _editingPath = !_editingPath;
                if (_editingPath) {
                  _pathController.text = _display(_path);
                  _pathFocus.requestFocus();
                }
              });
            },
            icon: Icon(_editingPath ? Icons.close : Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            iconSize: 20,
            onPressed: _loading ? null : () => _load(_failedPath ?? _path),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _pathField() {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            setState(() => _editingPath = false),
      },
      child: TextField(
        controller: _pathController,
        focusNode: _pathFocus,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: 'Path, then Enter',
        ),
        onSubmitted: _submitPath,
      ),
    );
  }

  Widget _breadcrumbs(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = _path.isEmpty ? <String>[] : _path.split('/');
    final crumbs = <Widget>[];
    for (var i = -1; i < parts.length; i++) {
      final target = i < 0 ? '' : parts.sublist(0, i + 1).join('/');
      final label = i < 0 ? widget.rootLabel : parts[i];
      final current = i == parts.length - 1;
      if (i >= 0) {
        crumbs.add(Icon(Icons.chevron_right,
            size: 16, color: scheme.onSurfaceVariant));
      }
      crumbs.add(TextButton(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          foregroundColor: current ? scheme.onSurface : scheme.primary,
          disabledForegroundColor: scheme.onSurface,
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: current ? FontWeight.w600 : FontWeight.w500),
        ),
        onPressed: current ? null : () => _open(target),
        child: Text(label, overflow: TextOverflow.ellipsis),
      ));
    }
    // Reversed so a deep path shows its end; at least as wide as the bar
    // so a short one still starts on the left.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Row(children: crumbs),
        ),
      ),
    );
  }

  Widget _listing(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = _entries;
    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off_outlined,
                  size: 36, color: scheme.onSurfaceVariant),
              const SizedBox(height: 10),
              Text('$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  if (_entries != null)
                    OutlinedButton(
                      onPressed: () => _open(_path),
                      child: const Text('Back'),
                    )
                  else if ((_failedPath ?? _path).isNotEmpty)
                    OutlinedButton(
                      onPressed: () => _open(''),
                      child: Text('Go to ${widget.rootLabel}'),
                    ),
                  FilledButton.tonal(
                    onPressed: () => _load(_failedPath ?? _path),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    } else if (entries == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (entries.isEmpty) {
      body = Center(
        child: Text('This folder is empty.',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    } else {
      body = ListView.builder(
        itemCount: entries.length,
        itemExtent: 44,
        itemBuilder: (context, i) => _row(context, entries[i]),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(child: body),
          if (_loading && entries != null)
            const Positioned(
                left: 0, right: 0, top: 0, child: LinearProgressIndicator()),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, SourceEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = entry.isDirectory || !widget.pickFolder;
    final selected = !entry.isDirectory && entry.name == _selectedFile;
    final details = [
      if (!entry.isDirectory && entry.size != null) formatBytes(entry.size!),
      if (entry.modified != null) formatShortDate(entry.modified!),
    ].join('  ·  ');
    final color = enabled ? scheme.onSurface : scheme.onSurfaceVariant;

    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.6)
          : Colors.transparent,
      child: InkWell(
        onTap: !enabled
            ? null
            : entry.isDirectory
                ? () => _open(_child(entry.name))
                : () => setState(() => _selectedFile = entry.name),
        onDoubleTap: enabled && !entry.isDirectory
            ? () {
                setState(() => _selectedFile = entry.name);
                _confirm();
              }
            : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.55,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(
                  entry.isDirectory
                      ? Icons.folder
                      : Icons.insert_drive_file_outlined,
                  size: 20,
                  color: entry.isDirectory ? scheme.primary : color,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: color)),
                ),
                if (details.isNotEmpty)
                  Text(details,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                if (entry.isDirectory)
                  Icon(Icons.chevron_right,
                      size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

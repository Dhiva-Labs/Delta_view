/// The menu of things to do with the selected entries of a folder
/// comparison, shared by the right-click menu and the toolbar button.
library;

import 'package:flutter/material.dart';

import '../../compare/folder_compare.dart';
import '../../compare/folder_format.dart';
import '../shortcuts/app_shortcuts.dart';

/// What the menu's items do; the folder view supplies them.
class EntryMenuActions {
  const EntryMenuActions({
    required this.open,
    required this.copy,
    required this.delete,
    required this.copyPath,
    required this.showInFileManager,
    required this.openInEditor,
    required this.ignore,
  });

  final void Function(CompareNode node) open;

  /// Copies the selection from a side to the other.
  final void Function(Side from) copy;
  final void Function(Side side) delete;
  final void Function(Side side, CompareNode node) copyPath;
  final void Function(Side side, CompareNode node) showInFileManager;
  final void Function(Side side, CompareNode node) openInEditor;

  /// Leaves the selection out of this comparison.
  final VoidCallback ignore;
}

/// Menu items for [targets]. Items that cannot apply are disabled rather
/// than hidden, so the menu keeps its shape; actions that need a path on
/// this machine are offered only for local sides.
List<Widget> buildEntryMenu({
  required List<CompareNode> targets,
  required ScanResult result,
  required EntryMenuActions actions,
  required bool busy,
  required bool hasExternalEditor,
}) {
  final single = targets.length == 1 ? targets.single : null;
  bool canCopy(Side from) =>
      !busy &&
      result.writable(from.other) &&
      targets.any((n) => n.existsOn(from) && n.hasChanges);
  bool canDelete(Side side) =>
      !busy &&
      result.writable(side) &&
      targets.any((n) => n.existsOn(side) && n.relativePath.isNotEmpty);
  final many = targets.length > 1 ? ' (${formatCount(targets.length)})' : '';

  List<Widget> sideMenu(Side side) {
    final node = single != null && single.existsOn(side) ? single : null;
    return [
      MenuItemButton(
        leadingIcon: const Icon(Icons.content_copy, size: 18),
        onPressed: node == null ? null : () => actions.copyPath(side, node),
        child: const Text('Copy path'),
      ),
      if (result.isLocal(side)) ...[
        MenuItemButton(
          leadingIcon: const Icon(Icons.folder_open_outlined, size: 18),
          onPressed: node == null
              ? null
              : () => actions.showInFileManager(side, node),
          child: const Text('Show in file manager'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.edit_note, size: 18),
          onPressed:
              node == null ? null : () => actions.openInEditor(side, node),
          child: Text(hasExternalEditor
              ? 'Open in external editor'
              : 'Open with default app'),
        ),
      ],
    ];
  }

  return [
    MenuItemButton(
      leadingIcon: const Icon(Icons.open_in_new, size: 18),
      shortcut: AppAction.openEntry.activator,
      onPressed: single == null ? null : () => actions.open(single),
      child: Text(single?.isDirectory == true
          ? 'Open folder comparison'
          : 'Open comparison'),
    ),
    const Divider(height: 8),
    MenuItemButton(
      leadingIcon: const Icon(Icons.arrow_forward, size: 18),
      onPressed: canCopy(Side.left) ? () => actions.copy(Side.left) : null,
      child: Text('Copy to right$many'),
    ),
    MenuItemButton(
      leadingIcon: const Icon(Icons.arrow_back, size: 18),
      onPressed: canCopy(Side.right) ? () => actions.copy(Side.right) : null,
      child: Text('Copy to left$many'),
    ),
    MenuItemButton(
      leadingIcon: const Icon(Icons.delete_outline, size: 18),
      onPressed:
          canDelete(Side.left) ? () => actions.delete(Side.left) : null,
      child: Text('Delete on left$many…'),
    ),
    MenuItemButton(
      leadingIcon: const Icon(Icons.delete_outline, size: 18),
      onPressed:
          canDelete(Side.right) ? () => actions.delete(Side.right) : null,
      child: Text('Delete on right$many…'),
    ),
    const Divider(height: 8),
    SubmenuButton(
      leadingIcon: const Icon(Icons.west, size: 18),
      menuChildren: sideMenu(Side.left),
      child: const Text('Left side'),
    ),
    SubmenuButton(
      leadingIcon: const Icon(Icons.east, size: 18),
      menuChildren: sideMenu(Side.right),
      child: const Text('Right side'),
    ),
    const Divider(height: 8),
    MenuItemButton(
      leadingIcon: const Icon(Icons.visibility_off_outlined, size: 18),
      onPressed: targets.any((n) => n.relativePath.isNotEmpty)
          ? actions.ignore
          : null,
      child: Text(single != null
          ? 'Ignore “${single.name}” in this comparison'
          : 'Ignore$many in this comparison'),
    ),
  ];
}

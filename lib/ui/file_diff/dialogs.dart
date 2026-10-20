/// The questions the file diff view asks: save before closing, save in
/// UTF-8 when Latin-1 cannot hold the text, reload over unsaved edits, and
/// which line to go to.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum SaveChoice { save, discard, cancel }

/// "Save changes to X?" with Save / Don't save / Cancel. Null (dismissed)
/// means cancel.
Future<SaveChoice> askSaveChanges(
    BuildContext context, List<String> names) async {
  final what = names.join(' and ');
  final choice = await showDialog<SaveChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Save changes to $what?'),
      content: const Text("Your changes are lost if you don't save them."),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, SaveChoice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, SaveChoice.discard),
          child: const Text("Don't save"),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, SaveChoice.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return choice ?? SaveChoice.cancel;
}

/// Latin-1 cannot store [character]: offer UTF-8 instead. True to save as
/// UTF-8, false to cancel the save.
Future<bool> askSaveAsUtf8(
    BuildContext context, String name, String character) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('$name cannot be saved as Latin-1'),
      content: Text(
          'It contains "$character", which Latin-1 cannot store. Save it as '
          'UTF-8 instead? Nothing is saved otherwise.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save as UTF-8'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Confirms throwing away unsaved edits to reload from disk.
Future<bool> askDiscardAndReload(
    BuildContext context, List<String> names) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Reload from disk?'),
      content: Text('Unsaved changes to ${names.join(' and ')} will be '
          'replaced by the files on disk. Undo brings them back.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Reload'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Asks for a line number and a side. Returns (left, line) with a 1-based
/// line, or null.
Future<(bool, int)?> askGoToLine(
  BuildContext context, {
  required bool left,
  required int leftLines,
  required int rightLines,
}) {
  return showDialog<(bool, int)>(
    context: context,
    builder: (context) => _GoToLineDialog(
        left: left, leftLines: leftLines, rightLines: rightLines),
  );
}

class _GoToLineDialog extends StatefulWidget {
  const _GoToLineDialog({
    required this.left,
    required this.leftLines,
    required this.rightLines,
  });

  final bool left;
  final int leftLines;
  final int rightLines;

  @override
  State<_GoToLineDialog> createState() => _GoToLineDialogState();
}

class _GoToLineDialogState extends State<_GoToLineDialog> {
  late bool _left = widget.left;
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _max => _left ? widget.leftLines : widget.rightLines;

  int? get _line {
    final n = int.tryParse(_controller.text.trim());
    return n == null || n < 1 || n > _max ? null : n;
  }

  void _submit() {
    final line = _line;
    if (line != null) Navigator.pop(context, (_left, line));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Go to line'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, label: Text('Left')),
              ButtonSegment(value: false, label: Text('Right')),
            ],
            selected: {_left},
            onSelectionChanged: (s) => setState(() => _left = s.first),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Line (1–$_max)',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _line == null ? null : _submit,
          child: const Text('Go'),
        ),
      ],
    );
  }
}

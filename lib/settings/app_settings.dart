/// User preferences and remembered state (recent comparisons, window
/// bounds, open tabs), persisted as one JSON file in the app support
/// directory.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../diff/compare_options.dart';

/// The single settings instance. [AppSettings.load] fills it in `main`;
/// until then (and in tests) it holds the defaults and never touches disk.
final appSettings = AppSettings();

enum DiffColorPreset {
  /// Green / red / amber.
  classic,

  /// Blue / orange / purple, distinguishable with the common forms of
  /// colour blindness.
  colorBlindSafe,

  /// Stronger fills and emphasis for low-contrast screens.
  highContrast,
}

enum UiDensity { comfortable, compact }

/// How the folder scanner decides that two files with the same name are
/// the same.
enum FolderCompareMethod {
  /// Byte-for-byte (or by the text compare rules when those are not exact).
  content,

  /// Same size and same modification time. Much faster on huge trees.
  sizeAndDate,
}

enum FolderFilterDefault { all, changes, leftOnly, rightOnly }

enum DateStyle {
  /// "21 Oct 2026 14:05"
  short,

  /// "2026-10-21 14:05"
  iso,

  /// "3 hours ago", falling back to [short] after a week.
  relative,
}

/// A comparison the user ran, for the home screen's recent list.
class RecentComparison {
  RecentComparison({
    required this.comparison,
    required this.lastOpened,
    this.pinned = false,
  });

  /// [Comparison.toJson] of what was compared.
  final Map<String, Object?> comparison;
  DateTime lastOpened;
  bool pinned;

  Map<String, Object?> toJson() => {
        'comparison': comparison,
        'lastOpened': lastOpened.toIso8601String(),
        'pinned': pinned,
      };

  static RecentComparison? fromJson(Object? json) {
    if (json is! Map) return null;
    final comparison = json['comparison'];
    if (comparison is! Map) return null;
    return RecentComparison(
      comparison: comparison.cast<String, Object?>(),
      lastOpened:
          DateTime.tryParse('${json['lastOpened']}') ?? DateTime.now(),
      pinned: json['pinned'] == true,
    );
  }
}

class WindowBounds {
  const WindowBounds(this.x, this.y, this.width, this.height,
      {this.maximized = false});

  final double x, y, width, height;
  final bool maximized;

  Map<String, Object?> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'maximized': maximized,
      };

  static WindowBounds? fromJson(Object? json) {
    if (json is! Map) return null;
    double? n(Object? v) => v is num ? v.toDouble() : null;
    final x = n(json['x']), y = n(json['y']);
    final w = n(json['width']), h = n(json['height']);
    if (x == null || y == null || w == null || h == null) return null;
    return WindowBounds(x, y, w, h, maximized: json['maximized'] == true);
  }
}

class AppSettings extends ChangeNotifier {
  // ---- appearance ----
  ThemeMode themeMode = ThemeMode.system;
  Color accentColor = const Color(0xFF6366F1);
  DiffColorPreset diffColors = DiffColorPreset.classic;
  UiDensity density = UiDensity.comfortable;

  // ---- editor / diff view ----
  String editorFontFamily = 'monospace';
  double editorFontSize = 13;
  double editorLineHeight = 1.45;
  int tabWidth = 4;
  bool showWhitespace = false;
  bool wordWrap = false;
  bool syntaxHighlighting = true;

  /// Collapse long runs of unchanged lines, keeping [foldContext] lines of
  /// context around each change.
  bool foldUnchanged = false;
  int foldContext = 3;

  // ---- comparison rules ----
  CompareOptions compareOptions = const CompareOptions();

  // ---- folder compare ----
  List<String> ignorePatterns = [
    '.git',
    '.hg',
    '.svn',
    'node_modules',
    '.dart_tool',
    '__pycache__',
    '*.pyc',
    '.DS_Store',
    'Thumbs.db',
  ];
  bool respectGitignore = true;
  FolderCompareMethod folderCompareMethod = FolderCompareMethod.content;
  FolderFilterDefault defaultFolderFilter = FolderFilterDefault.changes;
  DateStyle dateStyle = DateStyle.short;

  // ---- behaviour ----
  /// Reopen the tabs that were open when the app was last closed.
  bool restoreSession = true;

  /// Command used for "Open in external editor". `{file}` is replaced with
  /// the path; empty means the system default application.
  String externalEditor = '';

  /// [AppAction.name] → serialized key combination (see app_shortcuts.dart).
  Map<String, String> shortcutOverrides = {};

  // ---- remembered state ----
  List<RecentComparison> recents = [];
  WindowBounds? windowBounds;

  /// [Comparison.toJson] of each open tab, in order, for session restore.
  List<Map<String, Object?>> sessionTabs = [];
  int sessionActiveTab = 0;

  static const maxRecents = 30;

  File? _file;
  Timer? _saveTimer;

  /// Call after changing any field: rebuilds listeners and schedules a save.
  void changed() {
    notifyListeners();
    _scheduleSave();
  }

  /// Records [comparisonJson] at the top of the recent list.
  void addRecent(Map<String, Object?> comparisonJson) {
    final key = jsonEncode(comparisonJson);
    final existing =
        recents.where((r) => jsonEncode(r.comparison) == key).firstOrNull;
    if (existing != null) {
      existing.lastOpened = DateTime.now();
      recents.remove(existing);
      recents.insert(0, existing);
    } else {
      recents.insert(
          0,
          RecentComparison(
              comparison: comparisonJson, lastOpened: DateTime.now()));
    }
    // Drop the oldest unpinned entries past the cap.
    while (recents.length > maxRecents) {
      final victim = recents.lastWhere((r) => !r.pinned,
          orElse: () => recents.last);
      recents.remove(victim);
    }
    changed();
  }

  // ---- persistence ----

  /// Reads settings from disk. Missing or unreadable files leave the
  /// defaults in place.
  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File(p.join(dir.path, 'settings.json'));
      if (!await _file!.exists()) return;
      final json = jsonDecode(await _file!.readAsString());
      if (json is Map) applyJson(json.cast<String, Object?>());
    } catch (e) {
      debugPrint('Settings not loaded: $e');
    }
  }

  /// Writes settings now (also called on app exit).
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
          const JsonEncoder.withIndent('  ').convert(toJson()));
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('Settings not saved: $e');
    }
  }

  void _scheduleSave() {
    if (_file == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), flush);
  }

  Map<String, Object?> toJson() => {
        'themeMode': themeMode.name,
        'accentColor': accentColor.toARGB32(),
        'diffColors': diffColors.name,
        'density': density.name,
        'editorFontFamily': editorFontFamily,
        'editorFontSize': editorFontSize,
        'editorLineHeight': editorLineHeight,
        'tabWidth': tabWidth,
        'showWhitespace': showWhitespace,
        'wordWrap': wordWrap,
        'syntaxHighlighting': syntaxHighlighting,
        'foldUnchanged': foldUnchanged,
        'foldContext': foldContext,
        'compareOptions': compareOptions.toJson(),
        'ignorePatterns': ignorePatterns,
        'respectGitignore': respectGitignore,
        'folderCompareMethod': folderCompareMethod.name,
        'defaultFolderFilter': defaultFolderFilter.name,
        'dateStyle': dateStyle.name,
        'restoreSession': restoreSession,
        'externalEditor': externalEditor,
        'shortcutOverrides': shortcutOverrides,
        'recents': [for (final r in recents) r.toJson()],
        'windowBounds': windowBounds?.toJson(),
        'sessionTabs': sessionTabs,
        'sessionActiveTab': sessionActiveTab,
      };

  void applyJson(Map<String, Object?> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.asNameMap()[name] ?? fallback;
    double num_(Object? v, double fallback) =>
        v is num ? v.toDouble() : fallback;

    themeMode = pick(ThemeMode.values, j['themeMode'], themeMode);
    if (j['accentColor'] is int) accentColor = Color(j['accentColor'] as int);
    diffColors = pick(DiffColorPreset.values, j['diffColors'], diffColors);
    density = pick(UiDensity.values, j['density'], density);
    if (j['editorFontFamily'] is String) {
      editorFontFamily = j['editorFontFamily'] as String;
    }
    editorFontSize = num_(j['editorFontSize'], editorFontSize).clamp(8, 32);
    editorLineHeight =
        num_(j['editorLineHeight'], editorLineHeight).clamp(1.0, 2.5);
    if (j['tabWidth'] is int) tabWidth = (j['tabWidth'] as int).clamp(1, 16);
    if (j['showWhitespace'] is bool) showWhitespace = j['showWhitespace'] as bool;
    if (j['wordWrap'] is bool) wordWrap = j['wordWrap'] as bool;
    if (j['syntaxHighlighting'] is bool) {
      syntaxHighlighting = j['syntaxHighlighting'] as bool;
    }
    if (j['foldUnchanged'] is bool) foldUnchanged = j['foldUnchanged'] as bool;
    if (j['foldContext'] is int) {
      foldContext = (j['foldContext'] as int).clamp(0, 50);
    }
    if (j['compareOptions'] is Map) {
      compareOptions = CompareOptions.fromJson(
          (j['compareOptions'] as Map).cast<String, Object?>());
    }
    if (j['ignorePatterns'] is List) {
      ignorePatterns = [for (final s in j['ignorePatterns'] as List) '$s'];
    }
    if (j['respectGitignore'] is bool) {
      respectGitignore = j['respectGitignore'] as bool;
    }
    folderCompareMethod = pick(
        FolderCompareMethod.values, j['folderCompareMethod'], folderCompareMethod);
    defaultFolderFilter = pick(
        FolderFilterDefault.values, j['defaultFolderFilter'], defaultFolderFilter);
    dateStyle = pick(DateStyle.values, j['dateStyle'], dateStyle);
    if (j['restoreSession'] is bool) restoreSession = j['restoreSession'] as bool;
    if (j['externalEditor'] is String) {
      externalEditor = j['externalEditor'] as String;
    }
    if (j['shortcutOverrides'] is Map) {
      shortcutOverrides = {
        for (final e in (j['shortcutOverrides'] as Map).entries)
          '${e.key}': '${e.value}',
      };
    }
    if (j['recents'] is List) {
      recents = [
        for (final r in j['recents'] as List) ?RecentComparison.fromJson(r),
      ];
    }
    windowBounds = WindowBounds.fromJson(j['windowBounds']) ?? windowBounds;
    if (j['sessionTabs'] is List) {
      sessionTabs = [
        for (final t in j['sessionTabs'] as List)
          if (t is Map) t.cast<String, Object?>(),
      ];
    }
    if (j['sessionActiveTab'] is int) {
      sessionActiveTab = j['sessionActiveTab'] as int;
    }
  }
}

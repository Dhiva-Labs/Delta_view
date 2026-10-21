import 'package:flutter/material.dart';

import 'compare/folder_compare.dart';
import 'diff/line_diff.dart';
import 'settings/app_settings.dart';

const seedColor = Color(0xFF6366F1); // indigo

ThemeData buildTheme(
  Brightness brightness, {
  Color seed = seedColor,
  UiDensity density = UiDensity.comfortable,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  );
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: visualDensityFor(density),
    scaffoldBackgroundColor:
        isDark ? const Color(0xFF0F1117) : const Color(0xFFF6F7FB),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: isDark ? const Color(0xFF181B24) : Colors.white,
    ),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor:
          isDark ? const Color(0xFF0F1117) : const Color(0xFFF6F7FB),
      centerTitle: false,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2E3B) : const Color(0xFF3A3F4E),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: isDark ? Colors.white10 : Colors.black12,
      space: 1,
      thickness: 1,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}

/// Desktop defaults to Flutter's compact density; "comfortable" sits one
/// step roomier so the two settings look different without the app
/// becoming touch-sized.
VisualDensity visualDensityFor(UiDensity density) => switch (density) {
      UiDensity.comfortable => VisualDensity.comfortable,
      UiDensity.compact => VisualDensity.compact,
    };

/// Sits above the shell (see main.dart) and rebuilds whatever depends on
/// it when a setting that changes how views draw is edited. Views that
/// read [appSettings] in `build` go through [DiffPalette.of] or
/// [editorTextStyle] with a context, or call [SettingsScope.dependOn]
/// themselves; the theme alone does not change when, say, the diff colour
/// preset does.
class SettingsScope extends InheritedWidget {
  SettingsScope({super.key, required super.child})
      : revision = _revisionOf(appSettings);

  /// A hash of the view-affecting settings.
  final int revision;

  static int _revisionOf(AppSettings s) => Object.hashAll([
        s.diffColors,
        s.editorFontFamily,
        s.editorFontSize,
        s.editorLineHeight,
        s.tabWidth,
        s.showWhitespace,
        s.wordWrap,
        s.syntaxHighlighting,
        s.foldUnchanged,
        s.foldContext,
        s.compareOptions,
        s.respectGitignore,
        s.folderCompareMethod,
        s.defaultFolderFilter,
        s.dateStyle,
        s.externalEditor,
        Object.hashAll(s.ignorePatterns),
      ]);

  /// Registers [context] for a rebuild when a view-affecting setting
  /// changes. Harmless where no scope exists (tests).
  static void dependOn(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<SettingsScope>();
  }

  @override
  bool updateShouldNotify(SettingsScope oldWidget) =>
      oldWidget.revision != revision;
}

/// Semantic colours for diff statuses, tuned per brightness and chosen by
/// [AppSettings.diffColors].
class DiffPalette {
  const DiffPalette._({
    required this.added,
    required this.removed,
    required this.modified,
    required this.addedBg,
    required this.removedBg,
    required this.modifiedBg,
    required this.addedEmphasis,
    required this.removedEmphasis,
  });

  final Color added;
  final Color removed;
  final Color modified;
  final Color addedBg;
  final Color removedBg;
  final Color modifiedBg;
  final Color addedEmphasis;
  final Color removedEmphasis;

  static DiffPalette of(BuildContext context) {
    SettingsScope.dependOn(context);
    return preset(appSettings.diffColors, Theme.of(context).brightness);
  }

  /// The palette for [preset] at [brightness], independent of the current
  /// setting (the settings page previews every preset side by side).
  static DiffPalette preset(DiffColorPreset preset, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return switch (preset) {
      DiffColorPreset.classic => isDark ? _classicDark : _classicLight,
      DiffColorPreset.colorBlindSafe =>
        isDark ? _colorBlindDark : _colorBlindLight,
      DiffColorPreset.highContrast =>
        isDark ? _highContrastDark : _highContrastLight,
    };
  }

  // Green / red / amber: the look DeltaView shipped with.
  static const _classicDark = DiffPalette._(
    added: Color(0xFF4ADE80),
    removed: Color(0xFFF87171),
    modified: Color(0xFFFBBF24),
    addedBg: Color(0x1F4ADE80),
    removedBg: Color(0x1FF87171),
    modifiedBg: Color(0x1AFBBF24),
    addedEmphasis: Color(0x4D4ADE80),
    removedEmphasis: Color(0x4DF87171),
  );

  static const _classicLight = DiffPalette._(
    added: Color(0xFF15803D),
    removed: Color(0xFFB91C1C),
    modified: Color(0xFFB45309),
    addedBg: Color(0x2222C55E),
    removedBg: Color(0x22EF4444),
    modifiedBg: Color(0x1FF59E0B),
    addedEmphasis: Color(0x5522C55E),
    removedEmphasis: Color(0x55EF4444),
  );

  // Okabe–Ito blue / vermillion / reddish purple. Blue and orange stay
  // apart under deuteranopia and protanopia (which fold red and green
  // together), and the purple differs from both in lightness as well as
  // hue so "modified" never collapses into "removed".
  static const _colorBlindLight = DiffPalette._(
    added: Color(0xFF0072B2),
    removed: Color(0xFFD55E00),
    modified: Color(0xFF9C4A8B),
    addedBg: Color(0x240072B2),
    removedBg: Color(0x26D55E00),
    modifiedBg: Color(0x1FCC79A7),
    addedEmphasis: Color(0x5A0072B2),
    removedEmphasis: Color(0x5AD55E00),
  );

  static const _colorBlindDark = DiffPalette._(
    added: Color(0xFF56B4E9),
    removed: Color(0xFFE69F00),
    modified: Color(0xFFD9A3C9),
    addedBg: Color(0x2456B4E9),
    removedBg: Color(0x24E69F00),
    modifiedBg: Color(0x1FCC79A7),
    addedEmphasis: Color(0x5C56B4E9),
    removedEmphasis: Color(0x5CE69F00),
  );

  // Deeper inks and much stronger fills for low-contrast screens and
  // bright rooms.
  static const _highContrastLight = DiffPalette._(
    added: Color(0xFF0B5E1E),
    removed: Color(0xFF9F0012),
    modified: Color(0xFF6B4000),
    addedBg: Color(0x4A22C55E),
    removedBg: Color(0x4AF43F5E),
    modifiedBg: Color(0x45F59E0B),
    addedEmphasis: Color(0x9022C55E),
    removedEmphasis: Color(0x90F43F5E),
  );

  static const _highContrastDark = DiffPalette._(
    added: Color(0xFF86EFAC),
    removed: Color(0xFFFF8A8A),
    modified: Color(0xFFFFD54F),
    addedBg: Color(0x3D4ADE80),
    removedBg: Color(0x3DF87171),
    modifiedBg: Color(0x36FBBF24),
    addedEmphasis: Color(0x804ADE80),
    removedEmphasis: Color(0x80F87171),
  );

  Color statusColor(EntryStatus status) => switch (status) {
        EntryStatus.identical => Colors.grey,
        EntryStatus.modified => modified,
        EntryStatus.onlyLeft => removed,
        EntryStatus.onlyRight => added,
      };

  Color rowBackground(DiffRowKind kind) => switch (kind) {
        DiffRowKind.same => Colors.transparent,
        DiffRowKind.added => addedBg,
        DiffRowKind.removed => removedBg,
        DiffRowKind.modified => modifiedBg,
      };
}

const monoStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['JetBrains Mono', 'Fira Code', 'Consolas', 'Menlo'],
  fontSize: 13,
  height: 1.45,
);

/// [monoStyle] with the user's editor font, size and line height applied.
/// Views that show file text should prefer this over the bare constant,
/// passing their [context] so they rebuild when the setting changes.
TextStyle editorTextStyle([BuildContext? context]) {
  if (context != null) SettingsScope.dependOn(context);
  return monoStyle.copyWith(
    fontFamily: appSettings.editorFontFamily,
    fontSize: appSettings.editorFontSize,
    height: appSettings.editorLineHeight,
  );
}

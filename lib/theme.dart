import 'package:flutter/material.dart';

import 'compare/folder_compare.dart';
import 'diff/line_diff.dart';

const seedColor = Color(0xFF6366F1); // indigo

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
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
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}

/// Semantic colours for diff statuses, tuned per brightness.
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? _dark : _light;
  }

  static const _dark = DiffPalette._(
    added: Color(0xFF4ADE80),
    removed: Color(0xFFF87171),
    modified: Color(0xFFFBBF24),
    addedBg: Color(0x1F4ADE80),
    removedBg: Color(0x1FF87171),
    modifiedBg: Color(0x1AFBBF24),
    addedEmphasis: Color(0x4D4ADE80),
    removedEmphasis: Color(0x4DF87171),
  );

  static const _light = DiffPalette._(
    added: Color(0xFF15803D),
    removed: Color(0xFFB91C1C),
    modified: Color(0xFFB45309),
    addedBg: Color(0x2222C55E),
    removedBg: Color(0x22EF4444),
    modifiedBg: Color(0x1FF59E0B),
    addedEmphasis: Color(0x5522C55E),
    removedEmphasis: Color(0x55EF4444),
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

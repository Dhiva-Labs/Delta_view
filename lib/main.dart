import 'package:flutter/material.dart';

import 'theme.dart';
import 'ui/shell.dart';

void main() {
  runApp(const DeltaViewApp());
}

/// App-wide theme mode, toggled from the tab bar.
final themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.dark);

class DeltaViewApp extends StatelessWidget {
  const DeltaViewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'DeltaView',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: mode,
          home: const TabbedShell(),
        );
      },
    );
  }
}

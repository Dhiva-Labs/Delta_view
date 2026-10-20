/// The native window: remembers its size, position and maximized state,
/// and turns the close button into "ask the tabs first, save, then quit".
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../settings/app_settings.dart';
import '../brand/app_info.dart';

class AppWindow with WindowListener {
  AppWindow({required this.confirmClose, required this.beforeClose});

  /// Runs the tabs' close guards; false keeps the window open.
  final Future<bool> Function() confirmClose;

  /// Saves whatever must survive (the session) before the window goes.
  final Future<void> Function() beforeClose;

  static const minimumSize = Size(560, 400);
  static const defaultSize = Size(1280, 720);

  Timer? _boundsTimer;
  bool _closing = false;

  /// On Wayland a client cannot place its own window, so only the size is
  /// restored and the position is left as it was saved.
  static bool get isWayland =>
      Platform.isLinux &&
      (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty &&
      Platform.environment['GDK_BACKEND'] != 'x11';

  Future<void> attach() async {
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(minimumSize);
    await windowManager.setTitle(appName);
    await _restoreBounds();
  }

  Future<void> _restoreBounds() async {
    final saved = appSettings.windowBounds;
    if (saved == null) return;
    final size = Size(
      saved.width.clamp(minimumSize.width, 16384),
      saved.height.clamp(minimumSize.height, 16384),
    );
    final rect = Rect.fromLTWH(saved.x, saved.y, size.width, size.height);
    if (isWayland) {
      await windowManager.setSize(size);
    } else if (fitsVirtualDesktop(rect, _displayRects())) {
      await windowManager.setBounds(rect);
    } else {
      await windowManager.setSize(size);
      await windowManager.center();
    }
    if (saved.maximized) await windowManager.maximize();
  }

  /// The displays in logical pixels. Flutter reports no positions, so
  /// each is at the origin; [fitsVirtualDesktop] allows for that.
  List<Rect> _displayRects() => [
        for (final d in WidgetsBinding.instance.platformDispatcher.displays)
          Rect.fromLTWH(0, 0, d.size.width / d.devicePixelRatio,
              d.size.height / d.devicePixelRatio),
      ];

  /// Whether enough of [window] would be reachable on [displays] to grab
  /// it. Display positions are unknown, so the screens are assumed to sit
  /// side by side or stacked; a window that fits neither arrangement is
  /// centred instead.
  static bool fitsVirtualDesktop(Rect window, List<Rect> displays) {
    if (displays.isEmpty) return true;
    const grab = 80.0;
    final widths = displays.fold(0.0, (sum, d) => sum + d.width);
    final heights = displays.fold(0.0, (sum, d) => sum + d.height);
    final maxWidth = displays.fold(0.0, (m, d) => d.width > m ? d.width : m);
    final maxHeight =
        displays.fold(0.0, (m, d) => d.height > m ? d.height : m);
    final arrangements = [
      Rect.fromLTWH(0, 0, widths, maxHeight),
      Rect.fromLTWH(0, 0, maxWidth, heights),
    ];
    return arrangements.any((desktop) =>
        window.left + grab <= desktop.right &&
        window.right - grab >= desktop.left &&
        window.top >= desktop.top - 8 &&
        window.top + grab <= desktop.bottom);
  }

  // ---- remembering bounds ----

  // Linux only reports the continuous `resize` / `move` events (never the
  // `-ed` ones Windows and macOS add when a drag ends), so both kinds feed
  // one debounce.
  @override
  void onWindowResize() => _scheduleCapture();

  @override
  void onWindowResized() => _scheduleCapture();

  @override
  void onWindowMove() => _scheduleCapture();

  @override
  void onWindowMoved() => _scheduleCapture();

  @override
  void onWindowMaximize() => _scheduleCapture();

  @override
  void onWindowUnmaximize() => _scheduleCapture();

  void _scheduleCapture() {
    _boundsTimer?.cancel();
    _boundsTimer = Timer(const Duration(milliseconds: 500), () async {
      await captureBounds();
      // Through changed() rather than flush(): the settings model owns one
      // debounced writer, and two flushes in flight race for the same
      // temporary file.
      appSettings.changed();
    });
  }

  /// Reads the window's bounds into [AppSettings.windowBounds]. When
  /// maximized, the previous normal bounds are kept so un-maximizing after
  /// a restart lands where it used to.
  Future<void> captureBounds() async {
    try {
      if (await windowManager.isMinimized()) return;
      final previous = appSettings.windowBounds;
      if (await windowManager.isMaximized()) {
        appSettings.windowBounds = WindowBounds(
          previous?.x ?? 0,
          previous?.y ?? 0,
          previous?.width ?? defaultSize.width,
          previous?.height ?? defaultSize.height,
          maximized: true,
        );
        return;
      }
      final bounds = await windowManager.getBounds();
      appSettings.windowBounds = WindowBounds(
        isWayland ? previous?.x ?? 0 : bounds.left,
        isWayland ? previous?.y ?? 0 : bounds.top,
        bounds.width,
        bounds.height,
      );
    } catch (e) {
      debugPrint('Window bounds not read: $e');
    }
  }

  // ---- closing ----

  /// The close button, Ctrl+Q, and the window manager's close request.
  Future<void> requestClose() => onWindowClose();

  @override
  Future<void> onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      if (!await confirmClose()) return;
      _boundsTimer?.cancel();
      await beforeClose();
      await captureBounds();
      await appSettings.flush();
    } catch (e) {
      debugPrint('Error while closing: $e');
    } finally {
      _closing = false;
    }
    await windowManager.destroy();
    // destroy() ends the process on every desktop; this is the fallback
    // should a platform ever return from it.
    exit(0);
  }
}


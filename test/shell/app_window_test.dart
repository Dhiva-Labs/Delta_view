import 'package:delta_view/ui/window/app_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppWindow.fitsVirtualDesktop', () {
    const screen = Rect.fromLTWH(0, 0, 1920, 1080);

    test('accepts a window on the screen and one on a second monitor', () {
      expect(
          AppWindow.fitsVirtualDesktop(
              const Rect.fromLTWH(100, 100, 1200, 700), [screen]),
          isTrue);
      expect(
          AppWindow.fitsVirtualDesktop(
              const Rect.fromLTWH(2000, 100, 1200, 700), [screen, screen]),
          isTrue);
      expect(
          AppWindow.fitsVirtualDesktop(
              const Rect.fromLTWH(100, 1200, 1200, 700), [screen, screen]),
          isTrue,
          reason: 'stacked monitors');
    });

    test('rejects a window that would be out of reach', () {
      expect(
          AppWindow.fitsVirtualDesktop(
              const Rect.fromLTWH(2000, 100, 1200, 700), [screen]),
          isFalse);
      expect(
          AppWindow.fitsVirtualDesktop(
              const Rect.fromLTWH(-1180, 100, 1200, 700), [screen]),
          isFalse);
      expect(
          AppWindow.fitsVirtualDesktop(
              const Rect.fromLTWH(100, 1100, 1200, 700), [screen]),
          isFalse);
      expect(
          AppWindow.fitsVirtualDesktop(
              const Rect.fromLTWH(100, -200, 1200, 700), [screen]),
          isFalse,
          reason: 'title bar above the top edge');
    });

    test('trusts the bounds when no display is known', () {
      expect(
          AppWindow.fitsVirtualDesktop(
              const Rect.fromLTWH(9000, 9000, 100, 100), []),
          isTrue);
    });
  });
}

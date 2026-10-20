import 'dart:io';

/// Opens [url] in the user's browser through the platform's opener
/// (xdg-open, start, open). No plugin needed for one link. Returns false
/// when nothing could be launched, so the caller can offer "copy" instead.
Future<bool> openUrl(String url) async {
  try {
    if (Platform.isLinux) {
      await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url], mode: ProcessStartMode.detached);
    } else if (Platform.isWindows) {
      // `start` is a cmd built-in; the empty string is the window title it
      // would otherwise take the URL for.
      await Process.start('cmd', ['/c', 'start', '', url],
          mode: ProcessStartMode.detached);
    } else {
      return false;
    }
    return true;
  } on ProcessException {
    return false;
  }
}

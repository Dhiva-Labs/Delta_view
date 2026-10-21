import 'dart:io';

/// Opens [url] in the user's browser through the platform's opener
/// (xdg-open, explorer, open). No plugin needed for one link. Returns false
/// when nothing could be launched, so the caller can offer "copy" instead.
Future<bool> openUrl(String url) async {
  try {
    if (Platform.isLinux) {
      await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url], mode: ProcessStartMode.detached);
    } else if (Platform.isWindows) {
      // Explorer hands a URL to the default browser. Not `cmd /c start`:
      // the Microsoft Store asks apps not to launch the command prompt.
      await Process.start('explorer', [url], mode: ProcessStartMode.detached);
    } else {
      return false;
    }
    return true;
  } on ProcessException {
    return false;
  }
}

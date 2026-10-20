/// Text for sizes, dates and durations, shared by the folder view and the
/// exported reports so both say the same thing.
library;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Decimal units, as file managers show them: `999 B`, `1.2 kB`, `3.4 MB`.
String formatSize(int? size) {
  if (size == null) return '';
  if (size < 1000) return '$size B';
  if (size < 1000 * 1000) return '${(size / 1000).toStringAsFixed(1)} kB';
  if (size < 1000 * 1000 * 1000) {
    return '${(size / 1e6).toStringAsFixed(1)} MB';
  }
  return '${(size / 1e9).toStringAsFixed(1)} GB';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// `21 Oct 2026 14:05`, in local time.
String formatDateShort(DateTime time) {
  final t = time.toLocal();
  return '${t.day} ${_months[t.month - 1]} ${t.year} '
      '${_two(t.hour)}:${_two(t.minute)}';
}

/// `2026-10-21 14:05`, in local time.
String formatDateIso(DateTime time) {
  final t = time.toLocal();
  return '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}';
}

/// `just now`, `5 min ago`, `3 h ago`, `yesterday`, `4 days ago`; older
/// than a week falls back to [formatDateShort]. Future times (clock skew
/// between machines) read as `just now` rather than a negative age.
String formatDateRelative(DateTime time, {DateTime? now}) {
  final age = (now ?? DateTime.now()).difference(time);
  if (age.inSeconds < 60) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  if (age.inHours < 24) return '${age.inHours} h ago';
  if (age.inDays < 2) return 'yesterday';
  if (age.inDays < 7) return '${age.inDays} days ago';
  return formatDateShort(time);
}

/// `0:07`, `2:41`, `1:02:09`.
String formatElapsed(Duration elapsed) {
  final h = elapsed.inHours;
  final m = elapsed.inMinutes % 60;
  final s = elapsed.inSeconds % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '$m:${_two(s)}';
}

/// `1,234,567`.
String formatCount(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// Natural order for names: case-insensitive, and runs of digits compare
/// by value, so `file2` sorts before `file10`.
int compareNatural(String a, String b) {
  final x = a.toLowerCase(), y = b.toLowerCase();
  var i = 0, j = 0;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i), cy = y.codeUnitAt(j);
    if (_isDigit(cx) && _isDigit(cy)) {
      final si = i, sj = j;
      while (i < x.length && _isDigit(x.codeUnitAt(i))) {
        i++;
      }
      while (j < y.length && _isDigit(y.codeUnitAt(j))) {
        j++;
      }
      // Compare without leading zeros: longer means bigger.
      final dx = x.substring(si, i).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final dy = y.substring(sj, j).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (dx.length != dy.length) return dx.length - dy.length;
      final c = dx.compareTo(dy);
      if (c != 0) return c;
      continue;
    }
    if (cx != cy) return cx - cy;
    i++;
    j++;
  }
  final rest = (x.length - i) - (y.length - j);
  if (rest != 0) return rest;
  // Equal ignoring case: fall back to a stable, case-sensitive order.
  return a.compareTo(b);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

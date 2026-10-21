/// "just now", "5 min ago", "yesterday" for the recent list. Beyond a week
/// it falls back to a short date, which reads better than "23 days ago".
String relativeTime(DateTime when, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final diff = reference.difference(when);
  if (diff.isNegative || diff.inSeconds < 45) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) {
    return diff.inHours == 1 ? '1 hour ago' : '${diff.inHours} hours ago';
  }
  final today = DateTime(reference.year, reference.month, reference.day);
  final day = DateTime(when.year, when.month, when.day);
  final days = today.difference(day).inDays;
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final date = '${when.day} ${months[when.month - 1]}';
  return when.year == reference.year ? date : '$date ${when.year}';
}

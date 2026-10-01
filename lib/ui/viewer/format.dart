String _two(int v) => v.toString().padLeft(2, '0');

String fmtClock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String fmtDate(DateTime t) => '${_two(t.day)}.${_two(t.month)}.${t.year}';

String fmtDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes % 60} min';
  if (d.inMinutes > 0) return '${d.inMinutes} min ${d.inSeconds % 60} s';
  return '${d.inSeconds} s';
}

String fmtNum(num? v, {int digits = 0, String unit = ''}) {
  if (v == null || (v is double && v.isNaN)) return '–';
  final s = v.toStringAsFixed(digits).replaceAll('.', ',');
  return unit.isEmpty ? s : '$s $unit';
}

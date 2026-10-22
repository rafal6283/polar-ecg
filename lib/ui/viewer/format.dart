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

/// Odmiana liczebnika: plural(1, 'pobudzenie', 'pobudzenia', 'pobudzeń') -> '1 pobudzenie', 22 -> '22 pobudzenia'.
String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  final w = n == 1 ? one : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? few : many);
  return '$n $w';
}

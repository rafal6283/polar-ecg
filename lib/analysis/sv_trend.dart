import 'dart:math';

/// Pobudzenia S na godzinę względem własnej normy: mediana z zapisów (≥ 1 h) z poprzednich 30 dni (co najmniej 5).
/// Częste pobudzenia S i ich serie często poprzedzają napady AF – wyraźny wzrost to sygnał do obserwacji.
class SvTrend {
  final double? norm, last;
  final DateTime? lastAt;
  final int samples;
  const SvTrend(this.norm, this.last, this.lastAt, this.samples);

  /// Wyraźnie więcej niż zwykle: ≥ 2× normy i co najmniej o 5/h.
  bool get elevated => norm != null && last != null && last! >= max(2 * norm!, norm! + 5);
}

/// [recs] – (początek, S/h, godzin analizy) dla każdego zapisu.
SvTrend svTrend(List<(DateTime, double, double)> recs) {
  final ok = [for (final r in recs) if (r.$3 >= 1) r]..sort((a, b) => a.$1.compareTo(b.$1));
  if (ok.isEmpty) return const SvTrend(null, null, null, 0);
  final last = ok.last;
  final from = last.$1.subtract(const Duration(days: 30));
  final prev = [for (final r in ok) if (r.$1.isBefore(last.$1) && r.$1.isAfter(from)) r.$2]..sort();
  if (prev.length < 5) return SvTrend(null, last.$2, last.$1, prev.length);
  return SvTrend(prev[prev.length ~/ 2], last.$2, last.$1, prev.length);
}

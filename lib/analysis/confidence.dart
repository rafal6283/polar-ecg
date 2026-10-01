import 'analysis_result.dart';

enum ConfidenceLevel {
  high('wysoka'),
  medium('średnia'),
  low('niska');

  final String label;
  const ConfidenceLevel(this.label);
}

/// Wiarygodność wyniku analizy: ile zapisu dało się odczytać, ile klasyfikacji pobudzeń jest
/// niepewnych (prawdopodobieństwo modelu < 0.8) i które zdarzenia leżą w zakłóconych fragmentach.
class AnalysisConfidence {
  final ConfidenceLevel level;
  final double readablePct; // czas bez zakłóceń / czas zapisu
  final double beatsReadablePct; // pobudzenia inne niż Q
  final int uncertainV, uncertainS; // V/S z niepewną klasyfikacją (bez poprawek ręcznych)
  final Set<int> uncertainEvents; // indeksy w AnalysisResult.events
  final List<String> reasons;

  const AnalysisConfidence(this.level, this.readablePct, this.beatsReadablePct, this.uncertainV, this.uncertainS,
      this.uncertainEvents, this.reasons);

  /// Pobudzenie [i] ma niepewną klasyfikację (model < 0.8 dla przypisanej klasy, bez poprawki ręcznej).
  static bool uncertainBeat(AnalysisResult a, int i) {
    final l = a.labels[i];
    if (l == BeatType.unknown || a.corrected.containsKey(a.rPeaks[i])) return false;
    final p = a.prob(i, l);
    return p != null && p < 0.8;
  }

  factory AnalysisConfidence.of(AnalysisResult a) {
    final s = a.stats.values;
    final dur = (s['duration_s'] ?? 0).toDouble();
    final readable = dur > 0 ? 100 * (s['analyzed_s'] ?? 0).toDouble() / dur : 0.0;
    final n = a.rPeaks.length;
    var q = 0, uv = 0, us = 0;
    for (var i = 0; i < n; i++) {
      final l = a.labels[i];
      if (l == BeatType.unknown) q++;
      if (a.inAf[i] == 1) continue;
      if (l == BeatType.ventricular && uncertainBeat(a, i)) uv++;
      if (l == BeatType.supraventricular && uncertainBeat(a, i)) us++;
    }
    final beatsReadable = n > 0 ? 100 * (n - q) / n : 0.0;

    // Zdarzenie niepewne: ≥ 20% nieczytelnych pobudzeń w nim i ±10 s wokół lub nakładanie na zakłócenia.
    final fs = a.sampleRate;
    final uncertainEv = <int>{};
    for (var k = 0; k < a.events.length; k++) {
      final e = a.events[k];
      final from = e.startSample - 10 * fs, to = e.endSample + 10 * fs;
      var tot = 0, bad = 0;
      for (var i = a.beatIndexAtOrAfter(from); i < n && a.rPeaks[i] <= to; i++) {
        tot++;
        if (a.labels[i] == BeatType.unknown) bad++;
      }
      final noisy = a.noisy.any((r) => r[0] < e.endSample + fs && e.startSample - fs < r[1]);
      if (noisy || (tot > 0 && bad / tot >= 0.2)) uncertainEv.add(k);
    }

    final reasons = <String>[];
    var level = ConfidenceLevel.high;
    void lower(ConfidenceLevel l, String why) {
      if (l.index > level.index) level = l;
      reasons.add(why);
    }

    if (readable < 70) {
      lower(ConfidenceLevel.low, 'tylko ${readable.round()}% zapisu bez zakłóceń');
    } else if (readable < 90) {
      lower(ConfidenceLevel.medium, '${(100 - readable).round()}% zapisu z zakłóceniami');
    }
    if (beatsReadable < 85) {
      lower(ConfidenceLevel.low, '${(100 - beatsReadable).round()}% pobudzeń nieczytelnych');
    } else if (beatsReadable < 95) {
      lower(ConfidenceLevel.medium, '${(100 - beatsReadable).round()}% pobudzeń nieczytelnych');
    }
    final v = (s['v'] ?? 0).toInt(), sv = (s['s'] ?? 0).toInt();
    if (v >= 10 && uv / v > 0.3) lower(ConfidenceLevel.medium, '$uv z $v pobudzeń V z niepewną klasyfikacją');
    if (sv >= 10 && us / sv > 0.3) lower(ConfidenceLevel.medium, '$us z $sv pobudzeń S z niepewną klasyfikacją');
    if (uncertainEv.isNotEmpty) {
      reasons.add('${uncertainEv.length} z ${a.events.length} zdarzeń w zakłóconych fragmentach');
    }
    return AnalysisConfidence(level, readable, beatsReadable, uv, us, uncertainEv, reasons);
  }
}

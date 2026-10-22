part of 'analyzer.dart';

/// Trend odcinka ST i epizody jego zmian (jak w analizie holterowskiej / European ST-T DB).
///
/// W oknach 10 s mediana czytelnych pobudzeń N (poza AF); ST = poziom w J+60 ms względem linii
/// izoelektrycznej PR (najbardziej płaski fragment 40–120 ms przed R). Punkt J wyznaczany raz,
/// z mediany pobudzeń całego zapisu. Zmiana ST = odchylenie względem odniesienia (mediana pierwszych
/// 5 min czytelnego zapisu). Epizod: |zmiana| ≥ stDevUv przez ≥ 30 s (przerwy < 30 s łączone).
/// Uwaga: w odprowadzeniu z opaski ST zmienia się też ze zmianą pozycji ciała – wynik orientacyjny.
extension _StTrend on _Ctx {
  static const stepSec = 10;

  /// (próbka środka okna, odchylenie ST [µV] względem odniesienia) – NaN, gdy okno nieczytelne.
  List<(int, double)> stTrend() {
    final out = <(int, double)>[];
    final normals = [
      for (var i = 0; i < n; i++)
        if (labels[i] == BeatType.normal && inAf[i] == 0 && beatNoisy[i] == 0) i
    ];
    if (normals.length < 30) return out;
    final global = _medianBeat(_spread(normals, 300), wide: true);
    final jOff = _jOffset(global);
    if (jOff == null) return out;
    final stOff = jOff + (0.06 * fs).round();
    if (stOff >= _wPost) return out;

    final step = stepSec * fs;
    var k = 0;
    final raw = <(int, double)>[];
    for (var w0 = r.isEmpty ? 0 : r.first; n > 0 && w0 < r.last; w0 += step) {
      final idx = <int>[];
      while (k < normals.length && r[normals[k]] < w0) {
        k++;
      }
      for (var q = k; q < normals.length && r[normals[q]] < w0 + step; q++) {
        idx.add(normals[q]);
      }
      if (idx.length < 5) {
        raw.add((w0 + step ~/ 2, double.nan));
        continue;
      }
      final b = _medianBeat(idx, wide: true);
      final iso = _isoLevel(b);
      raw.add((w0 + step ~/ 2, b[_wPre + stOff] - iso));
    }
    // Odniesienie: mediana pierwszych 5 min czytelnych okien.
    final first = [for (final p in raw) if (!p.$2.isNaN) p.$2].take(300 ~/ stepSec).toList();
    if (first.length < 6) return out;
    final ref = _median(first);
    // Wygładzanie: mediana z ±stSmooth okien (odporna na pojedyncze zaburzone okna).
    final h = cfg.stSmooth.round();
    for (var i = 0; i < raw.length; i++) {
      final v = [
        for (var q = max(0, i - h); q <= min(raw.length - 1, i + h); q++)
          if (!raw[q].$2.isNaN) raw[q].$2
      ];
      out.add((raw[i].$1, raw[i].$2.isNaN || v.isEmpty ? double.nan : _median(v) - ref));
    }
    return out;
  }

  /// Koniec QRS (punkt J) w próbkach po R: pierwszy płaski odcinek 20–140 ms po R.
  int? _jOffset(Float64List t) {
    var maxSlope = 0.0;
    for (var i = _wPre - (0.06 * fs).round(); i < _wPre + (0.06 * fs).round(); i++) {
      maxSlope = max(maxSlope, (t[i + 1] - t[i]).abs());
    }
    if (maxSlope <= 0) return null;
    for (var d = (0.02 * fs).round(); d < (0.14 * fs).round(); d++) {
      final i = _wPre + d;
      if ((t[i + 1] - t[i]).abs() < 0.12 * maxSlope && (t[i + 2] - t[i + 1]).abs() < 0.12 * maxSlope) return d;
    }
    return null;
  }

  /// Poziom izoelektryczny: średnia najbardziej płaskiego okna 20 ms w zakresie 40–120 ms przed R.
  double _isoLevel(Float64List t) {
    final w = max(2, (0.02 * fs).round());
    var best = double.infinity, level = 0.0;
    for (var a = _wPre - (0.12 * fs).round(); a + w <= _wPre - (0.04 * fs).round(); a++) {
      var mn = double.infinity, mx = -double.infinity, s = 0.0;
      for (var i = a; i < a + w; i++) {
        mn = min(mn, t[i]);
        mx = max(mx, t[i]);
        s += t[i];
      }
      if (mx - mn < best) {
        best = mx - mn;
        level = s / w;
      }
    }
    return level;
  }

  void _stEvents(List<EcgEvent> ev) {
    final trend = stTrend();
    if (trend.isEmpty) return;
    final thr = cfg.stDevUv;
    final minLen = (cfg.stMinSec / stepSec).ceil(), maxGap = 30 ~/ stepSec;
    var i = 0;
    while (i < trend.length) {
      final v = trend[i].$2;
      if (v.isNaN || v.abs() < thr) {
        i++;
        continue;
      }
      final sign = v.sign;
      var j = i, gap = 0, last = i;
      while (j + 1 < trend.length && gap <= maxGap) {
        j++;
        final x = trend[j].$2;
        if (!x.isNaN && x.sign == sign && x.abs() >= thr) {
          last = j;
          gap = 0;
        } else {
          gap++;
        }
      }
      if (last - i + 1 >= minLen) {
        var peak = 0.0;
        for (var q = i; q <= last; q++) {
          if (!trend[q].$2.isNaN && trend[q].$2.abs() > peak.abs()) peak = trend[q].$2;
        }
        final a = trend[i].$1 - stepSec * fs ~/ 2, b = trend[last].$1 + stepSec * fs ~/ 2;
        ev.add(EcgEvent(sign < 0 ? EventType.stDepression : EventType.stElevation, a, b,
            'maks. ${peak > 0 ? '+' : ''}${peak.round()} µV względem początku zapisu, czas ${_dur(b - a)} (orientacyjnie)'));
      }
      i = last + 1;
    }
  }
}

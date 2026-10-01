import 'dart:math';
import 'dart:typed_data';

import 'filters.dart';

/// Detektor zespołów QRS wg Pan & Tompkins (1985), z adaptacyjnymi progami,
/// wyszukiwaniem wstecz (searchback) i odrzucaniem załamków T.
///
/// Sygnał wejściowy: już przefiltrowane EKG (0.5–40 Hz). Przetwarzanie blokami
/// po 2 minuty z zakładką, żeby działało na wielogodzinnych zapisach.
class QrsDetector {
  final int fs;

  QrsDetector(this.fs);

  /// Zwraca indeksy załamków R (w sygnale [f]) dla fragmentu [start, end).
  List<int> detect(Float32List f, int start, int end) {
    final block = fs * 120, overlap = fs * 5;
    final peaks = <int>[];
    for (var cs = start; cs < end; cs += block) {
      final ce = min(cs + block, end);
      final a = max(start, cs - overlap), b = min(end, ce + overlap);
      for (final p in _detectBlock(f, a, b)) {
        if (p >= cs && p < ce) peaks.add(p);
      }
    }
    return _refine(f, peaks, start, end);
  }

  List<int> _detectBlock(Float32List f, int a, int b) {
    final n = b - a;
    if (n < fs * 2) return const [];

    // Pasmo detekcji 5–18 Hz.
    final x = Float64List(n);
    for (var i = 0; i < n; i++) {
      x[i] = f[a + i];
    }
    filtfilt(x, [Biquad.highpass(5, fs.toDouble()), Biquad.lowpass(18, fs.toDouble())]);

    // Pochodna 5-punktowa (symetryczna) i kwadrat.
    final d = Float64List(n);
    final sq = Float64List(n);
    for (var i = 2; i < n - 2; i++) {
      final v = (-x[i - 2] - 2 * x[i - 1] + 2 * x[i + 1] + x[i + 2]) / 8;
      d[i] = v;
      sq[i] = v * v;
    }

    // Całkowanie w oknie ruchomym 150 ms (wyśrodkowane).
    final w = max(3, (0.15 * fs).round());
    final half = w ~/ 2;
    final mwi = Float64List(n);
    var acc = 0.0;
    for (var i = 0; i < n + half; i++) {
      if (i < n) acc += sq[i];
      if (i - w >= 0) acc -= sq[i - w];
      final c = i - half;
      if (c >= 0 && c < n) mwi[c] = acc / w;
    }

    // Kandydaci: maksima lokalne MWI.
    final cands = <int>[];
    for (var i = 1; i < n - 1; i++) {
      if (mwi[i] > mwi[i - 1] && mwi[i] >= mwi[i + 1]) cands.add(i);
    }
    if (cands.isEmpty) return const [];

    final refractory = (0.2 * fs).round();
    final tWaveWindow = (0.36 * fs).round();
    final slopeHalf = (0.075 * fs).round();
    double slopeAt(int p) {
      var m = 0.0;
      for (var i = max(0, p - slopeHalf); i <= min(n - 1, p + slopeHalf); i++) {
        m = max(m, d[i].abs());
      }
      return m;
    }

    // Inicjalizacja progów z pierwszych 2 s.
    var maxInit = 0.0, sumInit = 0.0;
    final initN = min(n, 2 * fs);
    for (var i = 0; i < initN; i++) {
      maxInit = max(maxInit, mwi[i]);
      sumInit += mwi[i];
    }
    var spki = 0.33 * maxInit;
    var npki = 0.5 * sumInit / initN;
    double thr1() => npki + 0.25 * (spki - npki);

    final qrs = <int>[];
    final slopes = <double>[];
    final noiseSinceLast = <int>[];

    double rrAvg() {
      if (qrs.length < 3) return 0;
      final k = min(8, qrs.length - 1);
      return (qrs.last - qrs[qrs.length - 1 - k]) / k;
    }

    void accept(int p, double weight) {
      qrs.add(p);
      slopes.add(slopeAt(p));
      spki = weight * mwi[p] + (1 - weight) * spki;
      noiseSinceLast.clear();
    }

    for (final p in cands) {
      // Wyszukiwanie wstecz: zbyt długo bez QRS – weź najsilniejszego kandydata ponad progiem 2.
      final avg = rrAvg();
      if (avg > 0 && qrs.isNotEmpty && p - qrs.last > 1.66 * avg) {
        final thr2 = 0.5 * thr1();
        int? best;
        for (final c in noiseSinceLast) {
          if (c - qrs.last >= refractory && p - c >= refractory && mwi[c] > thr2) {
            if (best == null || mwi[c] > mwi[best]) best = c;
          }
        }
        if (best != null) accept(best, 0.25);
      }

      final v = mwi[p];
      if (v > thr1()) {
        if (qrs.isNotEmpty && p - qrs.last < refractory) {
          if (v > mwi[qrs.last]) {
            qrs.removeLast();
            slopes.removeLast();
            accept(p, 0.125);
          }
          continue;
        }
        if (qrs.isNotEmpty && p - qrs.last < tWaveWindow && slopeAt(p) < 0.5 * slopes.last) {
          npki = 0.125 * v + 0.875 * npki; // załamek T
          noiseSinceLast.add(p);
          continue;
        }
        accept(p, 0.125);
      } else {
        npki = 0.125 * v + 0.875 * npki;
        noiseSinceLast.add(p);
      }
    }
    return [for (final p in qrs) a + p];
  }

  /// Przesunięcie znacznika na szczyt załamka R w przefiltrowanym sygnale
  /// (z uwzględnieniem dominującej polaryzacji) i usunięcie duplikatów.
  List<int> _refine(Float32List f, List<int> peaks, int start, int end) {
    if (peaks.isEmpty) return peaks;
    final win = (0.1 * fs).round();
    var pos = 0;
    for (final p in peaks) {
      var mx = -double.infinity, mn = double.infinity;
      for (var i = max(start, p - win); i < min(end, p + win + 1); i++) {
        mx = max(mx, f[i]);
        mn = min(mn, f[i]);
      }
      if (mx >= -mn) pos++;
    }
    final polarity = pos * 2 >= peaks.length ? 1.0 : -1.0;

    final out = <int>[];
    final refractory = (0.2 * fs).round();
    for (final p in peaks) {
      var best = p;
      var bv = -double.infinity;
      for (var i = max(start, p - win); i < min(end, p + win + 1); i++) {
        final v = polarity * f[i];
        if (v > bv) {
          bv = v;
          best = i;
        }
      }
      if (out.isNotEmpty && best - out.last < refractory) {
        if (polarity * f[best] > polarity * f[out.last]) out[out.length - 1] = best;
      } else {
        out.add(best);
      }
    }
    return out;
  }
}

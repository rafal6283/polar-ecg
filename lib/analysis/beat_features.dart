part of 'analyzer.dart';

/// Cechy pobudzenia dla klasyfikatora (kolejność = wejścia sieci).
const beatFeatureNames = [
  'rr_pre/lokalny', 'rr_post/lokalny', 'rr_pre/rr_poprz', 'rr_post/rr_pre', 'lokalny/globalny', 'rr_pre [s]', //
  'korelacja QRS', 'szerokość QRS', 'amplituda p2p', 'wysokość R', //
  'korelacja P', 'energia P', 'korelacja ST-T', 'przesunięcie ST-T', 'energia QRS', 'szum', 'korelacja z poprzednim', //
  'różnica 1', 'różnica 2', 'różnica 3', 'różnica 4', 'różnica 5', //
  'różnica 6', 'różnica 7', 'różnica 8', 'różnica 9', 'różnica 10',
];

extension _BeatFeatures on _Ctx {
  /// Szerokie okno pobudzenia: od -300 ms (załamek P) do +450 ms (załamek T).
  Float64List? _wideWindow(int i) {
    final s = tl.segments[seg[i]];
    final a = r[i] - _wPre, b = r[i] + _wPost;
    if (a < s.start || b >= s.end) return null;
    final w = Float64List(b - a + 1);
    for (var k = 0; k < w.length; k++) {
      w[k] = f[a + k];
    }
    return w;
  }

  Float64List beatFeatures(int i, Float64List? t, Float64List? wt, double globalRr, Float64List prem, Float64List next) {
    final out = Float64List(beatFeatureNames.length);
    double safe(double v, double def, double lo, double hi) => (v.isNaN || v.isInfinite) ? def : v.clamp(lo, hi);
    final loc = _loc[i];
    out[0] = safe(prem[i], 1, 0, 4);
    out[1] = safe(next[i], 1, 0, 4);
    out[2] = (i >= 2 && rr(i) > 0 && rr(i - 1) > 0) ? safe(rr(i) / rr(i - 1), 1, 0, 4) : 1;
    out[3] = (i + 1 < n && rr(i + 1) > 0 && rr(i) > 0) ? safe(rr(i + 1) / rr(i), 1, 0, 4) : 1;
    out[4] = safe(loc / globalRr, 1, 0, 4);
    out[5] = safe((rr(i) > 0 ? rr(i) : loc) / fs, 0.8, 0, 4);

    final w = _window(i);
    if (w != null && t != null) {
      final amp = _Ctx._p2p(t);
      out[6] = _Ctx._pearson(w, t);
      out[7] = safe(_Ctx._eqWidth(w) / _Ctx._eqWidth(t), 1, 0, 5);
      out[8] = safe(_ampRatio[i], 1, 0, 5);
      out[9] = safe(_peakRatio[i], 1, -3, 3);
      var eb = 0.0, et = 0.0;
      for (var k = 0; k < w.length; k++) {
        eb += w[k] * w[k];
        et += t[k] * t[k];
      }
      out[14] = safe(eb / max(1, et), 1, 0, 10);
      for (var j = 0; j < 10; j++) {
        final k = (j * (w.length - 1) / 9).round();
        out[17 + j] = safe((w[k] - t[k]) / amp, 0, -3, 3);
      }
      if (i > 0 && seg[i - 1] == seg[i]) {
        final wp = _window(i - 1);
        out[16] = wp == null ? 1 : _Ctx._pearson(w, wp);
      } else {
        out[16] = 1;
      }
    } else {
      out[6] = 1;
      out[7] = 1;
      out[8] = 1;
      out[9] = 1;
      out[14] = 1;
      out[16] = 1;
    }

    final ww = _wideWindow(i);
    if (ww != null && wt != null) {
      final amp = max(1.0, _Ctx._p2p(t ?? wt));
      final p0 = _wPre - (0.25 * fs).round(), p1 = _wPre - (0.06 * fs).round();
      final t0 = _wPre + (0.15 * fs).round(), t1 = _wPre + (0.40 * fs).round();
      final bp = Float64List.sublistView(ww, p0, p1), tp = Float64List.sublistView(wt, p0, p1);
      out[10] = _Ctx._pearson(Float64List.fromList(bp), Float64List.fromList(tp));
      out[11] = safe(_std(bp) / max(1, _std(tp)), 1, 0, 10);
      final bt = Float64List.fromList(Float64List.sublistView(ww, t0, t1));
      final tt = Float64List.fromList(Float64List.sublistView(wt, t0, t1));
      out[12] = _Ctx._pearson(bt, tt);
      out[13] = safe((_mean(bt) - _mean(tt)) / amp, 0, -3, 3);
    } else {
      out[10] = 1;
      out[11] = 1;
      out[12] = 1;
      out[13] = 0;
    }
    out[15] = safe(_noiseIdx[i] * 10, 0, 0, 5);
    return out;
  }

  static double _mean(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

  static double _std(List<double> v) {
    if (v.length < 2) return 0;
    final m = _mean(v);
    return sqrt(v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / v.length);
  }
}

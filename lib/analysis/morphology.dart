import 'dart:math';
import 'dart:typed_data';

import 'analysis_result.dart';
import 'ecg_recording.dart';

/// mean2-8Hz: udział energii sygnału w paśmie 2–8 Hz [%] względem pasma 0.5–40 Hz,
/// średnio z 8-sekundowych okien bez artefaktów (do 200 okien rozłożonych w zapisie).
double? bandEnergy2to8(Float32List f, Timeline tl, List<List<int>> noisy) {
  final fs = tl.sampleRate;
  const nfft = 1024; // ~7.9 s przy 130 Hz
  final starts = <int>[];
  for (final s in tl.segments) {
    for (var a = s.start; a + nfft <= s.end; a += nfft) {
      if (!noisy.any((r) => r[0] < a + nfft && r[1] > a)) starts.add(a);
    }
  }
  if (starts.isEmpty) return null;
  final pick = starts.length <= 200 ? starts : [for (var k = 0; k < 200; k++) starts[k * starts.length ~/ 200]];
  final re = Float64List(nfft), im = Float64List(nfft);
  final hann = Float64List.fromList([for (var i = 0; i < nfft; i++) 0.5 - 0.5 * cos(2 * pi * i / (nfft - 1))]);
  var sum = 0.0;
  for (final a in pick) {
    var mean = 0.0;
    for (var i = 0; i < nfft; i++) {
      mean += f[a + i];
    }
    mean /= nfft;
    for (var i = 0; i < nfft; i++) {
      re[i] = (f[a + i] - mean) * hann[i];
      im[i] = 0;
    }
    _fft(re, im);
    var band = 0.0, total = 0.0;
    for (var k = 1; k < nfft ~/ 2; k++) {
      final hz = k * fs / nfft;
      final p = re[k] * re[k] + im[k] * im[k];
      if (hz >= 0.5 && hz <= 40) total += p;
      if (hz >= 2 && hz <= 8) band += p;
    }
    if (total > 0) sum += 100 * band / total;
  }
  return sum / pick.length;
}

/// FFT radix-2 w miejscu (n = potęga 2).
void _fft(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      var t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * pi / len;
    final wr = cos(ang), wi = sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final ur = re[i + k], ui = im[i + k];
        final vr = re[i + k + len ~/ 2] * cr - im[i + k + len ~/ 2] * ci;
        final vi = re[i + k + len ~/ 2] * ci + im[i + k + len ~/ 2] * cr;
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + len ~/ 2] = ur - vr;
        im[i + k + len ~/ 2] = ui - vi;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}

/// Pomiary morfologii na uśrednionym zespole (mediana z prawidłowych pobudzeń).
///
/// Sygnał 130 Hz jest interpolowany (Catmull-Rom, ×8) do ~1 kHz, żeby wyznaczyć
/// punkty charakterystyczne dokładniej niż co 7.7 ms. Mimo to dokładność odstępów
/// to ok. ±10 ms, a odprowadzenie z opaski piersiowej nie jest standardowym
/// odprowadzeniem EKG – wartości są orientacyjne.
class Morphology {
  static const preSec = 0.3, postSec = 0.6;

  /// Uśredniony zespół w µV, próbkowanie [fs], R w indeksie [pre].
  final Float32List template;
  final int pre;
  final Map<String, num?> values;

  Morphology(this.template, this.pre, this.values);
}

Morphology? measureMorphology(
  Float32List f,
  Int32List r,
  Uint8List labels,
  Uint8List inAf,
  Timeline tl,
) {
  final fs = tl.sampleRate;
  final pre = (Morphology.preSec * fs).round(), post = (Morphology.postSec * fs).round();
  final len = pre + post + 1;

  bool sameSeg(int a, int b) => tl.segmentIndexOf(r[a]) == tl.segmentIndexOf(r[b]);
  final good = <int>[];
  final nn = <double>[];
  for (var i = 1; i < r.length - 1; i++) {
    if (labels[i] != BeatType.normal || labels[i - 1] != BeatType.normal || labels[i + 1] != BeatType.normal) continue;
    if (inAf[i] == 1 || !sameSeg(i - 1, i) || !sameSeg(i, i + 1)) continue;
    final s = tl.segments[tl.segmentIndexOf(r[i])];
    if (r[i] - pre < s.start || r[i] + post >= s.end) continue;
    good.add(i);
    nn.add((r[i] - r[i - 1]) * 1000 / fs);
  }
  if (good.length < 8) return null;

  // Mediana próbka po próbce z maks. 300 pobudzeń rozłożonych w całym zapisie.
  final pick = good.length <= 300 ? good : [for (var k = 0; k < 300; k++) good[k * good.length ~/ 300]];
  final tpl = Float32List(len);
  final col = Float64List(pick.length);
  for (var k = 0; k < len; k++) {
    for (var j = 0; j < pick.length; j++) {
      col[j] = f[r[pick[j]] - pre + k];
    }
    col.sort();
    tpl[k] = col[col.length >> 1];
  }
  nn.sort();
  final rrMs = nn[nn.length >> 1];

  // Interpolacja ×8.
  const up = 8;
  final y = Float64List((len - 1) * up + 1);
  for (var k = 0; k < len - 1; k++) {
    final p0 = tpl[max(0, k - 1)], p1 = tpl[k], p2 = tpl[k + 1], p3 = tpl[min(len - 1, k + 2)];
    for (var u = 0; u < up; u++) {
      final t = u / up, t2 = t * t, t3 = t2 * t;
      y[k * up + u] = 0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
    }
  }
  y[y.length - 1] = tpl[len - 1];
  final dt = 1000 / (fs * up); // ms na punkt
  int at(double ms) => (pre * up + ms / dt).round().clamp(0, y.length - 1);
  double msOf(int idx) => (idx - pre * up) * dt;
  final dy = Float64List(y.length);
  for (var i = 1; i < y.length - 1; i++) {
    dy[i] = (y[i + 1] - y[i - 1]) / (2 * dt);
  }
  final rIdx = pre * up;

  // Linia izoelektryczna: najbardziej płaskie 20 ms w odcinku PR (R-120…R-30 ms).
  final w20 = (20 / dt).round();
  var bestFlat = double.infinity, b = 0.0, bIdx = at(-60);
  for (var s = at(-120); s + w20 <= at(-30); s++) {
    var mn = double.infinity, mx = -double.infinity, sum = 0.0;
    for (var k = s; k < s + w20; k++) {
      mn = min(mn, y[k]);
      mx = max(mx, y[k]);
      sum += y[k];
    }
    if (mx - mn < bestFlat) {
      bestFlat = mx - mn;
      b = sum / w20;
      bIdx = s + w20 ~/ 2;
    }
  }
  final rAmp = y[rIdx] - b;

  // QRS: początek przed najbardziej stromym narastaniem, koniec (J) po ostatnim stromym odcinku.
  var maxSlope = 0.0;
  for (var i = at(-80); i <= at(100); i++) {
    maxSlope = max(maxSlope, dy[i].abs());
  }
  if (maxSlope <= 0) return null;
  var m1 = rIdx;
  for (var i = at(-80); i <= rIdx; i++) {
    if (dy[i].abs() > dy[m1].abs()) m1 = i;
  }
  var onset = at(-150);
  for (var i = m1; i >= at(-150); i--) {
    if (dy[i].abs() < 0.1 * maxSlope && (y[i] - b).abs() < 0.15 * rAmp.abs()) {
      onset = i;
      break;
    }
  }
  var lastSteep = rIdx;
  for (var i = rIdx; i <= at(150); i++) {
    if (dy[i].abs() > 0.15 * maxSlope) lastSteep = i;
  }
  var j = lastSteep;
  for (var i = lastSteep; i <= at(200); i++) {
    if (dy[i].abs() < 0.1 * maxSlope) {
      j = i;
      break;
    }
  }
  var sAmp = 0.0;
  for (var i = rIdx; i <= j; i++) {
    sAmp = min(sAmp, y[i] - b);
  }

  // Załamek T: największe odchylenie od linii izoelektrycznej po J.
  final tWinEnd = min(at(min(600.0, 0.75 * rrMs)), y.length - 2);
  final tStart = j + (40 / dt).round();
  int? tPeak, tEnd;
  double? tAmp;
  if (tWinEnd - tStart > (60 / dt)) {
    var best = tStart;
    for (var i = tStart; i <= tWinEnd; i++) {
      if ((y[i] - b).abs() > (y[best] - b).abs()) best = i;
    }
    tPeak = best;
    tAmp = y[best] - b;
    // Koniec T metodą stycznej: najbardziej strome zejście po szczycie, przecięcie z linią izoelektryczną.
    var m = best;
    for (var i = best; i <= tWinEnd; i++) {
      final returning = tAmp > 0 ? dy[i] < dy[m] : dy[i] > dy[m];
      if (returning) m = i;
    }
    if (dy[m].abs() > 1e-6 && m > best) {
      tEnd = (m + (b - y[m]) / dy[m] / dt).round().clamp(best, tWinEnd); // dy w µV/ms
    }
  }

  // Załamek P przed QRS.
  int? pOn;
  double? pAmp;
  final pFrom = max(0, onset - (250 / dt).round()), pTo = onset - (40 / dt).round();
  if (pTo - pFrom > 40 / dt) {
    var best = pFrom;
    for (var i = pFrom; i <= pTo; i++) {
      if ((y[i] - b).abs() > (y[best] - b).abs()) best = i;
    }
    final amp = y[best] - b;
    if (amp.abs() > max(25.0, 3 * bestFlat)) {
      pAmp = amp;
      pOn = pFrom;
      for (var i = best; i >= pFrom; i--) {
        if ((y[i] - b).abs() < 0.15 * amp.abs()) {
          pOn = i;
          break;
        }
      }
    }
  }

  // Odsetek pobudzeń z dodatnim T (pomiar w punkcie szczytu T z wzorca).
  double? tPosPct;
  if (tPeak != null) {
    final tS = (msOf(tPeak) / 1000 * fs).round(), bS = (msOf(bIdx) / 1000 * fs).round();
    final h = max(1, (0.02 * fs).round());
    var pos = 0, cnt = 0;
    for (final i in good) {
      var tv = 0.0, bv = 0.0;
      for (var k = -h; k <= h; k++) {
        tv += f[r[i] + tS + k];
        bv += f[r[i] + bS + k];
      }
      cnt++;
      if (tv > bv) pos++;
    }
    tPosPct = 100 * pos / cnt;
  }

  final qt = tEnd == null ? null : (tEnd - onset) * dt;

  // meanSystole: średnia |U - linia izoelektryczna| od początku QRS do końca T (skurcz komór).
  double? systole;
  if (tEnd != null && tEnd > onset) {
    var s = 0.0;
    for (var i = onset; i <= tEnd; i++) {
      s += (y[i] - b).abs();
    }
    systole = s / (tEnd - onset + 1);
  }
  final rrS = rrMs / 1000;
  double? stAt(double msAfterJ) {
    final k = j + (msAfterJ / dt).round();
    return k < y.length ? y[k] - b : null;
  }

  return Morphology(tpl, pre, {
    'rr_ms': rrMs,
    'qrs_ms': (j - onset) * dt,
    'pr_ms': pOn == null ? null : (onset - pOn) * dt,
    'qt_ms': qt,
    'qtc_ms': qt == null ? null : qt / sqrt(rrS),
    'qtcf_ms': qt == null ? null : qt / pow(rrS, 1 / 3),
    'p_uv': pAmp,
    'r_uv': rAmp,
    's_uv': sAmp,
    'j_uv': y[j] - b,
    'st60_uv': stAt(60),
    't_uv': tAmp,
    't_pos_pct': tPosPct,
    'systole_uv': systole,
    // Położenia punktów względem R [ms] – do rysowania.
    'm_p_on': pOn == null ? null : msOf(pOn),
    'm_qrs_on': msOf(onset),
    'm_j': msOf(j),
    'm_t_peak': tPeak == null ? null : msOf(tPeak),
    'm_t_end': tEnd == null ? null : msOf(tEnd),
    'm_base': msOf(bIdx),
    'm_base_uv': b,
    'beats_averaged': pick.length,
  });
}

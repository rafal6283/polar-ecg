part of 'analyzer.dart';

/// Rytmy wymagające analizy aktywności przedsionków: blok AV II° i trzepotanie przedsionków.
/// Oba wyniki są oznaczane jako podejrzenie – jedno odprowadzenie z opaski i 130 Hz to mało
/// na pewne rozpoznanie (walidacja: tool/rhythm_eval.dart, mitdb 231 / 202, 203, 222, afdb).
extension _AtrialRhythms on _Ctx {
  // ---------------- Blok AV II° ----------------

  /// Załamek P bez zespołu QRS: w odstępie RR (po załamku T) szukamy kształtu zgodnego z własnym
  /// załamkiem P pacjenta (korelacja, amplituda), położonego mniej więcej w połowie między
  /// załamkami P przewiedzionymi (stały rytm zatokowy: P–P równe). Zdarzenie przy ≥ avbMin takich
  /// załamkach w odstępach < 60 s.
  void _avBlocks(List<EcgEvent> ev) {
    final normals = [
      for (var i = 0; i < n; i++)
        if (labels[i] == BeatType.normal && inAf[i] == 0 && beatNoisy[i] == 0) i
    ];
    if (normals.length < 30) return;
    final wide = _medianBeat(_spread(normals, 300), wide: true);
    // Załamek P wzorca: 250–60 ms przed R; wymagamy wyraźnego P.
    final p0 = _wPre - (0.25 * fs).round(), p1 = _wPre - (0.06 * fs).round();
    final pTpl = Float64List.sublistView(wide, p0, p1);
    final pAmp = _Ctx._p2p(Float64List.fromList(pTpl));
    if (pAmp < 40) return;
    // Położenie szczytu P względem R (do wyznaczenia czasu załamków P przewiedzionych).
    var pk = 0;
    final pm = _mean(pTpl);
    for (var k = 0; k < pTpl.length; k++) {
      if ((pTpl[k] - pm).abs() > (pTpl[pk] - pm).abs()) pk = k;
    }
    final pToR = _wPre - (p0 + pk); // próbki od szczytu P do R
    final len = pTpl.length;
    final tpl = Float64List.fromList(pTpl);
    final tm = _mean(tpl);
    var tn = 0.0;
    for (final v in tpl) {
      tn += (v - tm) * (v - tm);
    }
    tn = sqrt(tn);

    final blocked = <int>[]; // próbka zablokowanego P
    for (var i = 1; i < n; i++) {
      if (!cleanRr(i) || labels[i] != BeatType.normal || labels[i - 1] != BeatType.normal) continue;
      if (inAf[i] == 1 || inAf[i - 1] == 1) continue;
      final pa = r[i - 1] - pToR, pb = r[i] - pToR; // załamki P przewiedzione
      final from = r[i - 1] + (0.42 * fs).round(); // po załamku T
      final to = pb - (0.12 * fs).round();
      if (to - from < len) continue;
      var best = -1.0, bestAt = -1;
      for (var a = from; a + len <= to; a++) {
        final c = _corrAt(a, tpl, tm, tn);
        if (c > best) {
          best = c;
          bestAt = a;
        }
      }
      if (best < cfg.avbCorr || bestAt < 0) continue;
      final seg = Float64List.fromList([for (var k = bestAt; k < bestAt + len; k++) f[k].toDouble()]);
      final ar = _Ctx._p2p(seg) / pAmp;
      if (ar < 0.6 || ar > 1.6) continue;
      final pAt = bestAt + pk;
      // Połowa drogi między przewiedzionymi P (±15% odstępu).
      final mid = (pa + pb) / 2;
      if ((pAt - mid).abs() > 0.15 * (pb - pa)) continue;
      blocked.add(pAt);
    }
    // Zdarzenia: ≥ avbMin zablokowanych P w odstępach < 60 s.
    var i = 0;
    while (i < blocked.length) {
      var j = i;
      while (j + 1 < blocked.length && blocked[j + 1] - blocked[j] < 60 * fs) {
        j++;
      }
      if (j - i + 1 >= cfg.avbMin) {
        ev.add(EcgEvent(EventType.avBlock2, blocked[i] - fs, blocked[j] + fs,
            '${j - i + 1} załamków P bez zespołu QRS'));
      }
      i = j + 1;
    }
  }

  // ---------------- Trzepotanie przedsionków ----------------

  /// Okna 8 s (także w AF – trzepotanie ze zmiennym przewodzeniem bywa rozpoznane jako AF): zespoły QRS (±60 ms) zastąpione interpolacją liniową, a w pozostałym sygnale
  /// szukamy silnej okresowości 210–390/min (fale F): autokorelacja w tym zakresie opóźnień
  /// ≥ aflCorr i dominujący prążek widma 3.5–6.5 Hz. Rytm komór regularny lub nieregularny.
  void _flutter(List<EcgEvent> ev) {
    final win = 8 * fs, step = 4 * fs;
    final hits = <int>[];
    for (final s in tl.segments) {
      for (var a = s.start; a + win <= s.end; a += step) {
        final k0 = beatIndexAtOrAfter(a);
        var k1 = k0;
        var bad = false;
        while (k1 < n && r[k1] < a + win) {
          if (beatNoisy[k1] == 1 || labels[k1] == BeatType.ventricular) bad = true;
          k1++;
        }
        if (bad || k1 - k0 < 5) continue;
        final x = Float64List(win);
        for (var t = 0; t < win; t++) {
          x[t] = f[a + t].toDouble();
        }
        // Wycięcie QRS.
        final half = (0.06 * fs).round();
        for (var k = k0; k < k1; k++) {
          final c = r[k] - a;
          final lo = max(0, c - half), hi = min(win - 1, c + half);
          final ya = x[lo], yb = x[hi];
          for (var t = lo; t <= hi; t++) {
            x[t] = ya + (yb - ya) * (t - lo) / max(1, hi - lo);
          }
        }
        final m = _mean(x);
        for (var t = 0; t < win; t++) {
          x[t] -= m;
        }
        var e0 = 0.0;
        for (final v in x) {
          e0 += v * v;
        }
        if (e0 <= 0 || sqrt(e0 / win) < 15) continue;
        // Autokorelacja w zakresie fal F (0.154–0.286 s) i porównawczo krótsze opóźnienie (połowa).
        var bestR = -1.0, bestLag = 0;
        for (var lag = (0.154 * fs).round(); lag <= (0.286 * fs).round(); lag++) {
          var acc = 0.0;
          for (var t = 0; t + lag < win; t++) {
            acc += x[t] * x[t + lag];
          }
          final rr = acc / e0 * win / (win - lag);
          if (rr > bestR) {
            bestR = rr;
            bestLag = lag;
          }
        }
        if (bestR < cfg.aflCorr) continue;
        // Okres nie może być wielokrotnością rytmu komór z wyraźnym załamkiem T (wtedy to T/P).
        final hl = (bestLag / 2).round();
        var accH = 0.0;
        for (var t = 0; t + hl < win; t++) {
          accH += x[t] * x[t + hl];
        }
        if (accH / e0 > 0.3) continue; // okresowość o połowie okresu – raczej harmoniczne, nie fale F
        hits.add(a + win ~/ 2);
      }
    }
    // Epizody: ≥ 3 okna (≥ 16 s) z odstępami ≤ 1 okno.
    var i = 0;
    while (i < hits.length) {
      var j = i;
      while (j + 1 < hits.length && hits[j + 1] - hits[j] <= 2 * step) {
        j++;
      }
      if (j - i + 1 >= 3) {
        final a = hits[i] - win ~/ 2, b = hits[j] + win ~/ 2;
        final k0 = beatIndexAtOrAfter(a), k1 = beatIndexAtOrAfter(b);
        final hr = k1 - k0 > 1 ? _bpm(((r[k1 - 1] - r[k0]) / (k1 - 1 - k0)).round()) : 0;
        ev.add(EcgEvent(EventType.afl, a, b, 'czas ${_dur(b - a)}, rytm komór $hr/min'));
      }
      i = j + 1;
    }
  }

  /// Korelacja Pearsona sygnału od próbki a z wzorcem (średnia tm, norma tn).
  double _corrAt(int a, Float64List t, double tm, double tn) {
    final len = t.length;
    var m = 0.0;
    for (var k = 0; k < len; k++) {
      m += f[a + k];
    }
    m /= len;
    var num = 0.0, den = 0.0;
    for (var k = 0; k < len; k++) {
      final d = f[a + k] - m;
      num += d * (t[k] - tm);
      den += d * d;
    }
    return den <= 0 || tn <= 0 ? 0 : num / (sqrt(den) * tn);
  }

  int beatIndexAtOrAfter(int sample) {
    var lo = 0, hi = n;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (r[mid] < sample) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static double _mean(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
}

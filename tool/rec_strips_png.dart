// Paski EKG z zapisu aplikacji (H10) z etykietami analizy – przegląd zdarzeń na prawdziwych danych.
// dart run tool/rec_strips_png.dart <katalog_zapisu> <wyjście.png> <czas> [czas ...] [klucz=wartość ...]
// czas: sekundy od początku zapisu, mm:ss albo godzina zegarowa hh:mm:ss (z kropką: 23.04.10).
// Znaczniki: szary N, niebieski S, czerwony V, żółty Q; zielony pasek u dołu = AF wg analizy. Siatka 0.2 s / 0.5 mV.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';

import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

import 'png.dart';

const _w = 1400, _stripH = 220;

const targetFs = 130;

Future<void> main(List<String> args) async {
  final overrides = <String, double>{
    for (final a in args.where((a) => a.contains('='))) a.split('=')[0]: double.parse(a.split('=')[1]),
  };
  final pos = args.where((a) => !a.contains('=')).toList();
  final r = await analyzeRecordingDir(pos[0], settings: const AnalysisSettings().copyWith(overrides));
  final f = await loadFiltered(pos[0]);
  const fs = targetFs;
  int parse(String s) {
    if (s.contains('.')) {
      // godzina zegarowa
      final p = s.split('.').map(int.parse).toList();
      final st = r.timeline.started;
      var t = DateTime(st.year, st.month, st.day, p[0], p[1], p.length > 2 ? p[2] : 0);
      if (t.isBefore(st)) t = t.add(const Duration(days: 1));
      return r.timeline.sampleAt(t.difference(st));
    }
    if (s.contains(':')) {
      final p = s.split(':').map(int.parse).toList();
      return (p[0] * 60 + p[1]) * fs;
    }
    return (double.parse(s) * fs).round();
  }

  final starts = [for (final s in pos.skip(2)) max(0, parse(s) - 5 * fs)];
  final img = Img(_w, _stripH * starts.length);
  for (var si = 0; si < starts.length; si++) {
    final y0 = si * _stripH;
    final a = starts[si].clamp(0, f.length - 1), b = (starts[si] + 10 * fs).clamp(0, f.length - 1);
    int x(num s) => ((s - a) / (b - a) * (_w - 1)).round();
    int y(double uv) => (y0 + _stripH / 2 - uv / 2000 * (_stripH / 2)).round().clamp(y0, y0 + _stripH - 1);
    for (var s = a - a % (fs ~/ 5); s < b; s += fs ~/ 5) {
      if (s < a) continue;
      img.vline(x(s), y0, y0 + _stripH - 1, s % fs == 0 ? const [232, 161, 150] : const [246, 211, 204]);
    }
    img.hline(0, _w - 1, y0, const [120, 120, 120]);
    final lab = <String>[];
    for (var k = r.beatIndexAtOrAfter(a); k < r.rPeaks.length && r.rPeaks[k] < b; k++) {
      final col = const [
        [140, 140, 140],
        [21, 101, 192],
        [198, 40, 40],
        [200, 200, 0],
      ][r.labels[k]];
      final px = x(r.rPeaks[k]);
      for (var dx = -3; dx <= 3; dx++) {
        img.vline(px + dx, y0 + 2, y0 + 14, col);
      }
      if (r.inAf[k] == 1 && k + 1 < r.rPeaks.length) {
        for (var s = r.rPeaks[k]; s < r.rPeaks[k + 1] && s < b; s++) {
          img.vline(x(s), y0 + _stripH - 3, y0 + _stripH - 1, const [40, 160, 60]);
        }
      }
      lab.add(
        '${BeatType.letters[r.labels[k]]}${((r.rPeaks[k] - (k > 0 ? r.rPeaks[k - 1] : r.rPeaks[k])) * 1000 / fs).round()}',
      );
    }
    for (var s = a + 1; s < b; s++) {
      img.line(x(s - 1), y(f[s - 1]), x(s), y(f[s]), const [17, 17, 17]);
    }
    final clk = r.timeline.timeOf(starts[si]);
    print(
      'pasek ${si + 1}: ${clk.hour}:${clk.minute.toString().padLeft(2, '0')}:${clk.second.toString().padLeft(2, '0')}: ${lab.join(' ')}',
    );
  }
  File(pos[1]).writeAsBytesSync(img.png());
}

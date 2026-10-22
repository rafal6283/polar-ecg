// Paski EKG z bazy PhysioNet z etykietami analizy (diagnostyka algorytmów).
// dart run tool/mit_strips_png.dart <katalog> <rekord> <wyjście.png> <sekunda> [sekunda ...] [klucz=wartość ...]
// Znaczniki: szary N, niebieski S, czerwony V, żółty Q; zielony pasek u dołu = AF wg analizy,
// fioletowy = AF wg adnotacji. Siatka 0.2 s / 0.5 mV.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

import 'mitbih_io.dart';
import 'png.dart';

const _w = 1400, _stripH = 220;

void main(List<String> args) {
  final overrides = <String, double>{
    for (final a in args.where((a) => a.contains('='))) a.split('=')[0]: double.parse(a.split('=')[1]),
  };
  final pos = args.where((a) => !a.contains('=')).toList();
  final m = loadMitRecord(pos[0], pos[1]);
  final out = analyzeEcg(m.uv, m.timeline, settings: const AnalysisSettings().copyWith(overrides));
  final r = out.result, f = out.filtered;
  const fs = targetFs;
  final starts = [for (final s in pos.skip(3)) (double.parse(s) * fs).round()];
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
    for (final ref in m.afRanges) {
      for (var s = a; s < b; s++) {
        if (s >= ref[0] && s < ref[1]) img.vline(x(s), y0 + _stripH - 6, y0 + _stripH - 4, const [130, 60, 180]);
      }
    }
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
      lab.add('${BeatType.letters[r.labels[k]]}${((r.rPeaks[k] - (k > 0 ? r.rPeaks[k - 1] : r.rPeaks[k])) * 1000 / fs).round()}');
    }
    for (var s = a + 1; s < b; s++) {
      img.line(x(s - 1), y(f[s - 1]), x(s), y(f[s]), const [17, 17, 17]);
    }
    print('pasek ${si + 1}: t=${starts[si] ~/ fs} s: ${lab.join(' ')}');
  }
  File(pos[2]).writeAsBytesSync(img.png());
}

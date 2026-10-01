// Rysuje fragmenty EKG wokół pobudzeń innych niż N do pliku PNG (bez zależności).
// dart run tool/strips_png.dart <katalog_zapisu> [max_pasków]
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

import 'png.dart';

const _w = 1400, _stripH = 200;

Future<void> main(List<String> args) async {
  final path = args.first;
  final maxStrips = args.length > 1 ? int.parse(args[1]) : 6;
  final r = (await loadAnalysis(path))!;
  final f = await loadFiltered(path);
  final fs = r.sampleRate;
  final centers = <int>[];
  for (var i = 0; i < r.rPeaks.length && centers.length < maxStrips; i++) {
    if (r.labels[i] == BeatType.normal) continue;
    if (centers.isNotEmpty && r.rPeaks[i] - centers.last < 3 * fs) continue;
    centers.add(r.rPeaks[i]);
  }
  final img = Img(_w, _stripH * centers.length);
  for (var si = 0; si < centers.length; si++) {
    final y0 = si * _stripH;
    final a = (centers[si] - 4 * fs).clamp(0, f.length - 1), b = (centers[si] + 4 * fs).clamp(0, f.length - 1);
    int x(num s) => ((s - a) / (b - a) * (_w - 1)).round();
    int y(double uv) => (y0 + _stripH / 2 - uv / 2000 * (_stripH / 2)).round().clamp(y0, y0 + _stripH - 1);
    for (var s = a - a % (fs ~/ 5); s < b; s += fs ~/ 5) {
      if (s < a) continue;
      img.vline(x(s), y0, y0 + _stripH - 1, s % fs == 0 ? const [232, 161, 150] : const [246, 211, 204]);
    }
    img.hline(0, _w - 1, y0, const [120, 120, 120]);
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
    }
    for (var s = a + 1; s < b; s++) {
      img.line(x(s - 1), y(f[s - 1]), x(s), y(f[s]), const [17, 17, 17]);
    }
    print('pasek ${si + 1}: t=${(centers[si] / fs).toStringAsFixed(1)} s, etykiety: '
        '${[for (var k = r.beatIndexAtOrAfter(a); k < r.rPeaks.length && r.rPeaks[k] < b; k++) '${BeatType.letters[r.labels[k]]}${((r.rPeaks[k] - (k > 0 ? r.rPeaks[k - 1] : r.rPeaks[k])) * 1000 / fs).round()}'].join(' ')}');
  }
  final out = File('$path/strips.png')..writeAsBytesSync(img.png());
  print(out.path);
}


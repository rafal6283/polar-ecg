// Rysuje fragmenty EKG (±3 s) wokół pobudzeń innych niż N do pliku HTML/SVG.
// dart run tool/strips.dart <katalog_zapisu>   (po tool/analyze.dart)
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

Future<void> main(List<String> args) async {
  final path = args.first;
  final r = (await loadAnalysis(path))!;
  final f = await loadFiltered(path);
  final fs = r.sampleRate;
  final half = 3 * fs;
  const w = 1200.0, h = 220.0;
  final sb = StringBuffer('<html><body style="background:#fff;font-family:sans-serif">');
  var shown = 0;
  for (var i = 0; i < r.rPeaks.length && shown < 12; i++) {
    if (r.labels[i] == BeatType.normal) continue;
    if (i > 0 && r.labels[i - 1] != BeatType.normal) continue; // jeden pasek na grupę
    shown++;
    final c = r.rPeaks[i];
    final a = (c - half).clamp(0, f.length - 1), b = (c + half).clamp(0, f.length - 1);
    double x(int s) => (s - a) / (b - a) * w;
    double y(double uv) => h / 2 - uv / 2500 * (h / 2);
    sb.write('<h4>t = ${(c / fs).toStringAsFixed(2)} s</h4><svg width="$w" height="$h" style="border:1px solid #ddd">');
    for (var s = a - a % (fs ~/ 5); s < b; s += fs ~/ 5) {
      sb.write('<line x1="${x(s)}" x2="${x(s)}" y1="0" y2="$h" stroke="${s % fs == 0 ? '#e8a196' : '#f6d3cc'}"/>');
    }
    final pts = StringBuffer();
    for (var s = a; s < b; s++) {
      pts.write('${x(s).toStringAsFixed(1)},${y(f[s]).toStringAsFixed(1)} ');
    }
    sb.write('<polyline points="$pts" fill="none" stroke="#111" stroke-width="1.3"/>');
    for (var k = r.beatIndexAtOrAfter(a); k < r.rPeaks.length && r.rPeaks[k] < b; k++) {
      final l = BeatType.letters[r.labels[k]];
      final col = {'N': '#666', 'S': '#1565c0', 'V': '#c62828', 'Q': '#999'}[l];
      final px = x(r.rPeaks[k]);
      sb.write('<line x1="$px" x2="$px" y1="14" y2="$h" stroke="$col" stroke-dasharray="2,3"/>');
      sb.write('<text x="${px - 4}" y="12" fill="$col" font-size="12">$l</text>');
      if (k > 0) {
        final rr = ((r.rPeaks[k] - r.rPeaks[k - 1]) * 1000 / fs).round();
        sb.write('<text x="${(px + x(r.rPeaks[k - 1])) / 2 - 12}" y="${h - 4}" fill="#555" font-size="11">$rr</text>');
      }
    }
    sb.write('</svg>');
  }
  sb.write('</body></html>');
  final out = File('$path/strips.html')..writeAsStringSync(sb.toString());
  print(out.path);
}

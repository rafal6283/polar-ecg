// Analiza zapisu na PC: dart run tool/analyze.dart <katalog_zapisu> [...]
// Porównuje wykryte uderzenia z odstępami RR raportowanymi przez samą opaskę (rr.csv).
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';

import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

Future<void> main(List<String> args) async {
  for (final path in args) {
    final sw = Stopwatch()..start();
    final r = await analyzeRecordingDir(path);
    print('=== $path  (analiza ${sw.elapsedMilliseconds} ms)');
    final fs = r.sampleRate;
    r.stats.values.forEach((k, v) => print('  $k: ${v is double ? v.toStringAsFixed(1) : v}'));
    print('  segmenty: ${r.timeline.segments.length}, artefakty: ${r.noisy.map((e) => '${(e[0] / fs).toStringAsFixed(0)}-${(e[1] / fs).toStringAsFixed(0)}s').toList()}');
    print('  zdarzenia:');
    for (final e in r.events) {
      print('    ${(e.startSample / fs).toStringAsFixed(1)}s ${e.type.label} ${e.detail}');
    }
    final labels = String.fromCharCodes(r.labels.map((l) => BeatType.letters[l].codeUnitAt(0)));
    print('  etykiety: $labels');

    // Porównanie z RR z opaski.
    final polar = <double>[];
    for (final line in File('$path/rr.csv').readAsLinesSync().skip(1)) {
      final p = line.split(',');
      if (p.length == 3 && p[2].isNotEmpty) polar.add(double.parse(p[2]));
    }
    final ours = [for (var i = 1; i < r.rPeaks.length; i++) (r.rPeaks[i] - r.rPeaks[i - 1]) * 1000 / fs];
    double mean(List<double> v) => v.isEmpty ? double.nan : v.reduce((a, b) => a + b) / v.length;
    print('  RR opaska: n=${polar.length}, średnio ${mean(polar).toStringAsFixed(0)} ms');
    print('  RR nasze:  n=${ours.length}, średnio ${mean(ours).toStringAsFixed(0)} ms');
    // Dopasowanie sekwencji: szukamy przesunięcia z najmniejszym błędem.
    var bestErr = double.infinity, bestShift = 0;
    for (var s = -10; s <= 10; s++) {
      var err = 0.0, c = 0;
      for (var i = 0; i < ours.length; i++) {
        final j = i + s;
        if (j < 0 || j >= polar.length) continue;
        err += (ours[i] - polar[j]).abs();
        c++;
      }
      if (c > ours.length / 2 && err / c < bestErr) {
        bestErr = err / c;
        bestShift = s;
      }
    }
    var maxErr = 0.0;
    for (var i = 0; i < ours.length; i++) {
      final j = i + bestShift;
      if (j >= 0 && j < polar.length) maxErr = max(maxErr, (ours[i] - polar[j]).abs());
    }
    print('  zgodność RR z opaską: średni błąd ${bestErr.toStringAsFixed(1)} ms, maks. ${maxErr.toStringAsFixed(0)} ms');
  }
}

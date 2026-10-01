// Porównanie analizy zapisów H10 przy dwóch zestawach ustawień – kontrola zmian strojonych na bazach
// PhysioNet, zanim trafią do aplikacji (fałszywe pobudzenia/AF na artefaktach ruchowych opaski).
// dart run tool/h10_compare.dart <katalog_zapisu> [katalog ...] [--a klucz=wartość ...] [--b klucz=wartość ...]
// Domyślnie A = ustawienia sprzed v1.3.0 (bez odzysku uderzeń, stare progi AF, bez nowych zdarzeń),
// B = bieżące ustawienia domyślne. Wypisuje różnice etykiet i zdarzeń z czasem – do obejrzenia w aplikacji.
// ignore_for_file: avoid_print

import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

const legacy = {
  'rescueCorr': 0.0,
  'afPCorr': 0.4,
  'afCosen': -1.4,
  'afGapSec': 0.0,
  'svtOnset': 0.0,
  'stDevUv': 0.0,
  'avbCorr': 2.0,
};

Future<void> main(List<String> args) async {
  final dirs = <String>[];
  final a = <String, double>{...legacy}, b = <String, double>{};
  var target = dirs as Object;
  for (final x in args) {
    if (x == '--a') {
      target = a..clear();
    } else if (x == '--b') {
      target = b;
    } else if (x.contains('=') && target is Map<String, double>) {
      target[x.split('=')[0]] = double.parse(x.split('=')[1]);
    } else {
      dirs.add(x);
    }
  }
  for (final path in dirs) {
    final ra = await analyzeRecordingDir(path, settings: const AnalysisSettings().copyWith(a));
    final rb = await analyzeRecordingDir(path, settings: const AnalysisSettings().copyWith(b));
    final fs = ra.sampleRate;
    String t(int s) => '${(s / fs / 60).floor()}:${((s / fs) % 60).floor().toString().padLeft(2, '0')}';
    print('=== $path');
    for (final k in ['beats', 'n', 's', 'v', 'q', 'af_burden_pct', 'hr_mean', 'sdnn_ms']) {
      print('  $k: ${ra.stats[k]} -> ${rb.stats[k]}');
    }
    // Różnice etykiet (te same R).
    final idxB = {for (var i = 0; i < rb.rPeaks.length; i++) rb.rPeaks[i]: i};
    final changes = <String, List<int>>{};
    for (var i = 0; i < ra.rPeaks.length; i++) {
      final j = idxB[ra.rPeaks[i]];
      if (j == null || ra.labels[i] == rb.labels[j]) continue;
      changes.putIfAbsent('${BeatType.letters[ra.labels[i]]}->${BeatType.letters[rb.labels[j]]}', () => []).add(ra.rPeaks[i]);
    }
    changes.forEach((k, v) => print('  $k: ${v.length}  np. ${v.take(8).map(t).join(', ')}'));
    String ev(EcgEvent e) => '${t(e.startSample)} ${e.type.label} ${e.detail}';
    final ea = ra.events.map(ev).toSet(), eb = rb.events.map(ev).toSet();
    for (final e in eb.difference(ea)) {
      print('  + $e');
    }
    for (final e in ea.difference(eb)) {
      print('  - $e');
    }
  }
}

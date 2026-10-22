// Przegląd zapisu H10: pobudzenia V/S i zdarzenia w podziale na godziny – do szybkiej oceny zapisu.
// dart run tool/rec_summary.dart <katalog_zapisu> [klucz=wartość ...]
// ignore_for_file: avoid_print

import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

Future<void> main(List<String> args) async {
  final overrides = <String, double>{
    for (final a in args.skip(1).where((a) => a.contains('='))) a.split('=')[0]: double.parse(a.split('=')[1]),
  };
  final r = await analyzeRecordingDir(args.first, settings: const AnalysisSettings().copyWith(overrides));
  String t(int s) {
    final d = r.timeline.timeOf(s);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  }

  final byHour = <int, List<int>>{};
  for (var i = 0; i < r.rPeaks.length; i++) {
    final h = r.timeline.timeOf(r.rPeaks[i]).hour;
    byHour.putIfAbsent(h, () => List<int>.filled(4, 0))[r.labels[i]]++;
  }
  print('godzina  N  S  V  Q');
  byHour.forEach((h, c) => print('$h: ${c.join('  ')}'));
  print('zdarzenia:');
  for (final e in r.events) {
    print('  ${t(e.startSample)}–${t(e.endSample)} ${e.type.label} ${e.detail}');
  }
  final v = [
    for (var i = 0; i < r.rPeaks.length; i++)
      if (r.labels[i] == BeatType.ventricular) t(r.rPeaks[i]),
  ];
  print('V (${v.length}), co 20.: ${[for (var k = 0; k < v.length; k += 20) v[k]].join(' ')}');
  final s = [
    for (var i = 0; i < r.rPeaks.length; i++)
      if (r.labels[i] == BeatType.supraventricular) t(r.rPeaks[i]),
  ];
  print('S (${s.length}), co 30.: ${[for (var k = 0; k < s.length; k += 30) s[k]].join(' ')}');
  print(
    'statystyki: ${{
      for (final k in ['hr_mean', 'hr_min', 'hr_max', 'sdnn_ms', 'rmssd_ms', 'analyzed_s', 'duration_s', 'qrs_ms', 'qtc_ms', 'pr_ms']) k: r.stats[k]?.toStringAsFixed(0),
    }}',
  );
}

// Zrzut cech i wyników klasyfikacji każdego pobudzenia z MIT-BIH do CSV (diagnoza błędów, np. przeoczonych S).
// dart run tool/beat_dump.dart <katalog_mitdb> <wyjście.csv> [rekordy...]   (bez rekordów: DS1 i DS2)
// Kolumny: zbiór, rekord, prawda AAMI, wynik, w AF, pN/pS/pV, cechy f0… (kolejność jak beatFeatureNames).
// ignore_for_file: avoid_print
import 'dart:io';
import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';
import 'mitbih_io.dart';

Future<void> main(List<String> a) async {
  final dir = a[0];
  final out = File(a[1]).openWrite();
  out.writeln('set,rec,truth,label,inaf,pN,pS,pV,${List.generate(beatFeatureNames.length, (i) => 'f$i').join(',')}');
  for (final (set, recs) in a.length > 2 ? [('X', a.sublist(2))] : [('DS1', ds1), ('DS2', ds2)]) {
    for (final rec in recs) {
      final m = loadMitRecord(dir, rec);
      final o = analyzeEcg(m.uv, m.timeline, settings: const AnalysisSettings(collectFeatures: true));
      final res = o.result;
      final hits = matchBeats(res.rPeaks, m.beats);
      for (var b = 0; b < m.beats.length; b++) {
        final k = hits[b];
        if (k < 0) continue;
        final f = o.features?[k];
        final p = [res.prob(k, 0), res.prob(k, 1), res.prob(k, 2)];
        out.writeln('$set,$rec,${m.beats[b].cls},${BeatType.letters[res.labels[k]]},${res.inAf[k]},'
            '${p.map((v) => v?.toStringAsFixed(3) ?? '').join(',')},'
            '${f == null ? List.filled(beatFeatureNames.length, '').join(',') : f.map((v) => v.toStringAsFixed(4)).join(',')}');
      }
      stderr.write('$rec ');
    }
  }
  await out.close();
}

// Ocena wykrywania epizodów rytmu na bazach PhysioNet (adnotacje rytmu '(AFL', '(SVTA', '(BII', ...).
// dart run tool/rhythm_eval.dart <katalog> <rytm[,rytm]> <zdarzenie[,zdarzenie]> [rekordy...] [-q] [-lead=X]
//     [klucz=wartość ...]
// np. dart run tool/rhythm_eval.dart mitdb AFL afl     |  ... ltafdb SVTA svt,svRun
//
// Epizod odniesienia wykryty, gdy nakłada się na zdarzenie wskazanego typu; zdarzenie trafne, gdy nakłada się
// na epizod odniesienia. Podaje też liczbę zdarzeń fałszywych na dobę zapisu.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

import 'mitbih_io.dart';

void main(List<String> args) {
  final dir = args[0];
  final rhythms = args[1].split(',');
  final types = {for (final t in args[2].split(',')) EventType.values.byName(t)};
  final quiet = args.contains('-q');
  final lead = [for (final a in args) if (a.startsWith('-lead=')) a.substring(6)].firstOrNull;
  final overrides = <String, double>{
    for (final a in args.skip(3).where((a) => a.contains('=') && !a.startsWith('-')))
      a.split('=')[0]: double.parse(a.split('=')[1]),
  };
  final settings = const AnalysisSettings().copyWith(overrides);
  var records = args.skip(3).where((a) => !a.contains('=') && !a.startsWith('-')).toList();
  if (records.isEmpty) {
    records = Directory(dir)
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.hea') && !n.startsWith('x_'))
        .map((n) => n.substring(0, n.length - 4))
        .where((r) => File('$dir/$r.dat').existsSync() && !paced.contains(r))
        .toList()
      ..sort();
  }
  var refN = 0, refHit = 0, detN = 0, detTrue = 0;
  var hours = 0.0;
  for (final rec in records) {
    final m = loadMitRecord(dir, rec, lead: lead);
    final res = analyzeEcg(m.uv, m.timeline, settings: settings).result;
    hours += m.uv.length / targetFs / 3600;
    final ref = [for (final r in rhythms) ...?m.rhythms[r]];
    final det = [for (final e in res.events) if (types.contains(e.type)) e];
    var rh = 0, dt = 0;
    for (final a in ref) {
      if (det.any((d) => d.startSample < a[1] && a[0] < d.endSample + targetFs)) rh++;
    }
    final fp = <EcgEvent>[];
    for (final d in det) {
      if (ref.any((a) => d.startSample < a[1] && a[0] < d.endSample + targetFs)) {
        dt++;
      } else {
        fp.add(d);
      }
    }
    refN += ref.length;
    refHit += rh;
    detN += det.length;
    detTrue += dt;
    if (!quiet && (ref.isNotEmpty || det.isNotEmpty)) {
      print('$rec: odniesienie ${ref.length} (wykryte $rh), zdarzenia ${det.length} (trafne $dt)'
          '${fp.isEmpty ? '' : '  fałszywe np. ${fp.take(3).map((e) => '${(e.startSample / targetFs).round()}s ${e.detail}').join('; ')}'}');
    }
  }
  String pc(num a, num b) => b == 0 ? '–' : '${(100 * a / b).toStringAsFixed(1)}%';
  print('RAZEM ${hours.toStringAsFixed(0)} h: epizody Se ${pc(refHit, refN)} ($refHit/$refN), '
      'zdarzenia +P ${pc(detTrue, detN)} ($detTrue/$detN), fałszywe ${((detN - detTrue) / hours * 24).toStringAsFixed(1)}/dobę');
}

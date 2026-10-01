// Ocena wykrywania epizodów zmian ST na European ST-T Database (edb, 250 Hz, 2 odprowadzenia, 2 h).
// dart run tool/st_eval.dart <katalog_edb> [rekordy...] [-q] [klucz=wartość ...]
//
// Każdy kanał osobno (epizody adnotowane per kanał: '(ST0-' … 'ST0-)'). Epizod odniesienia wykryty, gdy
// nakłada się na wykryty epizod tego samego kierunku; wykryty jest trafny, gdy nakłada się na odniesienie.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

import 'mitbih_io.dart';

void main(List<String> args) {
  final dir = args.first;
  final quiet = args.contains('-q');
  final overrides = <String, double>{
    for (final a in args.skip(1).where((a) => a.contains('='))) a.split('=')[0]: double.parse(a.split('=')[1]),
  };
  final settings = const AnalysisSettings().copyWith(overrides);
  var records = args.skip(1).where((a) => !a.contains('=') && !a.startsWith('-')).toList();
  if (records.isEmpty) {
    records = Directory(dir)
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.hea'))
        .map((n) => n.substring(0, n.length - 4))
        .toList()
      ..sort();
  }
  var refN = 0, refHit = 0, detN = 0, detTrue = 0;
  var refSec = 0.0, overlapSec = 0.0, detSec = 0.0;
  for (final rec in records) {
    for (final ch in [0, 1]) {
      final m = loadMitRecord(dir, rec, channel: ch);
      final res = analyzeEcg(m.uv, m.timeline, settings: settings).result;
      final det = [
        for (final e in res.events)
          if (e.type == EventType.stDepression || e.type == EventType.stElevation)
            (start: e.startSample, end: e.endSample, neg: e.type == EventType.stDepression)
      ];
      final ref = [
        for (final e in m.stEpisodes) (start: e.start, end: e.end, neg: e.desc.contains('-'))
      ];
      bool ov(({int start, int end, bool neg}) a, ({int start, int end, bool neg}) b) =>
          a.neg == b.neg && a.start < b.end && b.start < a.end;
      var rh = 0, dt = 0;
      for (final a in ref) {
        if (det.any((d) => ov(a, d))) rh++;
        refSec += (a.end - a.start) / targetFs;
        for (final d in det) {
          if (ov(a, d)) overlapSec += (min(a.end, d.end) - max(a.start, d.start)) / targetFs;
        }
      }
      for (final d in det) {
        if (ref.any((a) => ov(a, d))) dt++;
        detSec += (d.end - d.start) / targetFs;
      }
      refN += ref.length;
      refHit += rh;
      detN += det.length;
      detTrue += dt;
      if (!quiet) print('$rec/$ch: odniesienie ${ref.length} (wykryte $rh), wykryte ${det.length} (trafne $dt)');
    }
  }
  String pc(num a, num b) => b == 0 ? '–' : '${(100 * a / b).toStringAsFixed(1)}%';
  print('RAZEM epizody: Se ${pc(refHit, refN)} +P ${pc(detTrue, detN)} (odniesienie $refN, wykryte $detN); '
      'czas: Se ${pc(overlapSec, refSec)} +P ${pc(overlapSec, detSec)}');
}

int min(int a, int b) => a < b ? a : b;
int max(int a, int b) => a > b ? a : b;

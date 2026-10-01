// Ocena wykrywania migotania przedsionków na długich zapisach:
// MIT-BIH AF Database (afdb, 250 Hz, 10 h) i Long-Term AF Database (ltafdb, 128 Hz, ~24 h).
// dart run tool/af_eval.dart <katalog> [rekordy...] [-q] [-lead=ECG2] [klucz=wartość ...]
//
// Miary: czas (sekundy rytmu w AF wg odniesienia vs wykryte), uderzenia oraz epizody
// (epizod wykryty, gdy ≥ 50% jego czasu oznaczono jako AF). Trzepotanie (AFL) jest liczone osobno
// i nie wchodzi do swoistości (często wygląda jak AF w jednym odprowadzeniu).
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:polar_ecg/analysis/analyzer.dart';

import 'mitbih_io.dart';

Future<void> main(List<String> args) async {
  final dir = args.first;
  final quiet = args.contains('-q');
  final lead = [for (final a in args) if (a.startsWith('-lead=')) a.substring(6)].firstOrNull;
  final overrides = <String, double>{
    for (final a in args.skip(1).where((a) => a.contains('=') && !a.startsWith('-'))) a.split('=')[0]: double.parse(a.split('=')[1]),
  };
  final settings = const AnalysisSettings().copyWith(overrides);
  var records = args.skip(1).where((a) => !a.contains('=') && !a.startsWith('-')).toList();
  if (records.isEmpty) {
    records = Directory(dir)
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.hea'))
        .map((n) => n.substring(0, n.length - 4))
        .where((r) => File('$dir/$r.dat').existsSync())
        .toList()
      ..sort();
  }
  final tot = AfCounts();
  if (!quiet) print('rekord   godz.  AF[h]   Se(czas) +P(czas) Sp(czas)  Se(epiz) +P(epiz)  AFL[h] AFL->AF');
  for (final rec in records) {
    final m = loadMitRecord(dir, rec, lead: lead);
    final c = evalAf(m, settings);
    tot.add(c);
    if (!quiet) print('${rec.padRight(7)} ${c.row()}');
  }
  print('RAZEM   ${tot.row()}');
  print('fałszywe epizody AF: ${tot.fpEpisodes} (${(tot.fpEpisodes / (tot.totalSec / 3600 / 24)).toStringAsFixed(2)} na dobę zapisu)');
}

class AfCounts {
  double totalSec = 0, tp = 0, fn = 0, fp = 0, tn = 0, afl = 0, aflAsAf = 0;
  int epTrue = 0, epHit = 0, epDet = 0, epDetTrue = 0, fpEpisodes = 0;

  void add(AfCounts o) {
    totalSec += o.totalSec;
    tp += o.tp;
    fn += o.fn;
    fp += o.fp;
    tn += o.tn;
    afl += o.afl;
    aflAsAf += o.aflAsAf;
    epTrue += o.epTrue;
    epHit += o.epHit;
    epDet += o.epDet;
    epDetTrue += o.epDetTrue;
    fpEpisodes += o.fpEpisodes;
  }

  static String pct(double a, double b) => b <= 0 ? '   –   ' : '${(100 * a / b).toStringAsFixed(1).padLeft(5)}% ';

  String row() => '${(totalSec / 3600).toStringAsFixed(1).padLeft(5)} ${((tp + fn) / 3600).toStringAsFixed(1).padLeft(6)}  '
      '${pct(tp, tp + fn)}  ${pct(tp, tp + fp)}  ${pct(tn, tn + fp)}   ${pct(epHit.toDouble(), epTrue.toDouble())}  '
      '${pct(epDetTrue.toDouble(), epDet.toDouble())}  ${(afl / 3600).toStringAsFixed(1).padLeft(5)}  ${pct(aflAsAf, afl)}';
}

AfCounts evalAf(MitRecord m, AnalysisSettings settings) {
  const fs = targetFs;
  final res = analyzeEcg(m.uv, m.timeline, settings: settings).result;
  final n = m.uv.length;
  final secs = n ~/ fs;
  // Odniesienie i wynik w rozdzielczości 1 s.
  final ref = List<int>.filled(secs, 0); // 0 inny, 1 AF, 2 AFL
  for (final r in m.rhythms['AFIB'] ?? const <List<int>>[]) {
    for (var s = r[0] ~/ fs; s < r[1] ~/ fs && s < secs; s++) {
      ref[s] = 1;
    }
  }
  for (final r in m.rhythms['AFL'] ?? const <List<int>>[]) {
    for (var s = r[0] ~/ fs; s < r[1] ~/ fs && s < secs; s++) {
      ref[s] = 2;
    }
  }
  final det = List<bool>.filled(secs, false);
  final known = List<bool>.filled(secs, false); // sekundy z wykrytymi pobudzeniami
  for (var k = 0; k + 1 < res.rPeaks.length; k++) {
    final a = res.rPeaks[k] ~/ fs, b = res.rPeaks[k + 1] ~/ fs;
    if (b - a > 3) continue; // przerwa / brak sygnału
    for (var s = a; s <= b && s < secs; s++) {
      known[s] = true;
      if (res.inAf[k] == 1 && res.inAf[k + 1] == 1) det[s] = true;
    }
  }
  final c = AfCounts()..totalSec = secs.toDouble();
  for (var s = 0; s < secs; s++) {
    if (ref[s] == 2) {
      c.afl++;
      if (det[s]) c.aflAsAf++;
      continue;
    }
    if (!known[s] && ref[s] == 0) continue;
    if (ref[s] == 1) {
      det[s] ? c.tp++ : c.fn++;
    } else {
      det[s] ? c.fp++ : c.tn++;
    }
  }
  // Epizody.
  List<List<int>> runs(bool Function(int) f) {
    final out = <List<int>>[];
    int? st;
    for (var s = 0; s <= secs; s++) {
      final v = s < secs && f(s);
      if (v && st == null) st = s;
      if (!v && st != null) {
        out.add([st, s]);
        st = null;
      }
    }
    return out;
  }

  for (final e in runs((s) => ref[s] == 1)) {
    c.epTrue++;
    var hit = 0;
    for (var s = e[0]; s < e[1]; s++) {
      if (det[s]) hit++;
    }
    if (hit >= 0.5 * (e[1] - e[0])) c.epHit++;
  }
  for (final e in runs((s) => det[s])) {
    c.epDet++;
    var hit = 0;
    for (var s = e[0]; s < e[1]; s++) {
      if (ref[s] != 0) hit++;
    }
    if (hit >= 0.5 * (e[1] - e[0])) {
      c.epDetTrue++;
    } else {
      c.fpEpisodes++;
    }
  }
  return c;
}

// Ocena algorytmów na bazie MIT-BIH Arrhythmia Database (PhysioNet) wg AAMI EC57.
// dart run tool/mitbih_eval.dart <katalog_mitdb> [DS1|DS2|rekordy...] [-q] [klucz=wartość ...]
//
// Sygnał (odprowadzenie 1, zwykle MLII, 360 Hz) jest przepróbkowany do 130 Hz,
// żeby warunki odpowiadały opasce Polar H10.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

import 'mitbih_io.dart';

var _settings = const AnalysisSettings();

Future<void> main(List<String> args) async {
  final dir = args.first;
  final quiet = args.contains('-q');
  final overrides = <String, double>{
    for (final a in args.skip(1).where((a) => a.contains('='))) a.split('=')[0]: double.parse(a.split('=')[1]),
  };
  _settings = const AnalysisSettings().copyWith(overrides);
  var records = args.skip(1).where((a) => !a.contains('=') && a != '-q').toList();
  if (records.length == 1 && records.first == 'DS1') records = ds1;
  if (records.length == 1 && records.first == 'DS2') records = ds2;
  if (records.isEmpty) {
    records = Directory(dir)
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.hea'))
        .map((n) => n.substring(0, n.length - 4))
        .where((r) => !paced.contains(r))
        .toList()
      ..sort();
  }

  final tot = Counts();
  if (!quiet) print('rekord  uderzeń  QRS Se   QRS +P   VEB Se   VEB +P   SVEB Se  SVEB +P  AF Se    AF Sp');
  for (final rec in records) {
    final c = evalRecord(loadMitRecord(dir, rec), _settings);
    tot.add(c);
    final q = c.confusion.values.fold<int>(0, (s, m) => s + (m['Q'] ?? 0));
    if (!quiet) print('${rec.padRight(7)} ${c.beats.toString().padLeft(7)}  ${c.row()}  Q=${(100 * q / c.beats).toStringAsFixed(1)}%');
  }
  if (!quiet) print('-' * 96);
  print('RAZEM   ${tot.beats.toString().padLeft(7)}  ${tot.row()}');
  if (quiet) return;
  print('\nMacierz pomyłek (wiersze: prawda AAMI, kolumny: wynik N/S/V/Q/brak):');
  for (final t in ['N', 'S', 'V', 'F', 'Q']) {
    final m = tot.confusion[t] ?? {};
    print('  $t: ${['N', 'S', 'V', 'Q', '-'].map((k) => '$k=${m[k] ?? 0}').join('  ')}');
  }
}

class Counts {
  int beats = 0, qrsTp = 0, qrsFn = 0, qrsFp = 0;
  int vTp = 0, vFn = 0, vFp = 0, sTp = 0, sFn = 0, sFp = 0;
  int afTp = 0, afFn = 0, afFp = 0, afTn = 0;
  final Map<String, Map<String, int>> confusion = {};

  void add(Counts o) {
    beats += o.beats;
    qrsTp += o.qrsTp;
    qrsFn += o.qrsFn;
    qrsFp += o.qrsFp;
    vTp += o.vTp;
    vFn += o.vFn;
    vFp += o.vFp;
    sTp += o.sTp;
    sFn += o.sFn;
    sFp += o.sFp;
    afTp += o.afTp;
    afFn += o.afFn;
    afFp += o.afFp;
    afTn += o.afTn;
    o.confusion.forEach((t, m) {
      final dst = confusion.putIfAbsent(t, () => {});
      m.forEach((k, v) => dst.update(k, (x) => x + v, ifAbsent: () => v));
    });
  }

  static String pct(int a, int b) => b == 0 ? '   –   ' : '${(100 * a / b).toStringAsFixed(1).padLeft(5)}% ';

  String row() => [
        pct(qrsTp, qrsTp + qrsFn),
        pct(qrsTp, qrsTp + qrsFp),
        pct(vTp, vTp + vFn),
        pct(vTp, vTp + vFp),
        pct(sTp, sTp + sFn),
        pct(sTp, sTp + sFp),
        pct(afTp, afTp + afFn),
        pct(afTn, afTn + afFp),
      ].join(' ');
}

Counts evalRecord(MitRecord m, AnalysisSettings settings) {
  final n = m.uv.length;
  final res = analyzeEcg(m.uv, m.timeline, settings: settings).result;
  final hits = matchBeats(res.rPeaks, m.beats);
  final c = Counts();
  final matched = <int>{};
  const edge = 5 * targetFs; // pomijamy pierwsze i ostatnie 5 s (rozbieg filtrów)
  for (var b = 0; b < m.beats.length; b++) {
    final rb = m.beats[b];
    if (rb.sample < edge || rb.sample > n - edge) continue;
    c.beats++;
    final hit = hits[b];
    final got = hit < 0 ? '-' : BeatType.letters[res.labels[hit]];
    c.confusion.putIfAbsent(rb.cls, () => {}).update(got, (v) => v + 1, ifAbsent: () => 1);
    if (hit < 0) {
      c.qrsFn++;
    } else {
      matched.add(hit);
      c.qrsTp++;
    }
    final isV = got == 'V', isS = got == 'S';
    // EC57: F wykryte jako V nie jest ani błędem, ani trafieniem dla VEB; Q pomijamy.
    if (rb.cls == 'V') {
      isV ? c.vTp++ : c.vFn++;
    } else if (rb.cls != 'F' && rb.cls != 'Q' && isV) {
      c.vFp++;
    }
    if (rb.cls == 'S') {
      isS ? c.sTp++ : c.sFn++;
    } else if (rb.cls != 'Q' && isS) {
      c.sFp++;
    }
  }
  for (var k = 0; k < res.rPeaks.length; k++) {
    final p = res.rPeaks[k];
    if (p < edge || p > n - edge) continue;
    if (!matched.contains(k)) c.qrsFp++;
    final truth = m.afRanges.any((r) => p >= r[0] && p < r[1]);
    final det = res.inAf[k] == 1;
    if (truth && det) c.afTp++;
    if (truth && !det) c.afFn++;
    if (!truth && det) c.afFp++;
    if (!truth && !det) c.afTn++;
  }
  return c;
}

// Uczenie klasyfikatora pobudzeń N/S/V na MIT-BIH DS1 (podział międzypacjentowy de Chazal).
// dart run tool/train_classifier.dart <katalog_mitdb> <plik_cache_cech.json> [svdb=<katalog_svdb>]
//
// 1. Cechy pobudzeń z DS1 (cache) i opcjonalnie z całej MIT-BIH Supraventricular Arrhythmia DB
//    (svdb, 128 Hz, inni pacjenci niż mitdb – DS2 pozostaje nietknięty do oceny).
// 2. 4-krotna walidacja krzyżowa PO PACJENTACH dla kilku konfiguracji sieci:
//    wybór konfiguracji, liczby epok i progów decyzyjnych na predykcjach out-of-fold.
// 3. Uczenie wybranej konfiguracji na całym DS1 -> lib/analysis/beat_model.g.dart.
// Ocena końcowa wyłącznie na DS2: tool/mitbih_eval.dart <katalog> DS2
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:polar_ecg/analysis/analyzer.dart';
import 'package:polar_ecg/analysis/mlp.dart';

import 'mitbih_io.dart';

const classes = {'N': 0, 'S': 1, 'V': 2};

class Rec {
  final String name;
  final List<List<double>> xs;
  final List<int> ys;
  Rec(this.name, this.xs, this.ys);
}

class Cfg {
  final List<int> hidden;
  final double l2, noise;
  const Cfg(this.hidden, this.l2, this.noise);
  @override
  String toString() => 'ukryte=$hidden l2=$l2 szum=$noise';
}

const configs = [
  Cfg([32, 16], 1e-4, 0),
  Cfg([16], 1e-3, 0.3),
  Cfg([32, 16], 1e-3, 0.3),
  Cfg([16], 3e-3, 0.5),
];
const maxEpochs = 40;

Future<void> main(List<String> args) async {
  final svdbDir = [for (final a in args.skip(2)) if (a.startsWith('svdb=')) a.substring(5)].firstOrNull;
  final ds1Recs = _loadOrExtract(args[0], ds1, args[1]);
  final svRecs = svdbDir == null ? <Rec>[] : _loadOrExtract(svdbDir, _recordNames(svdbDir), '${args[1]}.svdb.json');
  if (svRecs.isNotEmpty) {
    print('SVDB: ${svRecs.length} zapisów, ${_counts([for (final r in svRecs) ...r.ys])}');
  }
  final recs = [...ds1Recs, ...svRecs];
  final dim = recs.first.xs.first.length;
  final allX = [for (final r in recs) ...r.xs];
  final allY = [for (final r in recs) ...r.ys];
  print('uczące: ${allX.length} pobudzeń, ${_counts(allY)}');
  final (mean, std) = _standardize(allX, dim);
  final cw = _classWeights(allY);

  // Foldy: zapisy (osobno z każdej bazy) posortowane wg liczby S+V, rozdzielane naprzemiennie.
  final folds = List.generate(4, (_) => <Rec>[]);
  for (final db in [ds1Recs, svRecs]) {
    final order = [...db]..sort((a, b) => _ectopic(b).compareTo(_ectopic(a)));
    for (var i = 0; i < order.length; i++) {
      folds[i % 4].add(order[i]);
    }
  }
  final isDs1 = [for (final r in recs) for (var i = 0; i < r.xs.length; i++) ds1Recs.contains(r)];

  Cfg? bestCfg;
  var best = (score: -1.0, epoch: 0, tV: 0.5, tS: 0.5);
  for (final cfg in configs) {
    // probs[epoka][próbka] dla predykcji out-of-fold.
    final oof = List.generate(maxEpochs, (_) => List<Float64List?>.filled(allX.length, null));
    final oofY = List<int>.filled(allX.length, 0);
    var offset = 0;
    final idxOf = <String, int>{};
    for (final r in recs) {
      idxOf[r.name] = offset;
      offset += r.xs.length;
    }
    for (var k = 0; k < 4; k++) {
      final tr = [for (var j = 0; j < 4; j++) if (j != k) ...folds[j]];
      final xs = [for (final r in tr) ...r.xs];
      final ys = [for (final r in tr) ...r.ys];
      final net = Mlp.random([dim, ...cfg.hidden, 3], mean, std, seed: 7 + k);
      final trainer = MlpTrainer(net, lr: 1e-3, l2: cfg.l2, inputNoise: cfg.noise);
      final rnd = Random(k);
      for (var e = 0; e < maxEpochs; e++) {
        trainer.epoch(xs, ys, cw, rnd);
        for (final r in folds[k]) {
          final o = idxOf[r.name]!;
          for (var i = 0; i < r.xs.length; i++) {
            oof[e][o + i] = net.predict(r.xs[i]);
            oofY[o + i] = r.ys[i];
          }
        }
      }
    }
    var cfgBest = (score: -1.0, epoch: 0, tV: 0.5, tS: 0.5);
    for (var e = 0; e < maxEpochs; e++) {
      for (final tV in [0.3, 0.4, 0.5, 0.6, 0.7, 0.8]) {
        for (final tS in [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]) {
          final s = _score(oof[e], oofY, tV, tS);
          if (s.score > cfgBest.score) cfgBest = (score: s.score, epoch: e + 1, tV: tV, tS: tS);
        }
      }
    }
    final bestOof = oof[cfgBest.epoch - 1];
    print('$cfg: najlepiej epoka ${cfgBest.epoch}, tV=${cfgBest.tV}, tS=${cfgBest.tS} -> '
        '${_score(bestOof, oofY, cfgBest.tV, cfgBest.tS).desc}');
    if (svRecs.isNotEmpty) {
      List<Float64List?> only(bool ds) => [for (var i = 0; i < bestOof.length; i++) isDs1[i] == ds ? bestOof[i] : null];
      print('    DS1:  ${_score(only(true), oofY, cfgBest.tV, cfgBest.tS).desc}');
      print('    SVDB: ${_score(only(false), oofY, cfgBest.tV, cfgBest.tS).desc}');
    }
    if (cfgBest.score > best.score) {
      best = cfgBest;
      bestCfg = cfg;
    }
  }
  print('WYBRANO: $bestCfg, epok ${best.epoch}, tV=${best.tV}, tS=${best.tS}');

  // Uczenie na całym DS1.
  final net = Mlp.random([dim, ...bestCfg!.hidden, 3], mean, std, seed: 7);
  final trainer = MlpTrainer(net, lr: 1e-3, l2: bestCfg.l2, inputNoise: bestCfg.noise);
  final rnd = Random(99);
  for (var e = 0; e < best.epoch; e++) {
    trainer.epoch(allX, allY, cw, rnd);
  }
  final finalNet = Mlp(net.sizes, net.mean, net.std, net.weights, net.biases, meta: {
    'tV': best.tV,
    'tS': best.tS,
    'epochs': best.epoch.toDouble(),
    'trainBeats': allX.length.toDouble(),
  });
  final json = jsonEncode(finalNet.toJson());
  File('lib/analysis/beat_model.g.dart').writeAsStringSync(
    '// Wygenerowane przez tool/train_classifier.dart – nie edytować ręcznie.\n'
    '// MIT-BIH DS1${svRecs.isEmpty ? '' : ' + SVDB'} (${allX.length} pobudzeń), konfiguracja: $bestCfg, '
    'epok: ${best.epoch}.\n'
    '// ignore_for_file: lines_longer_than_80_chars\n\n'
    "const String beatModelJson = r'''$json''';\n",
  );
  print('zapisano lib/analysis/beat_model.g.dart');
}

int _ectopic(Rec r) => r.ys.where((y) => y != 0).length;

List<String> _recordNames(String dir) => Directory(dir)
    .listSync()
    .map((f) => f.uri.pathSegments.last)
    .where((n) => n.endsWith('.hea'))
    .map((n) => n.substring(0, n.length - 4))
    .toList()
  ..sort();

List<Rec> _loadOrExtract(String dir, List<String> names, String cachePath) {
  final cache = File(cachePath);
  if (cache.existsSync()) {
    final j = jsonDecode(cache.readAsStringSync()) as List;
    return [
      for (final r in j)
        Rec(r['name'] as String, [for (final x in r['xs'] as List) (x as List).cast<num>().map((v) => v.toDouble()).toList()],
            (r['ys'] as List).cast<int>())
    ];
  }
  final settings = const AnalysisSettings().copyWith({'useModel': 0, 'collectFeatures': 1});
  final recs = <Rec>[];
  for (final name in names) {
    final m = loadMitRecord(dir, name);
    final out = analyzeEcg(m.uv, m.timeline, settings: settings);
    final hits = matchBeats(out.result.rPeaks, m.beats);
    final xs = <List<double>>[], ys = <int>[];
    for (var b = 0; b < m.beats.length; b++) {
      final y = classes[m.beats[b].cls];
      final h = hits[b];
      if (y == null || h < 0 || out.features![h] == null) continue;
      xs.add(out.features![h]!.toList());
      ys.add(y);
    }
    recs.add(Rec(name, xs, ys));
    print('$name: ${xs.length} pobudzeń, ${_counts(ys)}');
  }
  cache.writeAsStringSync(jsonEncode([
    for (final r in recs) {'name': r.name, 'xs': r.xs, 'ys': r.ys}
  ]));
  return recs;
}

String _counts(List<int> ys) => 'N=${ys.where((y) => y == 0).length} S=${ys.where((y) => y == 1).length} '
    'V=${ys.where((y) => y == 2).length}';

(Float64List, Float64List) _standardize(List<List<double>> xs, int dim) {
  final mean = Float64List(dim), std = Float64List(dim);
  for (final x in xs) {
    for (var i = 0; i < dim; i++) {
      mean[i] += x[i];
    }
  }
  for (var i = 0; i < dim; i++) {
    mean[i] /= xs.length;
  }
  for (final x in xs) {
    for (var i = 0; i < dim; i++) {
      std[i] += (x[i] - mean[i]) * (x[i] - mean[i]);
    }
  }
  for (var i = 0; i < dim; i++) {
    std[i] = max(1e-6, sqrt(std[i] / xs.length));
  }
  return (mean, std);
}

List<double> _classWeights(List<int> ys) {
  final cnt = List<int>.filled(3, 0);
  for (final y in ys) {
    cnt[y]++;
  }
  return [for (final c in cnt) min(25.0, sqrt(ys.length / (3 * max(1, c))) * 1.5)];
}

/// Wynik = F1(V) + F1(S).
({double score, String desc}) _score(List<Float64List?> probs, List<int> ys, double tV, double tS) {
  var vTp = 0, vFp = 0, vFn = 0, sTp = 0, sFp = 0, sFn = 0;
  for (var i = 0; i < probs.length; i++) {
    final p = probs[i];
    if (p == null) continue;
    final pred = p[2] >= tV ? 2 : (p[1] >= tS ? 1 : 0);
    final y = ys[i];
    if (y == 2) pred == 2 ? vTp++ : vFn++;
    if (y != 2 && pred == 2) vFp++;
    if (y == 1) pred == 1 ? sTp++ : sFn++;
    if (y != 1 && pred == 1) sFp++;
  }
  double f1(int tp, int fp, int fn) => tp == 0 ? 0 : 2 * tp / (2 * tp + fp + fn);
  String pc(int a, int b) => b == 0 ? '–' : '${(100 * a / b).toStringAsFixed(1)}%';
  return (
    score: f1(vTp, vFp, vFn) + f1(sTp, sFp, sFn),
    desc: 'V Se ${pc(vTp, vTp + vFn)} +P ${pc(vTp, vTp + vFp)} | S Se ${pc(sTp, sTp + sFn)} +P ${pc(sTp, sTp + sFp)}',
  );
}

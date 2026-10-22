// Uczenie klasyfikatora pobudzeń N/S/V na MIT-BIH DS1 (podział międzypacjentowy de Chazal).
// dart run tool/train_classifier.dart <katalog_mitdb> <plik_cache_cech.json> [svdb=<katalog>] [incart=<katalog>]
//     [aug=1] [nKeep=0.35]
//
// 1. Cechy pobudzeń z DS1 (cache) i opcjonalnie z całych baz (inni pacjenci niż mitdb – DS2 pozostaje
//    nietknięty do oceny): MIT-BIH Supraventricular Arrhythmia DB (svdb, 128 Hz) i St. Petersburg INCART
//    (incartdb, 257 Hz, 12 odprowadzeń – bierzemy II i V5; 75 zapisów od 32 pacjentów, foldy po pacjentach).
//    aug=1: dodatkowa kopia każdego zapisu z zakłóceniami typowymi dla opaski (szum mięśniowy, pływanie linii,
//    zmiana amplitudy) – odporność cech na warunki H10. nKeep: odsetek pobudzeń N zachowanych z dodatkowych
//    baz i kopii (S i V zawsze wszystkie) – czas uczenia.
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
  final String group; // pacjent (foldy walidacji krzyżowej)
  final String db;
  final List<List<double>> xs;
  final List<int> ys;
  Rec(this.name, this.xs, this.ys, {String? group, this.db = 'mitdb'}) : group = group ?? name;
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
  String? opt(String k) => [for (final a in args.skip(2)) if (a.startsWith('$k=')) a.substring(k.length + 1)].firstOrNull;
  final aug = opt('aug') == '1';
  final nKeep = double.parse(opt('nKeep') ?? '1');
  final cache = args[1];
  final ds1Recs = _loadOrExtract(args[0], ds1, cache, db: 'mitdb');
  final extra = <Rec>[];
  if (opt('svdb') case final d?) extra.addAll(_loadOrExtract(d, _recordNames(d), '$cache.svdb.json', db: 'svdb'));
  if (opt('incart') case final d?) {
    extra.addAll(_loadOrExtract(d, _recordNames(d), '$cache.incart.json', db: 'incart', leads: ['II', 'V5']));
  }
  if (aug) {
    extra.addAll(_loadOrExtract(args[0], ds1, '$cache.aug.json', db: 'mitdb+aug', augment: true));
    if (opt('svdb') case final d?) {
      extra.addAll(_loadOrExtract(d, _recordNames(d), '$cache.svdb.aug.json', db: 'svdb+aug', augment: true));
    }
  }
  // Przerzedzenie N w dodatkowych danych (deterministyczne).
  final thinned = [
    for (final r in extra)
      if (nKeep >= 1)
        r
      else
        () {
          final xs = <List<double>>[], ys = <int>[];
          var acc = 0.0;
          for (var i = 0; i < r.xs.length; i++) {
            if (r.ys[i] == 0) {
              acc += nKeep;
              if (acc < 1) continue;
              acc -= 1;
            }
            xs.add(r.xs[i]);
            ys.add(r.ys[i]);
          }
          return Rec(r.name, xs, ys, group: r.group, db: r.db);
        }()
  ];
  for (final db in {for (final r in thinned) r.db}) {
    final rs = thinned.where((r) => r.db == db);
    print('$db: ${rs.length} zapisów, ${_counts([for (final r in rs) ...r.ys])}');
  }
  final recs = [...ds1Recs, ...thinned];
  final dim = recs.first.xs.first.length;
  final allX = [for (final r in recs) ...r.xs];
  final allY = [for (final r in recs) ...r.ys];
  print('uczące: ${allX.length} pobudzeń, ${_counts(allY)}');
  final (mean, std) = _standardize(allX, dim);
  final cw = _classWeights(allY);

  // Foldy po pacjentach: grupy (osobno z każdej bazy) posortowane wg liczby S+V, rozdzielane naprzemiennie.
  // Kopia z zakłóceniami trafia do tego samego foldu co oryginał (ta sama grupa).
  final foldOf = <String, int>{};
  for (final db in {for (final r in recs) r.db.split('+').first}) {
    final groups = <String, int>{};
    for (final r in recs.where((r) => r.db.split('+').first == db)) {
      groups.update('$db/${r.group}', (v) => v + _ectopic(r), ifAbsent: () => _ectopic(r));
    }
    final order = groups.keys.toList()..sort((a, b) => groups[b]!.compareTo(groups[a]!));
    for (var i = 0; i < order.length; i++) {
      foldOf[order[i]] = i % 4;
    }
  }
  final folds = List.generate(4, (_) => <Rec>[]);
  for (final r in recs) {
    folds[foldOf['${r.db.split('+').first}/${r.group}']!].add(r);
  }
  final dbOf = [for (final r in recs) for (var i = 0; i < r.xs.length; i++) r.db];

  Cfg? bestCfg;
  var best = (score: -1.0, epoch: 0, tV: 0.5, tS: 0.5);
  for (final cfg in configs) {
    // probs[epoka][próbka] dla predykcji out-of-fold.
    final oof = List.generate(maxEpochs, (_) => List<Float64List?>.filled(allX.length, null));
    final oofY = List<int>.filled(allX.length, 0);
    var offset = 0;
    final idxOf = <String, int>{};
    for (final r in recs) {
      idxOf['${r.db}/${r.name}'] = offset;
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
          final o = idxOf['${r.db}/${r.name}']!;
          for (var i = 0; i < r.xs.length; i++) {
            oof[e][o + i] = net.predict(r.xs[i]);
            oofY[o + i] = r.ys[i];
          }
        }
      }
    }
    final oofDs1 = [
      for (final ep in oof) [for (var i = 0; i < ep.length; i++) dbOf[i] == 'mitdb' ? ep[i] : null]
    ];
    var cfgBest = (score: -1.0, epoch: 0, tV: 0.5, tS: 0.5);
    for (var e = 0; e < maxEpochs; e++) {
      for (final tV in [0.3, 0.4, 0.5, 0.6, 0.7, 0.8]) {
        for (final tS in [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]) {
          // Wybór na predykcjach out-of-fold z DS1 (MIT-BIH) – pozostałe bazy tylko uczą; mieszanka baz
          // przesuwała progi (np. tV 0.3 przez liczne V w INCART) i zawyżała fałszywe V.
          final s = _score(oofDs1[e], oofY, tV, tS);
          if (s.score > cfgBest.score) cfgBest = (score: s.score, epoch: e + 1, tV: tV, tS: tS);
        }
      }
    }
    final bestOof = oof[cfgBest.epoch - 1];
    print('$cfg: najlepiej epoka ${cfgBest.epoch}, tV=${cfgBest.tV}, tS=${cfgBest.tS} -> '
        '${_score(oofDs1[cfgBest.epoch - 1], oofY, cfgBest.tV, cfgBest.tS).desc} (DS1)');
    for (final db in {for (final r in recs) r.db}) {
      final only = [for (var i = 0; i < bestOof.length; i++) dbOf[i] == db ? bestOof[i] : null];
      print('    ${db.padRight(10)} ${_score(only, oofY, cfgBest.tV, cfgBest.tS).desc}');
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
    '// MIT-BIH DS1 + ${{for (final r in thinned) r.db}.join(' + ')} (${allX.length} pobudzeń), konfiguracja: $bestCfg, '
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

List<Rec> _loadOrExtract(String dir, List<String> names, String cachePath,
    {required String db, List<String?> leads = const [null], bool augment = false}) {
  final cache = File(cachePath);
  if (cache.existsSync()) {
    final j = jsonDecode(cache.readAsStringSync()) as List;
    return [
      for (final r in j)
        Rec(r['name'] as String, [for (final x in r['xs'] as List) (x as List).cast<num>().map((v) => v.toDouble()).toList()],
            (r['ys'] as List).cast<int>(),
            group: r['group'] as String?, db: db)
    ];
  }
  final settings = const AnalysisSettings().copyWith({'useModel': 0, 'collectFeatures': 1});
  final recs = <Rec>[];
  for (final name in names) {
    final xs = <List<double>>[], ys = <int>[];
    for (final lead in leads) {
      final m = loadMitRecord(dir, name, lead: lead);
      if (augment) _augment(m.uv, name.hashCode);
      final out = analyzeEcg(m.uv, m.timeline, settings: settings);
      final hits = matchBeats(out.result.rPeaks, m.beats);
      for (var b = 0; b < m.beats.length; b++) {
        final y = classes[m.beats[b].cls];
        final h = hits[b];
        if (y == null || h < 0 || out.features![h] == null) continue;
        xs.add(out.features![h]!.toList());
        ys.add(y);
      }
    }
    final group = _patient(dir, name);
    recs.add(Rec(name, xs, ys, group: group, db: db));
    print('$db $name (pacjent $group): ${xs.length} pobudzeń, ${_counts(ys)}');
  }
  cache.writeAsStringSync(jsonEncode([
    for (final r in recs) {'name': r.name, 'group': r.group, 'xs': r.xs, 'ys': r.ys}
  ]));
  return recs;
}

/// Identyfikator pacjenta z komentarza nagłówka ('# patient 12' w incartdb), inaczej nazwa zapisu.
String _patient(String dir, String name) {
  for (final l in File('$dir/$name.hea').readAsLinesSync()) {
    final m = RegExp(r'^#\s*patient\s+(\d+)', caseSensitive: false).firstMatch(l);
    if (m != null) return 'p${m.group(1)}';
  }
  return name;
}

/// Zakłócenia typowe dla opaski piersiowej (w miejscu): zmiana amplitudy (pozycja ciała), pływanie linii
/// izoelektrycznej (oddech), szum mięśniowy (biały, ~25–40 µV) z krótkimi seriami silniejszego szumu
/// oraz pojedyncze skoki linii (ruch elektrody). Poziomy w zakresie, który zwykle przechodzi przez bramkę
/// szumu – uczymy odporności cech, a nie rozpoznawania artefaktów.
void _augment(Float32List x, int seed) {
  final rnd = Random(seed);
  final fs = targetFs;
  final scale = 0.6 + 0.8 * rnd.nextDouble();
  final noise = 25 + 15 * rnd.nextDouble();
  final bwAmp = 100 + 150 * rnd.nextDouble(), bwF = 0.15 + 0.2 * rnd.nextDouble();
  double g() => sqrt(-2 * log(max(1e-12, rnd.nextDouble()))) * cos(2 * pi * rnd.nextDouble());
  var burst = 0, step = 0.0, stepDecay = 0.0;
  for (var i = 0; i < x.length; i++) {
    if (burst == 0 && rnd.nextDouble() < 1 / (20 * fs)) burst = (0.5 + rnd.nextDouble()) * fs ~/ 1;
    if (rnd.nextDouble() < 1 / (60 * fs)) {
      step = (rnd.nextBool() ? 1 : -1) * (200 + 300 * rnd.nextDouble());
      stepDecay = 0;
    }
    final n = g() * (burst > 0 ? noise * 2.5 : noise);
    if (burst > 0) burst--;
    stepDecay += 1 / fs;
    x[i] = (x[i] * scale + bwAmp * sin(2 * pi * bwF * i / fs) + n + step * exp(-stepDecay / 0.4)).toDouble();
  }
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

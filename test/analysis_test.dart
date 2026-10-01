import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';
import 'package:polar_ecg/analysis/beat_clusters.dart';
import 'package:polar_ecg/analysis/confidence.dart';

import 'synthetic_ecg.dart';

/// Dopasowanie wykrytych R do prawdziwych (tolerancja 60 ms).
({int tp, int fn, int fp, Map<String, Map<String, int>> confusion}) score(SyntheticEcg s, AnalysisResult r) {
  final tol = (0.06 * SyntheticEcg.fs).round();
  final used = <int>{};
  final confusion = <String, Map<String, int>>{};
  var tp = 0, fn = 0;
  for (var b = 0; b < s.beatTimes.length; b++) {
    final truth = (s.beatTimes[b] * SyntheticEcg.fs).round();
    final k = r.beatIndexAtOrAfter(truth - tol);
    if (k < r.rPeaks.length && (r.rPeaks[k] - truth).abs() <= tol) {
      tp++;
      used.add(k);
      final got = BeatType.letters[r.labels[k]];
      confusion.putIfAbsent(s.beatTypes[b], () => {}).update(got, (v) => v + 1, ifAbsent: () => 1);
    } else {
      fn++;
    }
  }
  return (tp: tp, fn: fn, fp: r.rPeaks.length - used.length, confusion: confusion);
}

AnalysisResult run(SyntheticEcg s) {
  final x = s.render();
  return analyzeEcg(x, s.timeline(x.length)).result;
}

void main() {
  test('rytm zatokowy: detekcja QRS, brak fałszywych zdarzeń', () {
    final s = SyntheticEcg()..sinus(300);
    final r = run(s);
    final sc = score(s, r);
    // ignore: avoid_print
    print('sinus: $sc, events=${r.events.map((e) => e.type.name).toList()}');
    expect(sc.fn / s.beatTimes.length, lessThan(0.01));
    expect(sc.fp, lessThan(3));
    expect(r.events.where((e) => e.type == EventType.af), isEmpty);
    expect(r.count(BeatType.ventricular), lessThan(3));
    expect(r.stats['hr_mean']!, closeTo(70, 3));
  });

  test('pobudzenia komorowe', () {
    final s = SyntheticEcg(seed: 2)
      ..sinus(30)
      ..withPvcs(240);
    final r = run(s);
    final sc = score(s, r);
    // ignore: avoid_print
    print('pvc: $sc');
    final v = sc.confusion['V']!;
    final vTotal = v.values.reduce((a, b) => a + b);
    expect((v['V'] ?? 0) / vTotal, greaterThan(0.9), reason: 'czułość V');
    final nAsV = sc.confusion['N']?['V'] ?? 0;
    expect(nAsV, lessThan(5), reason: 'N błędnie jako V');
  });

  test('pobudzenia nadkomorowe', () {
    final s = SyntheticEcg(seed: 3)
      ..sinus(30)
      ..withPacs(240);
    final r = run(s);
    final sc = score(s, r);
    // ignore: avoid_print
    print('pac: $sc');
    final sv = sc.confusion['S']!;
    final total = sv.values.reduce((a, b) => a + b);
    expect((sv['S'] ?? 0) / total, greaterThan(0.85), reason: 'czułość S');
    expect(sc.confusion['N']?['S'] ?? 0, lessThan(5));
  });

  test('migotanie przedsionków', () {
    final s = SyntheticEcg(seed: 4)..sinus(120);
    final afStart = s.time;
    s.af(180);
    final afEnd = s.time;
    s.sinus(120);
    final r = run(s);
    final af = r.events.where((e) => e.type == EventType.af).toList();
    // ignore: avoid_print
    print('af: ${af.map((e) => '${e.startSample / 130}-${e.endSample / 130}').toList()} (prawda $afStart-$afEnd)');
    expect(af, isNotEmpty);
    final detected = af.fold<double>(0, (a, e) => a + (e.endSample - e.startSample) / 130);
    expect(detected, greaterThan(0.8 * (afEnd - afStart)));
    expect(detected, lessThan(1.2 * (afEnd - afStart)));
    expect(r.stats['af_burden_pct']!, closeTo(100 * 180 / 420, 10));
  });

  test('pauza i artefakty', () {
    final s = SyntheticEcg(seed: 5)
      ..sinus(60)
      ..pause(3.2)
      ..sinus(60)
      ..noise(12)
      ..sinus(60);
    final r = run(s);
    final pauses = r.events.where((e) => e.type == EventType.pause).toList();
    // ignore: avoid_print
    print('pause: ${pauses.map((e) => e.detail).toList()}, noisy=${r.noisy}, events=${r.events.map((e) => e.type.name).toList()}');
    expect(pauses.length, 1);
    expect((pauses.single.endSample - pauses.single.startSample) / 130, closeTo(3.2, 0.1));
    expect(r.noisy, isNotEmpty);
    expect(r.events.where((e) => e.type != EventType.pause), isEmpty);
  });

  test('grupy morfologii: V i N w osobnych grupach, poprawki grupowe', () {
    final s = SyntheticEcg(seed: 2)
      ..sinus(30)
      ..withPvcs(120);
    final x = s.render();
    final out = analyzeEcg(x, s.timeline(x.length));
    final a = out.result;
    final groups = clusterBeats(a, out.filtered);
    expect(groups, isNotEmpty);
    final v = groups.firstWhere((g) => g.dominantLabel == BeatType.ventricular);
    final n = groups.firstWhere((g) => g.dominantLabel == BeatType.normal);
    expect(v.labelCounts[BeatType.ventricular] / v.size, greaterThan(0.9));
    expect(n.labelCounts[BeatType.ventricular], lessThan(3));
    // „To nie są V” zmienia tylko pobudzenia V; „artefakt” – wszystkie w grupie.
    final notV = clusterCorrections(a, v, BeatType.normal);
    expect(notV.values.every((l) => l == BeatType.normal), isTrue);
    expect(notV.length, v.labelCounts[BeatType.ventricular]);
    expect(clusterCorrections(a, v, BeatType.ventricular).length, v.size - v.labelCounts[BeatType.ventricular]);
    // ignore: avoid_print
    print('grupy: ${groups.map((g) => '${BeatType.letters[g.dominantLabel]}${g.size}').join(' ')}');
  });

  test('wiarygodność analizy: czysty zapis wysoka, zaszumiony niższa', () {
    final clean = SyntheticEcg()..sinus(120);
    final xc = clean.render();
    final c = AnalysisConfidence.of(analyzeEcg(xc, clean.timeline(xc.length)).result);
    expect(c.level, ConfidenceLevel.high);
    final noisy = SyntheticEcg(seed: 4)
      ..sinus(40)
      ..noise(40)
      ..sinus(40);
    final xn = noisy.render();
    final cn = AnalysisConfidence.of(analyzeEcg(xn, noisy.timeline(xn.length)).result);
    expect(cn.level, isNot(ConfidenceLevel.high));
    expect(cn.reasons, isNotEmpty);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'analysis_result.dart';

/// Podsumowanie zapisu minuta po minucie – dla Rytmu Snu (fazy snu, gdy opaska była podłączona tylko
/// do Polar EKG) i Health Connect. Czysty Dart.
///
/// minutes.json: {"v": 1, "started_ms": ms, "minutes": [[t, hr, rmssd, act, s, v, af], …], "pauses": [[t, s], …]}
/// t – koniec minuty [ms od epoki]; hr – tętno; rmssd – HRV z kolejnych pobudzeń N [ms] (null przy < 20 parach);
/// act – sekundy z ruchem tułowia (akcelerometr, okna 2 s); s, v – pobudzenia dodatkowe; af – 1, gdy minuta w AF.
const minutesFile = 'minutes.json';

/// Próg ruchu w oknie 2 s: odchylenie standardowe modułu przyspieszenia [mG] (oddech daje kilka mG).
const _actThr = 30.0;

Map<String, Object?> minuteSummary(AnalysisResult a, Float32List? activity) {
  final tl = a.timeline;
  final fs = tl.sampleRate;
  final r = a.rPeaks;
  final lab = a.labels;
  final t0 = tl.started.millisecondsSinceEpoch;
  int minuteOf(int sample) => tl.offsetOf(sample).inMilliseconds ~/ 60000;
  final total = tl.totalSamples;
  final nMin = total <= 0 ? 0 : minuteOf(total - 1) + 1;

  final rrSum = List<double>.filled(nMin, 0);
  final rrN = List<int>.filled(nMin, 0);
  final dSq = List<double>.filled(nMin, 0);
  final dN = List<int>.filled(nMin, 0);
  final s = List<int>.filled(nMin, 0), v = List<int>.filled(nMin, 0), af = List<int>.filled(nMin, 0);
  final pauses = <List<num>>[];
  double? prevNN;
  for (var i = 1; i < r.length; i++) {
    final m = minuteOf(r[i]);
    if (m < 0 || m >= nMin) continue;
    if (lab[i] == BeatType.supraventricular) s[m]++;
    if (lab[i] == BeatType.ventricular) v[m]++;
    if (a.inAf[i] == 1) af[m] = 1;
    if (lab[i] == BeatType.unknown || lab[i - 1] == BeatType.unknown) {
      prevNN = null;
      continue;
    }
    final rr = (r[i] - r[i - 1]) * 1000 / fs;
    if (rr < 280 || rr > 3000) {
      prevNN = null;
      continue;
    }
    rrSum[m] += rr;
    rrN[m]++;
    if (rr >= 2000) pauses.add([t0 + tl.offsetOf(r[i]).inMilliseconds, double.parse((rr / 1000).toStringAsFixed(2))]);
    if (lab[i] == BeatType.normal && lab[i - 1] == BeatType.normal) {
      if (prevNN != null && (rr - prevNN).abs() <= 0.2 * prevNN) {
        dSq[m] += (rr - prevNN) * (rr - prevNN);
        dN[m]++;
      }
      prevNN = rr;
    } else {
      prevNN = null;
    }
  }

  // ruch: okna 2 s aktywności z akcelerometru opaski
  List<int>? act;
  if (activity != null && activity.isNotEmpty) {
    act = List<int>.filled(nMin, -1);
    final win = 2 * fs;
    for (var w = 0; w < activity.length; w++) {
      final x = activity[w];
      if (x < 0) continue;
      final m = minuteOf(min(total - 1, w * win));
      if (m < 0 || m >= nMin) continue;
      if (act[m] < 0) act[m] = 0;
      if (x > _actThr) act[m] += 2;
    }
  }

  final rows = <List<num?>>[];
  for (var m = 0; m < nMin; m++) {
    if (rrN[m] < 10) continue; // minuta nieczytelna albo bez sygnału
    rows.add([
      t0 + (m + 1) * 60000,
      double.parse((60000 / (rrSum[m] / rrN[m])).toStringAsFixed(1)),
      dN[m] >= 20 ? double.parse(sqrt(dSq[m] / dN[m]).toStringAsFixed(1)) : null,
      act == null || act[m] < 0 ? null : min(60, act[m]),
      s[m],
      v[m],
      af[m],
    ]);
  }
  return {'v': 1, 'started_ms': t0, 'minutes': rows, 'pauses': pauses};
}

Future<Map<String, Object?>?> loadMinuteSummary(String dir) async {
  final f = File('$dir/$minutesFile');
  if (!await f.exists()) return null;
  try {
    return (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
  } catch (_) {
    return null;
  }
}

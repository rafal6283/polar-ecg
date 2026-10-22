import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/hrv_session.dart';

void main() {
  final t0 = DateTime(2026, 1, 10, 7);

  test('RMSSD, tętno i odrzucanie artefaktów', () {
    // Naprzemiennie 980/1020 ms: RMSSD = 40 ms, HR = 60/min; jeden artefakt (pobudzenie z pauzą).
    final rr = [for (var i = 0; i < 120; i++) i.isEven ? 980.0 : 1020.0];
    rr[50] = 600;
    rr[51] = 1500;
    final m = computeHrv(rr, time: t0, seconds: 120)!;
    expect(m.rmssd, closeTo(40, 0.5));
    expect(m.hr, closeTo(60, 0.5));
    expect(m.correctedPct, closeTo(100 * 2 / 120, 0.01));
    expect(m.reliable, isTrue);
    expect(computeHrv(rr.sublist(0, 10), time: t0, seconds: 10), isNull);
  });

  test('ocena względem własnej normy i zapis historii', () async {
    final rnd = Random(1);
    HrvMeasurement mk(int day, double rmssd) => HrvMeasurement(
        time: t0.add(Duration(days: day)), seconds: 120, beats: 120, correctedPct: 0, hr: 60,
        rmssd: rmssd, sdnn: 50, pnn50: 20);
    final hist = [for (var d = 0; d < 10; d++) mk(d, 50 + rnd.nextDouble() * 4 - 2)];
    expect(hrvBaseline(hist, mk(10, 50)).status, HrvStatus.normal);
    expect(hrvBaseline(hist, mk(10, 35)).status, HrvStatus.low);
    expect(hrvBaseline(hist, mk(10, 70)).status, HrvStatus.high);
    expect(hrvBaseline(hist.sublist(0, 3), mk(10, 50)).status, HrvStatus.unknown);

    final dir = Directory.systemTemp.createTempSync('hrv');
    await HrvHistory.add(dir, hist[1]);
    await HrvHistory.add(dir, hist[0]);
    final back = await HrvHistory.load(dir);
    expect(back.map((h) => h.time), [hist[0].time, hist[1].time]);
    expect(back.first.rmssd, closeTo(hist[0].rmssd, 0.05));
    dir.deleteSync(recursive: true);
  });
}

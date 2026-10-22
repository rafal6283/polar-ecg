import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/analyzer.dart';
import 'package:polar_ecg/analysis/ecg_recording.dart';
import 'package:polar_ecg/analysis/hrv_session.dart';
import 'package:polar_ecg/report/pdf_report.dart';

import 'synthetic_ecg.dart';

void main() {
  test('raport zbiorczy z kilku zapisów (różne dni) i pomiarów HRV', () async {
    final items = <SummaryItem>[];
    for (var d = 0; d < 4; d++) {
      final s = SyntheticEcg(seed: 20 + d)
        ..sinus(120)
        ..withPvcs(60 + d * 30);
      final x = s.render();
      final tl = Timeline(DateTime(2026, 1, 10 + d, 7 + d), 130, [Segment(0, x.length, 0)]);
      items.add(SummaryItem(analyzeEcg(x, tl).result, const []));
    }
    final hrv = [
      for (var d = 0; d < 4; d++)
        HrvMeasurement(
            time: DateTime(2026, 1, 10 + d, 6, 50), seconds: 120, beats: 120, correctedPct: 1, hr: 58,
            rmssd: 45.0 + d, sdnn: 50, pnn50: 20),
    ];
    final fonts = (File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync(), File('assets/fonts/Roboto-Bold.ttf').readAsBytesSync());
    final pdf = await buildSummaryReport(items: items, hrv: hrv, fontData: fonts);
    expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');
    final out = Platform.environment['SCREENSHOTS'];
    if (out != null) File('$out/raport_zbiorczy.pdf').writeAsBytesSync(pdf);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/analyzer.dart';
import 'package:polar_ecg/analysis/ecg_recording.dart';
import 'package:polar_ecg/export/exporters.dart';
import 'package:polar_ecg/report/pdf_report.dart';

import 'synthetic_ecg.dart';

void main() {
  test('EDF+: poprawny nagłówek, liczba rekordów, sygnał i adnotacje', () async {
    final s = SyntheticEcg(seed: 4)
      ..sinus(30)
      ..withPvcs(60);
    final x = s.render();
    final tl = Timeline(DateTime(2026, 3, 5, 10, 20, 30), 130, [Segment(0, x.length, 0)]);
    final a = analyzeEcg(x, tl).result;
    final tmp = Directory.systemTemp.createTempSync('edf');
    final f = await exportEdf(out: File('${tmp.path}/t.edf'), rec: EcgRecording(tmp, tl, x), a: a, patientName: 'Jan K');
    final b = f.readAsBytesSync();
    String h(int from, int len) => ascii.decode(b.sublist(from, from + len)).trim();
    expect(h(0, 8), '0');
    expect(h(168, 8), '05.03.26');
    expect(h(176, 8), '10.20.30');
    expect(h(192, 44), 'EDF+C');
    final nRec = int.parse(h(236, 8));
    expect(nRec, (x.length / 130).ceil());
    expect(h(256, 16), 'ECG');
    final annSamples = int.parse(h(256 + 216 * 2 + 8, 8));
    final recBytes = 130 * 2 + annSamples * 2;
    expect(b.length, 768 + nRec * recBytes);
    // Pierwsza próbka EKG = surowy sygnał.
    final first = ByteData.sublistView(Uint8List.fromList(b)).getInt16(768, Endian.little);
    expect(first, x[0].round());
    // Adnotacje zawierają pobudzenia V.
    final all = latin1.decode(b.sublist(768));
    expect(all.contains('\x14V\x14'), isTrue);
    tmp.deleteSync(recursive: true);
  });

  test('raport PDF i eksport RR powstają bez błędów', () async {
    final s = SyntheticEcg(seed: 5)
      ..sinus(60)
      ..withPvcs(60);
    final x = s.render();
    final out = analyzeEcg(x, s.timeline(x.length));
    final pdf = await buildPdfReport(a: out.result, signal: out.filtered);
    expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');
    final tmp = Directory.systemTemp.createTempSync('rr');
    final rr = await exportRrCsv(out: File('${tmp.path}/rr.csv'), a: out.result);
    final lines = rr.readAsLinesSync();
    expect(lines.length, out.result.rPeaks.length); // nagłówek + (n-1) odstępów
    tmp.deleteSync(recursive: true);
  });

  test('raport PDF osadza dołączoną czcionkę Roboto (polskie znaki)', () async {
    final s = SyntheticEcg(seed: 5)..sinus(60);
    final x = s.render();
    final out = analyzeEcg(x, s.timeline(x.length));
    final pdf = await buildPdfReport(
      a: out.result,
      signal: out.filtered,
      fontData: (
        File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync(),
        File('assets/fonts/Roboto-Bold.ttf').readAsBytesSync(),
      ),
    );
    expect(latin1.decode(pdf).contains('Roboto'), isTrue);
  });
}

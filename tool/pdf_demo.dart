// Raport PDF z zapisu (lub syntetycznego przykładu): dart run tool/pdf_demo.dart <wyjście.pdf> [katalog_zapisu]
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:polar_ecg/analysis/analyzer.dart';
import 'package:polar_ecg/recording/markers.dart';
import 'package:polar_ecg/report/pdf_report.dart';

import '../test/synthetic_ecg.dart';

Future<void> main(List<String> args) async {
  final out = args.first;
  if (args.length > 1) {
    final a = (await loadAnalysis(args[1])) ?? await analyzeRecordingDir(args[1]);
    final sig = await loadFiltered(args[1]);
    final markers = await loadMarkers(args[1], a.timeline);
    File(out).writeAsBytesSync(await buildPdfReport(a: a, signal: sig, markers: markers, fontData: _fonts()));
  } else {
    final s = SyntheticEcg(seed: 3)
      ..sinus(120)
      ..withPvcs(120, every: 7)
      ..pause(2.8)
      ..sinus(60)
      ..af(150)
      ..sinus(90);
    final x = s.render();
    final res = analyzeEcg(x, s.timeline(x.length));
    final a = res.result;
    final markers = [SymptomMarker(a.timeline.timeOf(130 * 300), 130 * 300, 'Kołatanie serca', 'po schodach')];
    File(out).writeAsBytesSync(await buildPdfReport(
      fontData: _fonts(),
      a: a,
      signal: res.filtered,
      markers: markers,
      person: const ReportPerson(name: 'Jan Przykładowy', age: 52, sex: 'M'),
      deviceName: 'Polar H10 (dane syntetyczne)',
    ));
  }
  print('zapisano $out');
}

/// Czcionka dołączona do aplikacji (assets/fonts) – jak na telefonie.
(Uint8List, Uint8List) _fonts() => (
      File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync(),
      File('assets/fonts/Roboto-Bold.ttf').readAsBytesSync(),
    );

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';
import 'package:polar_ecg/analysis/ecg_recording.dart';
import 'package:polar_ecg/analysis/personal_profile.dart';
import 'package:polar_ecg/ble/polar_protocol.dart';
import 'package:polar_ecg/recording/binary_format.dart';

import 'synthetic_ecg.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('polar_ecg_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Zapisuje syntetyczny sygnał w formacie aplikacji (ramki po 73 próbki jak z H10) + ACC.
  Future<Directory> writeRecording(Float32List x, {double accMotionFrom = double.infinity}) async {
    final dir = Directory('${tmp.path}/recordings/20260101_080000')..createSync(recursive: true);
    File('${dir.path}/meta.json').writeAsStringSync(jsonEncode({
      'sample_rate_hz': 130,
      'started': DateTime(2026, 1, 1, 8).toIso8601String(),
    }));
    final ecg = BinaryStreamWriter.create(File('${dir.path}/ecg.bin'), 'PECG', fs: 130, channels: 1);
    final acc = BinaryStreamWriter.create(File('${dir.path}/acc.bin'), 'PACC', fs: 25, channels: 3);
    const step = 1000000000 ~/ 130;
    for (var i = 0; i < x.length; i += 73) {
      final end = i + 73 < x.length ? i + 73 : x.length;
      ecg.addFrame((end - 1) * step, [for (var k = i; k < end; k++) x[k].round()]);
    }
    // ACC 25 Hz: spoczynek (1 g na osi z), od accMotionFrom [s] – ruch 0.3 g.
    final accN = (x.length / 130 * 25).floor();
    for (var i = 0; i < accN; i += 36) {
      final end = i + 36 < accN ? i + 36 : accN;
      final xyz = <int>[];
      for (var k = i; k < end; k++) {
        final t = k / 25;
        final m = t >= accMotionFrom ? (300 * (k.isEven ? 1 : -1)) : 0;
        xyz.addAll([0, 0, 1000 + m]);
      }
      acc.addFrame((end - 1) * 40000000, xyz);
    }
    await ecg.close();
    await acc.close();
    return dir;
  }

  test('format binarny: zapis i odczyt EKG + aktywność z akcelerometru', () async {
    final s = SyntheticEcg()..sinus(60);
    final x = s.render();
    final dir = await writeRecording(x, accMotionFrom: 30);
    final rec = await EcgRecording.load(dir);
    expect(rec.uv.length, x.length);
    expect(rec.timeline.segments.length, 1);
    expect(rec.uv[500], closeTo(x[500], 1));
    final act = rec.activity!;
    expect(act[5], lessThan(15)); // 10 s – spoczynek
    expect(act[20], greaterThan(200)); // 40 s – ruch
    // CSV jest ~12x większy niż format binarny.
    final binSize = File('${dir.path}/ecg.bin').lengthSync();
    expect(binSize, lessThan(x.length * 2.2));
  });

  test('ramka ACC: nieskompresowana 16 bit i kompresja delta', () {
    final raw = [0x02, ...List.filled(8, 0), 0x01, 0x10, 0x00, 0xF0, 0xFF, 0xE8, 0x03]; // x=16,y=-16,z=1000
    final f = parseAccFrame(raw)!;
    expect(f.xyz, [16, -16, 1000]);
    // Kompresja: odniesienie (10, 20, 30), 1 próbka z deltami 4-bitowymi (+1, -1, +2).
    final comp = [0x02, ...List.filled(8, 0), 0x81, 10, 0, 20, 0, 30, 0, 4, 1, 0xF1, 0x02];
    final g = parseAccFrame(comp)!;
    expect(g.xyz, [10, 20, 30, 11, 19, 32]);
  });

  test('poprawki ręczne i personalizacja (k-NN) zmieniają etykiety', () async {
    final s = SyntheticEcg(seed: 2)
      ..sinus(30)
      ..withPvcs(220, every: 6);
    final x = s.render();
    final dir = await writeRecording(x);
    final first = await analyzeRecordingDir(dir.path);
    final vIdx = [for (var i = 0; i < first.labels.length; i++) if (first.labels[i] == BeatType.ventricular) i];
    expect(vIdx.length, greaterThan(10));

    // Użytkownik oznacza wszystkie pobudzenia V jako N (np. uznał je za swoje prawidłowe).
    await saveCorrections(dir.path, {for (final i in vIdx) first.rPeaks[i]: BeatType.normal});
    final second = await analyzeRecordingDir(dir.path);
    final leftV = [for (var i = 0; i < second.labels.length; i++) if (second.labels[i] == BeatType.ventricular) second.rPeaks[i]];
    // ignore: avoid_print
    print('pozostałe V: $leftV, poprawki: ${vIdx.map((i) => first.rPeaks[i]).toList()}');
    expect(second.count(BeatType.ventricular), 0);
    final profile = (await PersonalProfile.loadForRecording(dir.path))!;
    expect(profile.examples, vIdx.length);
    expect(profile.hasTemplate, isTrue);

    // Nowy zapis z takimi samymi pobudzeniami: k-NN z profilu oznacza je jako N bez poprawek.
    final dir2 = Directory('${tmp.path}/recordings/20260102_080000')..createSync(recursive: true);
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name == 'meta.json' || name.endsWith('.bin')) f.copySync('${dir2.path}/$name');
    }
    final third = await analyzeRecordingDir(dir2.path);
    expect(third.count(BeatType.ventricular), lessThan(vIdx.length ~/ 4));
  });
}

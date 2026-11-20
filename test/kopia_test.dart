import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koofr_backup_ui/testing.dart';
import 'package:polar_ecg/recording/koofr_backup.dart';
import 'package:polar_ecg/recording/recorder.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kopia na Koofr → nowy telefon (tylko kod odzyskiwania) → przywrócenie: zapisy i profil wracają.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('polar');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (c) async => dir.path);
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = null; // serwer WebDAV w pamięci potrzebuje prawdziwego HttpClient
  });

  test('przywrócenie kopii na czystym telefonie', () async {
    final root = await Recorder.recordingsRoot();
    final rec = Directory('${root.path}/20261119_223000')..createSync();
    File('${rec.path}/ecg.bin').writeAsBytesSync([1, 2, 3, 4]);
    File('${rec.path}/meta.json').writeAsStringSync('{"started":"2026-11-19T22:30:00"}');
    File('${rec.path}/analysis.json').writeAsStringSync('{}'); // pochodny — nie trafia do kopii
    File('${root.parent.path}/profile.json').writeAsStringSync('{"p":1}');
    final backup = PolarBackup(() => null);
    final restored = await kopiaAdapteraNaNowyTelefon(backup);
    expect(restored.blobs.keys, unorderedEquals(['recordings/20261119_223000/ecg.bin', 'recordings/20261119_223000/meta.json']));

    // „nowy telefon”: pusty katalog danych
    for (final f in dir.listSync()) {
      f.deleteSync(recursive: true);
    }
    await backup.import(restored, (_) {});
    final back = Directory('${(await Recorder.recordingsRoot()).path}/20261119_223000');
    expect(File('${back.path}/ecg.bin').readAsBytesSync(), [1, 2, 3, 4]);
    expect(File('${back.path}/analysis.json').existsSync(), isFalse);
    expect(File('${dir.path}/profile.json').readAsStringSync(), '{"p":1}');
  });
}

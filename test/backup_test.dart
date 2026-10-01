import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/recording/backup.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('backup'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory rec(Directory app, String name, {String ecg = 'EKG'}) {
    final d = Directory('${app.path}/recordings/$name')..createSync(recursive: true);
    File('${d.path}/ecg.bin').writeAsStringSync(ecg);
    File('${d.path}/meta.json').writeAsStringSync('{"started":"2026-01-01T08:00:00"}');
    File('${d.path}/analysis.json').writeAsStringSync('{}'); // pochodny – domyślnie pomijany
    return d;
  }

  test('kopia i przywrócenie: nowe zapisy dodane, istniejące nienadpisane, profil tylko gdy brak', () async {
    final src = Directory('${tmp.path}/src')..createSync();
    final a = rec(src, '20260101_080000', ecg: 'A');
    final b = rec(src, '20260102_080000', ecg: 'B');
    File('${src.path}/profile.json').writeAsStringSync('{"p":1}');
    final zip = await createArchive(
        out: File('${tmp.path}/kopia.zip'), recordings: [a, b], appDir: src, settings: {'name': 'Jan', 'sex': 'M'});

    final dst = Directory('${tmp.path}/dst')..createSync();
    rec(dst, '20260101_080000', ecg: 'LOKALNY'); // ten sam zapis już jest na telefonie
    final r = await restoreArchive(zip, dst);
    expect(r.added, 1);
    expect(r.skipped, 1);
    expect(r.profileRestored, isTrue);
    expect(r.settings?['name'], 'Jan');
    expect(File('${dst.path}/recordings/20260101_080000/ecg.bin').readAsStringSync(), 'LOKALNY');
    expect(File('${dst.path}/recordings/20260102_080000/ecg.bin').readAsStringSync(), 'B');
    expect(File('${dst.path}/recordings/20260102_080000/analysis.json').existsSync(), isFalse);
    expect(File('${dst.path}/profile.json').readAsStringSync(), '{"p":1}');

    // Drugie przywrócenie niczego nie dubluje ani nie nadpisuje profilu.
    File('${dst.path}/profile.json').writeAsStringSync('{"p":2}');
    final r2 = await restoreArchive(zip, dst);
    expect(r2.added, 0);
    expect(r2.profileRestored, isFalse);
    expect(File('${dst.path}/profile.json').readAsStringSync(), '{"p":2}');
  });
}

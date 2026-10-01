import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

/// Pliki źródłowe zapisu – wystarczą, żeby odtworzyć zapis i analizę na innym telefonie/PC.
/// (analysis.json / summary.json da się przeliczyć; wchodzą tylko gdy [withAnalysis].)
const recordingSourceFiles = {
  'ecg.bin', 'acc.bin', 'ecg.csv', 'rr.csv', 'events.csv', 'stamp.csv', 'markers.json', 'corrections.json',
  'meta.json',
};
const recordingDerivedFiles = {'analysis.json', 'summary.json'};

/// Plik ZIP z zapisami: `recordings/<zapis>/…`, opcjonalnie `profile.json` (profil osobisty),
/// `settings.json` (ustawienia aplikacji) i `hrv_morning.json`, oraz `manifest.json` z opisem.
/// [recordings] – katalogi zapisów do spakowania; [appDir] – katalog danych aplikacji (rodzic `recordings`).
Future<File> createArchive({
  required File out,
  required List<Directory> recordings,
  Directory? appDir,
  Map<String, Object?>? settings,
  bool withAnalysis = false,
  String kind = 'backup',
}) async {
  final enc = ZipFileEncoder()..create(out.path);
  var files = 0;
  for (final d in recordings) {
    final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
    for (final f in d.listSync().whereType<File>()) {
      final fn = f.uri.pathSegments.last;
      if (recordingSourceFiles.contains(fn) || (withAnalysis && recordingDerivedFiles.contains(fn))) {
        await enc.addFile(f, 'recordings/$name/$fn');
        files++;
      }
    }
  }
  if (appDir != null) {
    for (final fn in ['profile.json', 'hrv_morning.json']) {
      final f = File('${appDir.path}/$fn');
      if (f.existsSync()) await enc.addFile(f, fn);
    }
  }
  void addJson(String name, Object json) {
    final bytes = utf8.encode(const JsonEncoder.withIndent(' ').convert(json));
    enc.addArchiveFile(ArchiveFile(name, bytes.length, bytes));
  }

  if (settings != null) addJson('settings.json', settings);
  addJson('manifest.json', {
    'app': 'Polar EKG',
    'kind': kind,
    'created': DateTime.now().toIso8601String(),
    'recordings': recordings.length,
    'files': files,
  });
  await enc.close();
  return out;
}

class RestoreResult {
  final int added, skipped;
  final bool profileRestored;
  final Map<String, Object?>? settings; // ustawienia z kopii (zastosowanie decyduje wywołujący)
  RestoreResult(this.added, this.skipped, this.profileRestored, this.settings);
}

/// Przywraca kopię: dodaje zapisy, których jeszcze nie ma (istniejących nie nadpisuje), profil osobisty
/// i historię pomiarów porannych – tylko gdy lokalnie ich brak (żeby nie zgubić nowszych danych).
Future<RestoreResult> restoreArchive(File zip, Directory appDir) async {
  final archive = ZipDecoder().decodeStream(InputFileStream(zip.path));
  final recRoot = Directory('${appDir.path}/recordings')..createSync(recursive: true);
  final existing = {
    for (final d in recRoot.listSync().whereType<Directory>()) d.uri.pathSegments.where((s) => s.isNotEmpty).last
  };
  final added = <String>{}, skipped = <String>{};
  var profile = false;
  Map<String, Object?>? settings;
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final parts = f.name.split('/');
    // Ochrona przed ścieżkami spoza katalogu (np. "../").
    if (parts.any((p) => p == '..' || p.isEmpty)) continue;
    if (parts.length == 3 && parts[0] == 'recordings') {
      final rec = parts[1];
      if (existing.contains(rec)) {
        skipped.add(rec);
        continue;
      }
      added.add(rec);
      final out = File('${recRoot.path}/$rec/${parts[2]}')..createSync(recursive: true);
      out.writeAsBytesSync(f.readBytes()!);
    } else if (parts.length == 1 && (f.name == 'profile.json' || f.name == 'hrv_morning.json')) {
      final out = File('${appDir.path}/${f.name}');
      if (!out.existsSync()) {
        out.writeAsBytesSync(f.readBytes()!);
        if (f.name == 'profile.json') profile = true;
      }
    } else if (f.name == 'settings.json') {
      settings = (jsonDecode(utf8.decode(f.readBytes()!)) as Map).cast<String, Object?>();
    }
  }
  return RestoreResult(added.length, skipped.length, profile, settings);
}

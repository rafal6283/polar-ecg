import 'dart:convert';
import 'dart:io';

import 'package:koofr_backup_ui/koofr_backup_ui.dart';

import '../settings/app_settings.dart';
import '../export/exchange.dart' show buildAfExchange;
import 'backup.dart' show recordingSourceFiles;
import 'recorder.dart';

/// Kopia Polar EKG na rodzinnym Koofr. Pliki źródłowe zapisów (ecg.bin itd.) są załącznikami
/// wysyłanymi tylko raz — nowa noc to tylko nowe pliki. Analizy da się przeliczyć, więc ich nie ma.
class PolarBackup extends BackupAdapter {
  /// Zapis w toku (pomijany w kopii; kopia automatyczna czeka na koniec nagrywania).
  final Directory? Function() currentRecording;
  PolarBackup(this.currentRecording);

  /// Zapis, w którym coś zmieniło się w ostatnim [within] (prawdopodobnie trwa nagrywanie).
  static Future<Directory?> recentlyWritten(Duration within) async {
    final root = await Recorder.recordingsRoot();
    final now = DateTime.now();
    for (final d in root.listSync().whereType<Directory>()) {
      for (final f in d.listSync().whereType<File>()) {
        if (now.difference(f.lastModifiedSync()) < within) return d;
      }
    }
    return null;
  }

  @override
  String get appId => 'polar-ekg';
  @override
  String get appName => 'Polar EKG';
  @override
  String get contentNote =>
      'W kopii są zakończone zapisy (pliki źródłowe), profil osobisty, pomiary poranne HRV i ustawienia.';
  @override
  String get restoreWarning => 'Dodaje brakujące zapisy (istniejących nie nadpisuje) i przywraca ustawienia. '
      'Profil osobisty i pomiary poranne — tylko, jeśli na tym telefonie ich nie ma.';
  @override
  bool get busy => currentRecording() != null;

  @override
  ExchangeAdapter get exchange => _PolarExchange();

  @override
  Future<BackupContent> export() async {
    final recRoot = await Recorder.recordingsRoot();
    final appDir = recRoot.parent;
    final current = currentRecording()?.path;
    final blobs = <BackupBlob>[];
    for (final d in recRoot.listSync().whereType<Directory>()) {
      if (d.path == current) continue;
      final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      for (final f in d.listSync().whereType<File>()) {
        final fn = f.uri.pathSegments.last;
        if (recordingSourceFiles.contains(fn)) blobs.add(BackupBlob('recordings/$name/$fn', f.readAsBytes));
      }
    }
    Future<Object?> readJson(String fn) async {
      final f = File('${appDir.path}/$fn');
      return await f.exists() ? jsonDecode(await f.readAsString()) : null;
    }

    final data = utf8.encode(jsonEncode({
      'format': 'polar-ekg-kopia',
      'version': 1,
      'settings': AppSettings.instance.toJson(),
      'profile': await readJson('profile.json'),
      'hrv_morning': await readJson('hrv_morning.json'),
    }));
    return BackupContent(data, blobs);
  }

  @override
  Future<void> import(RestoredBackup r, void Function(String step) progress) async {
    final j = (jsonDecode(utf8.decode(r.data)) as Map).cast<String, Object?>();
    if (j['format'] != 'polar-ekg-kopia') throw KoofrException('To nie jest kopia Polar EKG.');
    final recRoot = await Recorder.recordingsRoot();
    final appDir = recRoot.parent;
    final existing = {
      for (final d in recRoot.listSync().whereType<Directory>()) d.uri.pathSegments.where((s) => s.isNotEmpty).last
    };
    // zapisy pobieramy do folderu tymczasowego i przenosimy w całości — bez połówek zapisów
    final byRec = <String, Map<String, String>>{};
    for (final e in r.blobs.entries) {
      final parts = e.key.split('/');
      if (parts.length != 3 || parts[0] != 'recordings' || parts.any((p) => p == '..' || p.isEmpty)) continue;
      if (existing.contains(parts[1])) continue;
      (byRec[parts[1]] ??= {})[parts[2]] = e.value;
    }
    var i = 0;
    for (final rec in byRec.entries) {
      progress('Zapisy: ${++i} z ${byRec.length}');
      final tmp = Directory('${recRoot.path}/.$rec.przywracanie');
      if (await tmp.exists()) await tmp.delete(recursive: true);
      await tmp.create(recursive: true);
      for (final f in rec.value.entries) {
        await File('${tmp.path}/${f.key}').writeAsBytes(await r.blob(f.value), flush: true);
      }
      await tmp.rename('${recRoot.path}/${rec.key}');
    }
    for (final (key, fn) in [('profile', 'profile.json'), ('hrv_morning', 'hrv_morning.json')]) {
      final out = File('${appDir.path}/$fn');
      if (j[key] != null && !await out.exists()) await out.writeAsString(jsonEncode(j[key]));
    }
    final s = j['settings'];
    if (s is Map) await AppSettings.instance.applyJson(s.cast<String, Object?>());
  }
}

/// Epizody AF do Kreski i Doby przez Koofr (zamiast ręcznego eksportu pliku).
class _PolarExchange extends ExchangeAdapter {
  @override
  String get publishes => 'Epizody migotania przedsionków (AF) z przeanalizowanych zapisów — dla Kreski i Doby';

  @override
  Future<Map<String, List<int>?>> export() async {
    final (bytes, _, _, _, _) = await buildAfExchange();
    return {'polar-ekg': bytes};
  }
}

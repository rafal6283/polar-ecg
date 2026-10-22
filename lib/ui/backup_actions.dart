import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../analysis/analyzer.dart';
import '../analysis/hrv_session.dart';
import '../recording/backup.dart';
import '../recording/markers.dart';
import '../recording/recorder.dart';
import '../report/pdf_report.dart';
import '../settings/app_settings.dart';
import 'report_fonts.dart';

String _stamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}';
}

Future<T> _withProgress<T>(BuildContext context, String text, Future<T> Function() job) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 16),
          Expanded(child: Text(text)),
        ]),
      ),
    ),
  );
  try {
    return await job();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// Wysyła wybrane zapisy jednym plikiem ZIP (np. do analizy na komputerze).
Future<void> shareRecordings(BuildContext context, List<Directory> dirs) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final tmp = await getTemporaryDirectory();
    if (!context.mounted) return;
    final zip = await _withProgress(context, 'Pakuję ${dirs.length} zapis(y)…', () {
      return createArchive(
        out: File('${tmp.path}/polar-ekg-zapisy_${_stamp()}.zip'),
        recordings: dirs,
        kind: 'export',
      );
    });
    await SharePlus.instance.share(ShareParams(files: [XFile(zip.path)], subject: 'Zapisy EKG (${dirs.length})'));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Nie udało się przygotować pliku: $e')));
  }
}

/// Pełna kopia: wszystkie zapisy, profil osobisty, pomiary poranne i ustawienia → udostępnij (Dysk, e-mail, PC).
Future<void> backupAll(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final root = await Recorder.recordingsRoot();
    final dirs = root.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
    final tmp = await getTemporaryDirectory();
    if (!context.mounted) return;
    final zip = await _withProgress(context, 'Tworzę kopię zapasową (${dirs.length} zapisów)…', () {
      return createArchive(
        out: File('${tmp.path}/polar-ekg-kopia_${_stamp()}.zip'),
        recordings: dirs,
        appDir: root.parent,
        settings: AppSettings.instance.toJson(),
      );
    });
    final mb = (zip.lengthSync() / 1024 / 1024).toStringAsFixed(1);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(zip.path)],
      subject: 'Kopia zapasowa Polar EKG',
      text: 'Kopia zapasowa Polar EKG: ${dirs.length} zapisów, $mb MB',
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Kopia nie powiodła się: $e')));
  }
}

/// Przywrócenie z pliku ZIP: brakujące zapisy, profil (gdy brak) i – po potwierdzeniu – ustawienia.
Future<void> restoreBackup(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Wybierz kopię Polar EKG (.zip)',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    final path = picked?.path;
    if (path == null || !context.mounted) return;
    final root = await Recorder.recordingsRoot();
    if (!context.mounted) return;
    final r = await _withProgress(context, 'Przywracam kopię…', () => restoreArchive(File(path), root.parent));
    var settingsApplied = false;
    if (r.settings != null && context.mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Przywrócić też ustawienia?'),
          content: const Text('Dane osoby, progi analizy i alarmów z kopii zastąpią obecne ustawienia.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nie')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Przywróć')),
          ],
        ),
      );
      if (ok == true) {
        await AppSettings.instance.applyJson(r.settings!);
        settingsApplied = true;
      }
    }
    messenger.showSnackBar(SnackBar(
      content: Text([
        'Dodano zapisów: ${r.added}',
        if (r.skipped > 0) 'pominięto istniejące: ${r.skipped}',
        if (r.profileRestored) 'przywrócono profil osobisty',
        if (settingsApplied) 'przywrócono ustawienia',
      ].join(' · ')),
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Nie udało się przywrócić kopii: $e')));
  }
}

/// Raport zbiorczy PDF z zapisów [dirs] (+ pomiary poranne HRV) → udostępnij.
Future<void> shareSummaryReport(BuildContext context, List<Directory> dirs) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final root = await Recorder.recordingsRoot();
    final tmp = await getTemporaryDirectory();
    if (!context.mounted) return;
    final file = await _withProgress(context, 'Przygotowuję raport z ${dirs.length} zapisów…', () async {
      final items = <SummaryItem>[];
      for (final d in dirs) {
        final a = await loadAnalysis(d.path) ?? await analyzeInBackground(d.path, AppSettings.instance.analysis);
        items.add(SummaryItem(a, await loadMarkers(d.path, a.timeline)));
      }
      final s = AppSettings.instance;
      final pdf = await buildSummaryReport(
        items: items,
        hrv: await HrvHistory.load(root.parent),
        person: ReportPerson(name: s.name, age: s.age, sex: s.sex),
        fontData: await loadReportFonts(),
      );
      return File('${tmp.path}/raport_zbiorczy_${_stamp()}.pdf')..writeAsBytesSync(pdf);
    });
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Raport zbiorczy EKG'));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Nie udało się przygotować raportu: $e')));
  }
}

/// Wybór okresu raportu zbiorczego.
Future<void> pickSummaryReport(BuildContext context) async {
  final days = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Raport zbiorczy PDF'), subtitle: Text('Dla lekarza: okres, dzień po dniu, zdarzenia, HRV')),
        for (final (d, t) in [(7, 'Ostatnie 7 dni'), (30, 'Ostatnie 30 dni'), (0, 'Wszystkie zapisy')])
          ListTile(leading: const Icon(Icons.date_range), title: Text(t), onTap: () => Navigator.pop(ctx, d)),
      ]),
    ),
  );
  if (days == null || !context.mounted) return;
  final root = await Recorder.recordingsRoot();
  final since = DateTime.now().subtract(Duration(days: days));
  final dirs = <Directory>[];
  for (final d in root.listSync().whereType<Directory>()) {
    if (days == 0) {
      dirs.add(d);
      continue;
    }
    final a = await loadAnalysis(d.path);
    final started = a?.timeline.started ?? d.statSync().modified;
    if (started.isAfter(since)) dirs.add(d);
  }
  if (!context.mounted) return;
  if (dirs.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Brak zapisów w wybranym okresie.')));
    return;
  }
  await shareSummaryReport(context, dirs);
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../analysis/analysis_result.dart';
import '../analysis/analyzer.dart';
import '../recording/recorder.dart';
import 'viewer/recording_screen.dart';

/// Lista zapisanych sesji z możliwością wysłania plików (np. na komputer) lub usunięcia.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingInfo {
  final Directory dir;
  final Map<String, dynamic> meta;
  final int bytes;
  final String? summary; // podsumowanie analizy, jeśli była wykonana

  _RecordingInfo(this.dir, this.meta, this.bytes, this.summary);

  String get name => dir.uri.pathSegments.where((s) => s.isNotEmpty).last;

  Duration get duration {
    final samples = (meta['ecg_samples'] as num?)?.toInt() ?? 0;
    final rate = (meta['sample_rate_hz'] as num?)?.toInt() ?? 130;
    return Duration(milliseconds: samples * 1000 ~/ rate);
  }
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  late Future<List<_RecordingInfo>> _items = _load();

  Future<List<_RecordingInfo>> _load() async {
    final root = await Recorder.recordingsRoot();
    final dirs = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    final out = <_RecordingInfo>[];
    for (final d in dirs) {
      Map<String, dynamic> meta = {};
      final mf = File('${d.path}/meta.json');
      if (mf.existsSync()) {
        try {
          meta = jsonDecode(mf.readAsStringSync()) as Map<String, dynamic>;
        } catch (_) {}
      }
      final bytes = d.listSync().whereType<File>().fold<int>(0, (s, f) => s + f.lengthSync());
      out.add(_RecordingInfo(d, meta, bytes, await _summary(d.path)));
    }
    return out;
  }

  Future<String?> _summary(String path) async {
    final a = await loadAnalysis(path);
    if (a == null) return null;
    final hr = a.stats['hr_mean'];
    final parts = <String>[
      if (hr != null) 'śr. ${hr.round()}/min',
      'V: ${a.stats['v']}',
      'S: ${a.stats['s']}',
      if (a.events.isNotEmpty) 'zdarzeń: ${a.events.length}',
      if (a.events.any((e) => e.severity == Severity.high)) '⚠',
    ];
    return parts.join(' · ');
  }

  Future<void> _open(_RecordingInfo r) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RecordingScreen(path: r.dir.path, title: _title(r)),
    ));
    if (!mounted) return;
    setState(() {
      _items = _load();
    });
  }

  Future<void> _share(_RecordingInfo r) async {
    // Tylko dane źródłowe; wyniki analizy da się odtworzyć.
    const sources = {'ecg.csv', 'rr.csv', 'events.csv', 'meta.json', 'analysis.json'};
    final files = r.dir
        .listSync()
        .whereType<File>()
        .where((f) => sources.contains(f.uri.pathSegments.last))
        .map((f) => XFile(f.path))
        .toList();
    await SharePlus.instance.share(ShareParams(files: files, subject: 'Zapis EKG ${r.name}'));
  }

  Future<void> _delete(_RecordingInfo r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Usunąć zapis?'),
        content: Text('${r.name} zostanie trwale usunięty z telefonu.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Usuń')),
        ],
      ),
    );
    if (ok != true) return;
    await r.dir.delete(recursive: true);
    if (!mounted) return;
    setState(() {
      _items = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zapisy')),
      body: FutureBuilder<List<_RecordingInfo>>(
        future: _items,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) return const Center(child: Text('Brak zapisów'));
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = items[i];
              final d = r.duration;
              final mb = (r.bytes / 1024 / 1024).toStringAsFixed(1);
              return ListTile(
                onTap: () => _open(r),
                title: Text(_title(r)),
                subtitle: Text([
                  '${d.inHours} h ${d.inMinutes % 60} min ${d.inSeconds % 60} s · $mb MB',
                  r.summary ?? 'nieprzeanalizowany – stuknij',
                ].join('\n')),
                isThreeLine: true,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.share), tooltip: 'Wyślij', onPressed: () => _share(r)),
                  IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Usuń', onPressed: () => _delete(r)),
                ]),
              );
            },
          );
        },
      ),
    );
  }

  String _title(_RecordingInfo r) {
    final started = DateTime.tryParse(r.meta['started'] as String? ?? '');
    if (started == null) return r.name;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(started.day)}.${two(started.month)}.${started.year}  ${two(started.hour)}:${two(started.minute)}';
  }
}

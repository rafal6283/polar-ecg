import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../analysis/analysis_result.dart';
import '../analysis/analyzer.dart';
import '../recording/recorder.dart';
import 'theme/app_theme.dart';
import 'viewer/format.dart';
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
  final AnalysisResult? analysis; // wynik analizy, jeśli była wykonana

  _RecordingInfo(this.dir, this.meta, this.bytes, this.analysis);

  String get name => dir.uri.pathSegments.where((s) => s.isNotEmpty).last;

  DateTime? get started => DateTime.tryParse(meta['started'] as String? ?? '');

  Duration get duration {
    final samples = (meta['ecg_samples'] as num?)?.toInt() ?? 0;
    final rate = (meta['sample_rate_hz'] as num?)?.toInt() ?? 130;
    if (samples == 0 && analysis != null) {
      return Duration(seconds: (analysis!.stats['duration_s'] ?? 0).round());
    }
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
      out.add(_RecordingInfo(d, meta, bytes, await loadAnalysis(d.path)));
    }
    return out;
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
    // Komplet do odtworzenia zapisu na innym urządzeniu/PC: sygnał (bin, starsze csv), akcelerometr,
    // RR z opaski, znaczniki objawów, poprawki ręczne i metadane. Wyniki analizy da się przeliczyć.
    const sources = {
      'ecg.bin', 'acc.bin', 'ecg.csv', 'rr.csv', 'events.csv', 'markers.json', 'corrections.json', 'meta.json',
      'analysis.json',
    };
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
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.folder_open_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('Brak zapisów', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Połącz opaskę na ekranie Monitor i rozpocznij nagrywanie.', textAlign: TextAlign.center),
                ]),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _RecordingCard(
              info: items[i],
              title: _title(items[i]),
              onOpen: () => _open(items[i]),
              onShare: () => _share(items[i]),
              onDelete: () => _delete(items[i]),
            ),
          );
        },
      ),
    );
  }

  String _title(_RecordingInfo r) {
    final started = DateTime.tryParse(r.meta['started'] as String? ?? '');
    if (started == null) return r.name;
    return '${fmtDate(started)}, ${fmtClock(started).substring(0, 5)}';
  }
}

const _months = ['STY', 'LUT', 'MAR', 'KWI', 'MAJ', 'CZE', 'LIP', 'SIE', 'WRZ', 'PAŹ', 'LIS', 'GRU'];

class _RecordingCard extends StatelessWidget {
  final _RecordingInfo info;
  final String title;
  final VoidCallback onOpen, onShare, onDelete;

  const _RecordingCard(
      {required this.info, required this.title, required this.onOpen, required this.onShare, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final colors = AppColors.of(context);
    final st = info.started;
    final a = info.analysis;
    final s = a?.stats;
    final high = a?.events.where((e) => e.severity == Severity.high).length ?? 0;
    final mb = (info.bytes / 1024 / 1024).toStringAsFixed(1);
    return Card(
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 52,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Text(st == null ? '–' : '${st.day}', style: t.titleLarge?.copyWith(color: scheme.onPrimaryContainer, height: 1.1)),
                Text(st == null ? '' : _months[st.month - 1],
                    style: t.labelSmall?.copyWith(color: scheme.onPrimaryContainer, letterSpacing: 1)),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(st == null ? title : 'godz. ${fmtClock(st).substring(0, 5)} · ${fmtDuration(info.duration)}',
                    style: t.titleSmall),
                Text(st == null ? '$mb MB' : '${fmtDate(st)} · $mb MB', style: t.bodySmall),
                const SizedBox(height: 8),
                if (a == null)
                  Text('Nieprzeanalizowany – stuknij, aby otworzyć', style: t.bodySmall?.copyWith(color: scheme.primary))
                else
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    if (s!['hr_mean'] != null) _Chip('${s['hr_mean']!.round()}/min', Icons.favorite_border, scheme.primary),
                    _Chip('V ${s['v'] ?? 0}', null, (s['v'] ?? 0) > 0 ? colors.beatV : scheme.outline),
                    _Chip('S ${s['s'] ?? 0}', null, (s['s'] ?? 0) > 0 ? colors.beatS : scheme.outline),
                    if ((s['af_burden_pct'] ?? 0) > 0) _Chip('AF ${fmtNum(s['af_burden_pct'], digits: 1)}%', null, colors.af),
                    if (a.events.isNotEmpty)
                      _Chip(plural(a.events.length, 'zdarzenie', 'zdarzenia', 'zdarzeń'),
                          high > 0 ? Icons.warning_amber_rounded : null, high > 0 ? colors.danger : colors.warning),
                  ]),
              ]),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) => v == 'share' ? onShare() : onDelete(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share), title: Text('Wyślij pliki zapisu'))),
                PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Usuń'))),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color color;
  const _Chip(this.text, this.icon, this.color);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 3)],
          Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ]),
      );
}

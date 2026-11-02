import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:rodzina_wykresy/rodzina_wykresy.dart' show InteractiveLineChart, LineSeries, ChartPoint;

import '../analysis/analysis_result.dart';
import '../analysis/analyzer.dart';
import '../analysis/hrv_session.dart';
import '../recording/recorder.dart';
import '../settings/app_settings.dart';
import 'theme/app_theme.dart';
import 'af_diary_card.dart';
import 'af_triggers_card.dart';
import 'viewer/format.dart';

class _Metric {
  final String key, label, unit;
  final int digits;
  final bool morningOnly;
  const _Metric(this.key, this.label, this.unit, {this.digits = 0, this.morningOnly = false});
}

const _metrics = [
  _Metric('hrv_guided', 'HRV – pomiar poranny', 'ms', morningOnly: true),
  _Metric('rmssd_ms', 'HRV poranne z zapisów', 'ms', morningOnly: true),
  _Metric('hr_mean', 'Tętno średnie', '/min'),
  _Metric('hr_rest', 'Tętno w spoczynku', '/min'),
  _Metric('hr_min', 'Tętno minimalne', '/min'),
  _Metric('rmssd_ms', 'RMSSD (wszystkie zapisy)', 'ms'),
  _Metric('sdnn_ms', 'SDNN', 'ms'),
  _Metric('v_per_h', 'Pobudzenia V na godzinę', '/h', digits: 1),
  _Metric('s_per_h', 'Pobudzenia S na godzinę', '/h', digits: 1),
  _Metric('af_burden_pct', 'Obciążenie migotaniem', '%', digits: 1),
  _Metric('qtc_ms', 'QTc', 'ms'),
  _Metric('qrs_ms', 'QRS', 'ms'),
];

/// Trendy parametrów z wielu zapisów w czasie.
/// Typowa wartość: średnia ± odch. std. z 7 ostatnich pomiarów (przed ostatnim).
(double, double)? _personalBand(List<(DateTime, double)> pts) {
  if (pts.length < 4) return null;
  final prev = pts.sublist(max(0, pts.length - 8), pts.length - 1).map((p) => p.$2).toList();
  final m = prev.reduce((a, b) => a + b) / prev.length;
  final sd = sqrt(prev.map((v) => (v - m) * (v - m)).reduce((a, b) => a + b) / prev.length);
  return (m - sd, m + sd);
}

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  List<Map<String, dynamic>> _rows = [];
  List<HrvMeasurement> _hrv = []; // prowadzone pomiary poranne (hrv_morning.json)
  List<String> _missing = []; // zapisy bez analizy
  int _metric = 0;
  bool _loading = true;
  String? _progress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final root = await Recorder.recordingsRoot();
    final rows = <Map<String, dynamic>>[];
    final missing = <String>[];
    for (final d in root.listSync().whereType<Directory>()) {
      final f = File('${d.path}/$summaryFile');
      if (f.existsSync()) {
        try {
          final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
          if (j['version'] == AnalysisResult.version) {
            rows.add(j);
            continue;
          }
        } catch (_) {}
      }
      if (File('${d.path}/ecg.bin').existsSync() || File('${d.path}/ecg.csv').existsSync()) missing.add(d.path);
    }
    rows.sort((a, b) => (a['started'] as String).compareTo(b['started'] as String));
    final hrv = await HrvHistory.load(root.parent);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _hrv = hrv;
      _missing = missing;
      _loading = false;
    });
  }

  Future<void> _analyzeMissing() async {
    for (var i = 0; i < _missing.length; i++) {
      setState(() => _progress = 'Analiza ${i + 1} z ${_missing.length}…');
      try {
        await analyzeInBackground(_missing[i], AppSettings.instance.analysis);
      } catch (_) {}
    }
    setState(() => _progress = null);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final m = _metrics[_metric];
    final pts = m.key == 'hrv_guided'
        ? [for (final h in _hrv) if (h.reliable) (h.time, h.rmssd)]
        : [
            for (final r in _rows)
              if (r[m.key] != null && (!m.morningOnly || r['morning'] == true))
                (DateTime.parse(r['started'] as String), (r[m.key] as num).toDouble())
          ];
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Trendy')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_missing.isNotEmpty)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.analytics_outlined),
                      title: Text('Nieprzeanalizowane zapisy: ${_missing.length}'),
                      subtitle: Text(_progress ?? 'Przeanalizuj, aby uwzględnić je w trendach.'),
                      trailing: _progress != null
                          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : TextButton(onPressed: _analyzeMissing, child: const Text('ANALIZUJ')),
                    ),
                  ),
                AfDiaryCard(rows: _rows),
                AfTriggersCard(rows: _rows, hrv: _hrv),
                const SectionLabel('Parametry w czasie'),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (var i = 0; i < _metrics.length; i++)
                    ChoiceChip(label: Text(_metrics[i].label), selected: i == _metric, onSelected: (_) => setState(() => _metric = i)),
                ]),
                const SizedBox(height: 12),
                if (m.key == 'hrv_guided')
                  Text(
                    'Wyniki prowadzonego pomiaru (Monitor → Poranny pomiar HRV); tylko wiarygodne pomiary. '
                    'Pasmo – Twoja typowa wartość (średnia ± odch. std. z 7 ostatnich pomiarów). Przesuń palcem po wykresie.',
                    style: t.bodySmall,
                  )
                else if (m.morningOnly)
                  Text(
                    'Pomiar poranny = zapis 1–15 min rozpoczęty między 5:00 a 10:00, najlepiej na leżąco zaraz po '
                    'przebudzeniu. Pasmo – Twoja typowa wartość (średnia ± odch. std. z 7 poprzednich pomiarów); '
                    'wynik wyraźnie poniżej pasma może oznaczać zmęczenie, chorobę lub słabą regenerację.',
                    style: t.bodySmall,
                  ),
                const SizedBox(height: 8),
                if (pts.length < 2)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Text(
                      pts.isEmpty ? 'Brak danych dla tego parametru.' : 'Potrzebne są co najmniej 2 zapisy.',
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  InteractiveLineChart(
                    series: [
                      LineSeries(m.label, Theme.of(context).colorScheme.primary, [for (final (d, v) in pts) ChartPoint(d, v)],
                          area: true, dots: pts.length <= 60),
                    ],
                    band: m.morningOnly || m.key == 'hrv_guided' ? _personalBand(pts) : null,
                    bandLabel: 'Twoja norma',
                    yFormat: (v) => fmtNum(v, digits: m.digits),
                    xFormat: (d) => '${fmtDate(d)} ${fmtClock(d).substring(0, 5)}',
                    height: 230,
                  ),
                const SizedBox(height: 12),
                for (final (d, v) in pts.reversed)
                  ListTile(
                    dense: true,
                    title: Text('${fmtDate(d)}  ${fmtClock(d).substring(0, 5)}'),
                    trailing: Text(fmtNum(v, digits: m.digits, unit: m.unit), style: t.titleSmall),
                  ),
              ],
            ),
    );
  }
}

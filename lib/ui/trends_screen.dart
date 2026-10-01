import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../analysis/analysis_result.dart';
import '../analysis/analyzer.dart';
import '../recording/recorder.dart';
import '../settings/app_settings.dart';
import 'viewer/format.dart';

class _Metric {
  final String key, label, unit;
  final int digits;
  final bool morningOnly;
  const _Metric(this.key, this.label, this.unit, {this.digits = 0, this.morningOnly = false});
}

const _metrics = [
  _Metric('rmssd_ms', 'HRV poranne (RMSSD)', 'ms', morningOnly: true),
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
class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  List<Map<String, dynamic>> _rows = [];
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
    if (!mounted) return;
    setState(() {
      _rows = rows;
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
    final pts = [
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
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (var i = 0; i < _metrics.length; i++)
                    ChoiceChip(label: Text(_metrics[i].label), selected: i == _metric, onSelected: (_) => setState(() => _metric = i)),
                ]),
                const SizedBox(height: 12),
                if (m.morningOnly)
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
                  SizedBox(
                    height: 220,
                    child: CustomPaint(
                      painter: _TrendPainter(pts, Theme.of(context).colorScheme, band: m.morningOnly),
                      size: Size.infinite,
                    ),
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

class _TrendPainter extends CustomPainter {
  final List<(DateTime, double)> pts;
  final ColorScheme scheme;
  final bool band;

  _TrendPainter(this.pts, this.scheme, {this.band = false});

  @override
  void paint(Canvas canvas, Size size) {
    const left = 40.0, bottom = 22.0;
    final w = size.width - left, h = size.height - bottom;
    final t0 = pts.first.$1.millisecondsSinceEpoch.toDouble();
    final t1 = max(t0 + 1, pts.last.$1.millisecondsSinceEpoch.toDouble());
    var lo = pts.map((p) => p.$2).reduce(min), hi = pts.map((p) => p.$2).reduce(max);
    final pad = max(1.0, (hi - lo) * 0.15);
    lo -= pad;
    hi += pad;
    double x(DateTime d) => left + (d.millisecondsSinceEpoch - t0) / (t1 - t0) * w;
    double y(double v) => h - (v - lo) / (hi - lo) * h;

    final grid = Paint()..color = scheme.outlineVariant..strokeWidth = 0.6;
    for (var k = 0; k <= 4; k++) {
      final v = lo + (hi - lo) * k / 4;
      canvas.drawLine(Offset(left, y(v)), Offset(size.width, y(v)), grid);
      _text(canvas, v.toStringAsFixed(v.abs() < 10 ? 1 : 0), Offset(2, y(v) - 7));
    }
    _text(canvas, fmtDate(pts.first.$1), Offset(left, h + 4));
    _text(canvas, fmtDate(pts.last.$1), Offset(size.width - 62, h + 4));

    // Pasmo normy osobistej (średnia ± SD z 7 poprzednich pomiarów).
    if (band) {
      final path = Path(), lower = <Offset>[];
      var started = false;
      for (var i = 3; i < pts.length; i++) {
        final prev = pts.sublist(max(0, i - 7), i).map((p) => p.$2).toList();
        final m = prev.reduce((a, b) => a + b) / prev.length;
        final sd = sqrt(prev.map((v) => (v - m) * (v - m)).reduce((a, b) => a + b) / prev.length);
        final px = x(pts[i].$1);
        if (!started) {
          path.moveTo(px, y(m + sd));
          started = true;
        } else {
          path.lineTo(px, y(m + sd));
        }
        lower.add(Offset(px, y(m - sd)));
      }
      if (started) {
        for (final o in lower.reversed) {
          path.lineTo(o.dx, o.dy);
        }
        path.close();
        canvas.drawPath(path, Paint()..color = scheme.primary.withValues(alpha: 0.15));
      }
    }

    final line = Path()..moveTo(x(pts.first.$1), y(pts.first.$2));
    for (final p in pts.skip(1)) {
      line.lineTo(x(p.$1), y(p.$2));
    }
    canvas.drawPath(line, Paint()..color = scheme.primary..strokeWidth = 2..style = PaintingStyle.stroke);
    for (final p in pts) {
      canvas.drawCircle(Offset(x(p.$1), y(p.$2)), 3.5, Paint()..color = scheme.primary);
    }
  }

  void _text(Canvas c, String s, Offset o) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => old.pts != pts;
}

import 'dart:math';

import 'package:flutter/material.dart';

import '../../analysis/analysis_result.dart';
import '../../analysis/reference_ranges.dart';
import '../../settings/app_settings.dart';
import '../legend_screen.dart';
import 'format.dart';

/// Parametry przebiegu z zakresami i oceną + rysunek uśrednionego zespołu.
class WaveformCard extends StatelessWidget {
  final AnalysisResult analysis;

  const WaveformCard({super.key, required this.analysis});

  @override
  Widget build(BuildContext context) {
    final s = analysis.stats.values;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final sex = AppSettings.instance.sex;
    final params = paramsFor(sex);
    final bad = outOfRange(s, sex: sex);
    final measured = params.any((p) => s[p.key] != null);
    const ok = Color(0xFF2E7D32), warn = Color(0xFFD32F2F);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: (bad.isEmpty ? ok : warn).withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Text(
              !measured
                  ? 'ZA MAŁO PRAWIDŁOWYCH POBUDZEŃ DO POMIARU'
                  : bad.isEmpty
                      ? 'W NORMIE'
                      : 'POZA ZAKRESEM: ${bad.map((p) => p.label).join(', ')}',
              textAlign: TextAlign.center,
              style: t.titleSmall?.copyWith(color: bad.isEmpty ? ok : warn, fontWeight: FontWeight.w700),
            ),
          ),
          if (analysis.template != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: AspectRatio(
                aspectRatio: 2.2,
                child: CustomPaint(painter: _TemplatePainter(analysis, scheme, Theme.of(context).brightness == Brightness.dark)),
              ),
            ),
          if (analysis.template != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(
                'Uśredniony zespół z ${fmtNum(s['beats_averaged'])} pobudzeń · '
                'P  ·  QRS  ·  J  ·  szczyt T  ·  koniec T',
                style: t.labelSmall,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Table(
              columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(2), 2: FlexColumnWidth(2)},
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                for (final p in params)
                  if (s[p.key] != null)
                    TableRow(children: [
                      InkWell(
                        onTap: () => showParamInfo(context, p),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(children: [
                            Flexible(child: Text(p.label)),
                            const SizedBox(width: 4),
                            Icon(Icons.info_outline, size: 14, color: scheme.outline),
                          ]),
                        ),
                      ),
                      Text(
                        '${fmtNum(s[p.key], digits: p.digits)} ${p.unit}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: switch (p.within(s[p.key])) {
                            false => warn,
                            _ => null,
                          },
                        ),
                      ),
                      Text(
                        p.rated ? '[${p.rangeText}]' : '',
                        textAlign: TextAlign.right,
                        style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ]),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              'Stuknij parametr, aby zobaczyć objaśnienie. Zakresy dla standardowego EKG spoczynkowego. Opaska rejestruje jedno, niestandardowe '
              'odprowadzenie piersiowe (130 Hz) – odstępy mają dokładność ok. ±10 ms, a QT bywa krótsze '
              'niż w 12-odprowadzeniowym EKG.',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplatePainter extends CustomPainter {
  final AnalysisResult a;
  final ColorScheme scheme;
  final bool dark;

  _TemplatePainter(this.a, this.scheme, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    final tpl = a.template!;
    final fs = a.sampleRate;
    final s = a.stats.values;
    final w = size.width, h = size.height;
    const msFrom = -300.0, msTo = 600.0;
    double x(double ms) => (ms - msFrom) / (msTo - msFrom) * w;
    final base = (s['m_base_uv'] ?? 0).toDouble();
    var peak = 500.0;
    for (final v in tpl) {
      peak = max(peak, (v - base).abs());
    }
    final pxPerUv = h / 2 / (peak * 1.15);
    double y(double uv) => h / 2 - (uv - base) * pxPerUv;

    canvas.drawRect(Offset.zero & size, Paint()..color = dark ? const Color(0xFF1A1414) : const Color(0xFFFFF9F7));
    final minor = Paint()..color = dark ? const Color(0xFF3A2626) : const Color(0xFFF6D3CC)..strokeWidth = 0.5;
    final major = Paint()..color = dark ? const Color(0xFF5E3434) : const Color(0xFFE8A196)..strokeWidth = 0.8;
    for (var ms = msFrom; ms <= msTo; ms += 40) {
      canvas.drawLine(Offset(x(ms), 0), Offset(x(ms), h), (ms % 200 == 0) ? major : minor);
    }
    for (var uv = 0.0; uv * pxPerUv <= h / 2; uv += 100) {
      final p = uv % 500 == 0 ? major : minor;
      canvas.drawLine(Offset(0, y(base + uv)), Offset(w, y(base + uv)), p);
      canvas.drawLine(Offset(0, y(base - uv)), Offset(w, y(base - uv)), p);
    }

    final marks = <String, Color>{
      'm_p_on': const Color(0xFF2E7D32),
      'm_qrs_on': const Color(0xFF1565C0),
      'm_j': const Color(0xFF8E24AA),
      'm_t_peak': const Color(0xFFEF6C00),
      'm_t_end': const Color(0xFFC62828),
    };
    marks.forEach((k, c) {
      final v = s[k];
      if (v == null) return;
      final px = x(v.toDouble());
      canvas.drawLine(Offset(px, 0), Offset(px, h), Paint()..color = c.withValues(alpha: 0.8)..strokeWidth = 1.5);
    });

    final path = Path();
    for (var k = 0; k < tpl.length; k++) {
      final ms = (k - a.templatePre) * 1000 / fs;
      final p = Offset(x(ms), y(tpl[k]));
      k == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = dark ? const Color(0xFFEDEDED) : const Color(0xFF111111)
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _TemplatePainter old) => old.a != a || old.dark != dark;
}

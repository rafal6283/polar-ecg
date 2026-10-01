import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../analysis/analysis_result.dart';
import 'ecg_strip_view.dart';
import 'viewport.dart';
import '../theme/app_theme.dart';

/// Odstępy RR całego zapisu w funkcji czasu. Stuknięcie/przeciągnięcie przenosi widok EKG.
class Tachogram extends StatelessWidget {
  final AnalysisResult analysis;
  final EcgViewport viewport;

  const Tachogram({super.key, required this.analysis, required this.viewport});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      void jump(double x) => viewport.centerOn(x / box.maxWidth * viewport.totalSamples);
      return GestureDetector(
        onTapDown: (d) => jump(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => jump(d.localPosition.dx),
        child: ListenableBuilder(
          listenable: viewport,
          builder: (context, _) => CustomPaint(
            size: Size(box.maxWidth, box.maxHeight),
            painter: _TachoPainter(analysis, viewport.start, viewport.span, Theme.of(context).colorScheme),
          ),
        ),
      );
    });
  }
}

class _TachoPainter extends CustomPainter {
  final AnalysisResult a;
  final double start, span;
  final ColorScheme scheme;

  _TachoPainter(this.a, this.start, this.span, this.scheme);

  static const minMs = 300.0, maxMs = 2000.0;

  @override
  void paint(Canvas canvas, Size size) {
    final total = max(1, a.timeline.totalSamples);
    final fs = a.sampleRate;
    final w = size.width, h = size.height;
    double xOf(num s) => s / total * w;
    double yOf(double ms) => h - (ms.clamp(minMs, maxMs) - minMs) / (maxMs - minMs) * h;

    canvas.drawRect(Offset.zero & size, Paint()..color = scheme.surfaceContainerHighest);

    for (final e in a.events) {
      if (e.type != EventType.af) continue;
      canvas.drawRect(Rect.fromLTRB(xOf(e.startSample), 0, max(xOf(e.endSample), xOf(e.startSample) + 1), h),
          Paint()..color = AppColors.light.af.withValues(alpha: 0.22));
    }
    for (final n in a.noisy) {
      canvas.drawRect(Rect.fromLTRB(xOf(n[0]), 0, max(xOf(n[1]), xOf(n[0]) + 1), h),
          Paint()..color = scheme.outline.withValues(alpha: 0.15));
    }

    final grid = Paint()..color = scheme.outlineVariant..strokeWidth = 0.5;
    for (final ms in [500.0, 1000.0, 1500.0]) {
      canvas.drawLine(Offset(0, yOf(ms)), Offset(w, yOf(ms)), grid);
    }

    final pts = List.generate(4, (_) => <double>[]);
    for (var k = 1; k < a.rPeaks.length; k++) {
      final rr = (a.rPeaks[k] - a.rPeaks[k - 1]) * 1000 / fs;
      if (rr > 3500) continue; // przerwa w zapisie
      pts[a.labels[k]]
        ..add(xOf(a.rPeaks[k]))
        ..add(yOf(rr));
    }
    for (final l in [BeatType.normal, BeatType.unknown, BeatType.supraventricular, BeatType.ventricular]) {
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(pts[l]),
        Paint()
          ..color = beatColor(l, scheme)
          ..strokeWidth = l == BeatType.normal ? 1.5 : 3
          ..strokeCap = StrokeCap.round,
      );
    }

    // Aktualny widok EKG.
    final vx0 = xOf(start), vx1 = max(xOf(start + span), vx0 + 2);
    canvas.drawRect(Rect.fromLTRB(vx0, 0, vx1, h), Paint()..color = scheme.primary.withValues(alpha: 0.25));
    canvas.drawLine(Offset((vx0 + vx1) / 2, 0), Offset((vx0 + vx1) / 2, h), Paint()..color = scheme.primary..strokeWidth = 1.5);

    final tp = TextPainter(
      text: TextSpan(text: 'RR [ms]  500 · 1000 · 1500', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 9)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(4, 2));
  }

  @override
  bool shouldRepaint(covariant _TachoPainter old) => old.start != start || old.span != span || old.a != a;
}

/// Wykres Poincaré: RR(n) vs RR(n+1).
class PoincarePlot extends StatelessWidget {
  final AnalysisResult analysis;

  const PoincarePlot({super.key, required this.analysis});

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: 1,
        child: CustomPaint(painter: _PoincarePainter(analysis, Theme.of(context).colorScheme)),
      );
}

class _PoincarePainter extends CustomPainter {
  final AnalysisResult a;
  final ColorScheme scheme;

  _PoincarePainter(this.a, this.scheme);

  @override
  void paint(Canvas canvas, Size size) {
    const lo = 300.0, hi = 2000.0;
    final s = size.width;
    double p(double ms) => (ms.clamp(lo, hi) - lo) / (hi - lo) * s;
    canvas.drawRect(Offset.zero & size, Paint()..color = scheme.surfaceContainerHighest);
    final grid = Paint()..color = scheme.outlineVariant..strokeWidth = 0.5;
    for (final ms in [500.0, 1000.0, 1500.0]) {
      canvas.drawLine(Offset(p(ms), 0), Offset(p(ms), s), grid);
      canvas.drawLine(Offset(0, s - p(ms)), Offset(s, s - p(ms)), grid);
    }
    canvas.drawLine(Offset(0, s), Offset(s, 0), grid);
    final fs = a.sampleRate;
    final pts = List.generate(4, (_) => <double>[]);
    for (var k = 2; k < a.rPeaks.length; k++) {
      final r1 = (a.rPeaks[k - 1] - a.rPeaks[k - 2]) * 1000 / fs;
      final r2 = (a.rPeaks[k] - a.rPeaks[k - 1]) * 1000 / fs;
      if (r1 > 3500 || r2 > 3500) continue;
      final l = max(a.labels[k], a.labels[k - 1]);
      pts[l]
        ..add(p(r1))
        ..add(s - p(r2));
    }
    for (final l in [BeatType.normal, BeatType.unknown, BeatType.supraventricular, BeatType.ventricular]) {
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(pts[l]),
        Paint()
          ..color = beatColor(l, scheme).withValues(alpha: 0.6)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
    final tp = TextPainter(
      text: TextSpan(text: 'RRₙ → RRₙ₊₁  (300–2000 ms)', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(6, 4));
  }

  @override
  bool shouldRepaint(covariant _PoincarePainter old) => old.a != a;
}

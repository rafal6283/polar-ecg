import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../analysis/analysis_result.dart';
import 'format.dart';
import 'viewport.dart';
import '../theme/app_theme.dart';

/// Przewijany i skalowany wykres EKG z oznaczeniami pobudzeń.
/// Przeciągnięcie – przesuw, rozsunięcie palców – skala czasu, podwójne stuknięcie – 10 s.
class EcgStripView extends StatefulWidget {
  final Float32List signal;
  final AnalysisResult analysis;
  final EcgViewport viewport;

  /// Ręczne poprawki (próbka R → etykieta), także jeszcze nieprzeliczone.
  final Map<int, int> corrections;

  /// Znaczniki objawów: próbka → opis.
  final Map<int, String> markers;
  final void Function(int beatIndex)? onBeatTap;
  final void Function(int sample)? onLongPressEmpty;

  const EcgStripView({
    super.key,
    required this.signal,
    required this.analysis,
    required this.viewport,
    this.corrections = const {},
    this.markers = const {},
    this.onBeatTap,
    this.onLongPressEmpty,
  });

  @override
  State<EcgStripView> createState() => _EcgStripViewState();
}

class _EcgStripViewState extends State<EcgStripView> {
  double _startSpan = 0;
  double _lastFocalX = 0;

  /// Pobudzenie najbliższe pozycji x (w promieniu 24 px) lub null.
  int? _beatNear(double x, double width) {
    final vp = widget.viewport;
    final a = widget.analysis;
    final sample = vp.start + x / width * vp.span;
    final tol = 24 / width * vp.span;
    final k = a.beatIndexAtOrAfter(sample - tol);
    int? best;
    for (var i = k; i < a.rPeaks.length && a.rPeaks[i] <= sample + tol; i++) {
      if (best == null || (a.rPeaks[i] - sample).abs() < (a.rPeaks[best] - sample).abs()) best = i;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final vp = widget.viewport;
    return LayoutBuilder(builder: (context, box) {
      return GestureDetector(
        onScaleStart: (d) {
          _startSpan = vp.span;
          _lastFocalX = d.localFocalPoint.dx;
        },
        onScaleUpdate: (d) {
          final w = box.maxWidth;
          if (d.pointerCount >= 2 && d.horizontalScale > 0) {
            vp.zoom(_startSpan / d.horizontalScale, (d.localFocalPoint.dx / w).clamp(0, 1));
          }
          final dx = d.localFocalPoint.dx - _lastFocalX;
          _lastFocalX = d.localFocalPoint.dx;
          vp.set(vp.start - dx * vp.span / w);
        },
        onDoubleTap: () => vp.zoom(10.0 * vp.sampleRate, 0.5),
        onTapUp: widget.onBeatTap == null
            ? null
            : (d) {
                final k = _beatNear(d.localPosition.dx, box.maxWidth);
                if (k != null) widget.onBeatTap!(k);
              },
        onLongPressStart: widget.onLongPressEmpty == null
            ? null
            : (d) {
                if (_beatNear(d.localPosition.dx, box.maxWidth) != null) return;
                widget.onLongPressEmpty!((vp.start + d.localPosition.dx / box.maxWidth * vp.span).round());
              },
        child: ListenableBuilder(
          listenable: vp,
          builder: (context, _) => CustomPaint(
            size: Size(box.maxWidth, box.maxHeight),
            painter: _StripPainter(
              signal: widget.signal,
              a: widget.analysis,
              start: vp.start,
              span: vp.span,
              scheme: Theme.of(context).colorScheme,
              dark: Theme.of(context).brightness == Brightness.dark,
              palette: AppColors.of(context),
              corrections: widget.corrections,
              markers: widget.markers,
            ),
          ),
        ),
      );
    });
  }
}

class _StripPainter extends CustomPainter {
  final Float32List signal;
  final AnalysisResult a;
  final double start, span;
  final ColorScheme scheme;
  final bool dark;
  final AppColors palette;
  final Map<int, int> corrections;
  final Map<int, String> markers;

  _StripPainter({
    required this.signal,
    required this.a,
    required this.start,
    required this.span,
    required this.scheme,
    required this.dark,
    required this.palette,
    this.corrections = const {},
    this.markers = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fs = a.sampleRate;
    final w = size.width, h = size.height;
    const top = 22.0, bottom = 18.0;
    final plotH = h - top - bottom;
    final midY = top + plotH / 2;
    double xOf(num s) => (s - start) / span * w;

    canvas.drawRect(Offset.zero & size, Paint()..color = palette.paper);

    final s0 = max(0, start.floor());
    final s1 = min(signal.length, (start + span).ceil() + 1);

    // Tła: epizody AF, artefakty.
    final afPaint = Paint()..color = palette.af.withValues(alpha: 0.12);
    for (final e in a.events) {
      if (e.type != EventType.af || e.endSample < s0 || e.startSample > s1) continue;
      canvas.drawRect(Rect.fromLTRB(xOf(e.startSample), top, xOf(e.endSample), h - bottom), afPaint);
    }
    final noisePaint = Paint()..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.07);
    for (final n in a.noisy) {
      if (n[1] < s0 || n[0] > s1) continue;
      canvas.drawRect(Rect.fromLTRB(xOf(n[0]), top, xOf(n[1]), h - bottom), noisePaint);
    }

    // Skala pionowa: typowa amplituda R w widoku (odporna na artefakty).
    final b0 = a.beatIndexAtOrAfter(s0), b1 = a.beatIndexAtOrAfter(s1);
    final amps = <double>[for (var k = b0; k < b1; k++) signal[a.rPeaks[k]].abs()]..sort();
    final typical = amps.isEmpty ? 1000.0 : amps[amps.length ~/ 2];
    final rangeUv = max(800.0, typical * 1.5);
    final pxPerUv = plotH / 2 / rangeUv;

    // Siatka jak na papierze EKG: 0.2 s / 0.5 mV (duże), 0.04 s / 0.1 mV (małe).
    final minor = Paint()..color = palette.gridMinor..strokeWidth = 0.5;
    final major = Paint()..color = palette.gridMajor..strokeWidth = 0.8;
    final pxPerSec = w / span * fs;
    final minorStep = pxPerSec * 0.04 >= 4 ? 0.04 : (pxPerSec * 0.2 >= 4 ? 0.2 : 1.0);
    final firstLine = ((start / fs) / minorStep).floor();
    for (var k = firstLine;; k++) {
      final t = k * minorStep;
      final x = xOf(t * fs);
      if (x > w) break;
      if (x < 0) continue;
      final isMajor = (t / 0.2 - (t / 0.2).round()).abs() < 1e-6;
      canvas.drawLine(Offset(x, top), Offset(x, h - bottom), isMajor ? major : minor);
    }
    final uvStep = pxPerUv * 100 >= 4 ? 100 : 500;
    for (var uv = 0; uv <= rangeUv; uv += uvStep) {
      final p = uv % 500 == 0 ? major : minor;
      canvas.drawLine(Offset(0, midY - uv * pxPerUv), Offset(w, midY - uv * pxPerUv), p);
      canvas.drawLine(Offset(0, midY + uv * pxPerUv), Offset(w, midY + uv * pxPerUv), p);
    }

    // Przebieg (decymacja min/max na piksel przy dużej skali).
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, top, w, h - bottom));
    final trace = Paint()
      ..color = palette.trace
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final seg = a.timeline.segments;
    final samplesPerPx = span / w;
    for (final sg in seg) {
      final from = max(s0, sg.start), to = min(s1, sg.end);
      if (to - from < 2) continue;
      final path = Path();
      if (samplesPerPx <= 1.5) {
        path.moveTo(xOf(from), midY - signal[from] * pxPerUv);
        for (var i = from + 1; i < to; i++) {
          path.lineTo(xOf(i), midY - signal[i] * pxPerUv);
        }
      } else {
        var i = from;
        var first = true;
        while (i < to) {
          final px = xOf(i).floor();
          var mn = double.infinity, mx = -double.infinity;
          while (i < to && xOf(i).floor() == px) {
            mn = min(mn, signal[i]);
            mx = max(mx, signal[i]);
            i++;
          }
          if (first) {
            path.moveTo(px.toDouble(), midY - mx * pxPerUv);
            first = false;
          } else {
            path.lineTo(px.toDouble(), midY - mx * pxPerUv);
          }
          path.lineTo(px.toDouble(), midY - mn * pxPerUv);
        }
      }
      canvas.drawPath(path, trace);
    }
    canvas.restore();

    // Przerwy w transmisji.
    final gapPaint = Paint()..color = scheme.error..strokeWidth = 1.5;
    for (var k = 1; k < seg.length; k++) {
      final x = xOf(seg[k].start);
      if (x < 0 || x > w) continue;
      for (var y = top; y < h - bottom; y += 8) {
        canvas.drawLine(Offset(x, y), Offset(x, y + 4), gapPaint);
      }
      _text(canvas, 'przerwa', Offset(x + 3, top + 2), scheme.error, 10);
    }

    // Pobudzenia: litera nad szczytem, RR między pobudzeniami.
    final showRr = span <= 15 * fs;
    for (var k = b0; k < b1; k++) {
      final x = xOf(a.rPeaks[k]);
      final corr = corrections[a.rPeaks[k]];
      final l = corr == null || corr > 3 ? a.labels[k] : corr;
      final color = corr == 9 ? scheme.error : beatColor(l, scheme);
      final letter = corr == 9 ? '×' : (a.inAf[k] == 1 && l == BeatType.normal ? 'A' : BeatType.letters[l]);
      if (l != BeatType.normal || a.inAf[k] == 1 || span <= 20 * fs || corr != null) {
        _text(canvas, letter, Offset(x - 4, 3), color, 12, bold: l != BeatType.normal);
      }
      if (corr != null) {
        canvas.drawRRect(RRect.fromLTRBR(x - 7, 1, x + 8, 19, const Radius.circular(3)),
            Paint()..color = scheme.primary..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }
      if (showRr && k > 0 && a.timeline.segmentIndexOf(a.rPeaks[k - 1]) == a.timeline.segmentIndexOf(a.rPeaks[k])) {
        final rr = ((a.rPeaks[k] - a.rPeaks[k - 1]) * 1000 / fs).round();
        _text(canvas, '$rr', Offset((x + xOf(a.rPeaks[k - 1])) / 2 - 10, h - bottom + 2), scheme.onSurfaceVariant, 10);
      }
    }

    // Poprawki dodające uderzenie (bez wykrytego R w pobliżu).
    for (final e in corrections.entries) {
      if (e.key < s0 || e.key > s1 || e.value > 3) continue;
      final k = a.beatIndexAtOrAfter(e.key - 4);
      if (k < a.rPeaks.length && (a.rPeaks[k] - e.key).abs() <= 4) continue;
      final x = xOf(e.key);
      canvas.drawLine(Offset(x, top), Offset(x, h - bottom), Paint()..color = scheme.primary..strokeWidth = 1);
      _text(canvas, '+${BeatType.letters[e.value]}', Offset(x - 6, 3), scheme.primary, 12, bold: true);
    }

    // Znaczniki objawów.
    for (final e in markers.entries) {
      if (e.key < s0 || e.key > s1) continue;
      final x = xOf(e.key);
      final p = Paint()..color = palette.symptom..strokeWidth = 2;
      canvas.drawLine(Offset(x, top), Offset(x, h - bottom), p);
      _text(canvas, '⚑ ${e.value}', Offset(x + 3, top + 14), palette.symptom, 11, bold: true);
    }

    // Godzina początku widoku i skala.
    final tStart = a.timeline.timeOf(max(0, start));
    _text(canvas, fmtClock(tStart), Offset(w - 62, 3), scheme.onSurfaceVariant, 11);
    final bar = 1000 * pxPerUv;
    canvas.drawLine(Offset(6, midY + bar / 2), Offset(6, midY - bar / 2), major..strokeWidth = 2);
    _text(canvas, '1 mV', Offset(10, midY - bar / 2), major.color, 10);
  }

  void _text(Canvas c, String s, Offset o, Color color, double size, {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _StripPainter old) =>
      old.start != start ||
      old.span != span ||
      old.signal != signal ||
      old.a != a ||
      old.dark != dark ||
      old.corrections != corrections ||
      old.markers != markers;
}

Color beatColor(int label, ColorScheme scheme) => switch (label) {
      BeatType.ventricular => AppColors.light.beatV,
      BeatType.supraventricular => AppColors.light.beatS,
      BeatType.unknown => scheme.outline,
      _ => scheme.onSurfaceVariant,
    };

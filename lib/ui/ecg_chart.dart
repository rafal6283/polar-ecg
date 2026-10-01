import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app_controller.dart';
import '../ble/polar_protocol.dart';

/// Przesuwający się wykres EKG na siatce jak na papierze (0.2 s / 0.5 mV duże kratki).
///
/// H10 wysyła ramki po ~73 próbki (~0.56 s), więc wyświetlanie jest opóźnione
/// o ~0.7 s i animowane z prędkością 130 próbek/s – przesuw jest płynny.
class EcgChart extends StatefulWidget {
  final EcgBuffer buffer;
  final double seconds;

  const EcgChart({super.key, required this.buffer, this.seconds = 5});

  @override
  State<EcgChart> createState() => _EcgChartState();
}

class _EcgChartState extends State<EcgChart> with SingleTickerProviderStateMixin {
  static const _latency = ecgSampleRate * 0.7;
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  double _head = 0; // indeks próbki na prawej krawędzi wykresu
  double _range = 1000; // połowa zakresu osi Y w µV (autoskala)

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration now) {
    final dt = (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    final total = widget.buffer.total.toDouble();
    final target = total - _latency;
    _head += dt * ecgSampleRate;
    if ((target - _head).abs() > ecgSampleRate) _head = target; // resynchronizacja
    _head = min(_head, total);
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = (widget.seconds * ecgSampleRate).round();
    final end = _head.floor();
    final start = max(0, end - n);
    final buf = widget.buffer;

    // Autoskala: co najmniej ±1 mV, wygładzona żeby nie skakała.
    var peak = 1000.0;
    for (var i = max(start, end - EcgBuffer.capacity + 1); i < end; i++) {
      peak = max(peak, buf.at(i).abs());
    }
    final wanted = (peak * 1.15 / 500).ceil() * 500.0;
    _range += (wanted - _range) * 0.05;

    return CustomPaint(
      painter: _EcgPainter(
        buffer: buf,
        start: start,
        end: end,
        windowSamples: n,
        rangeUv: _range,
        dark: Theme.of(context).brightness == Brightness.dark,
      ),
      size: Size.infinite,
    );
  }
}

class _EcgPainter extends CustomPainter {
  final EcgBuffer buffer;
  final int start, end, windowSamples;
  final double rangeUv;
  final bool dark;

  _EcgPainter({
    required this.buffer,
    required this.start,
    required this.end,
    required this.windowSamples,
    required this.rangeUv,
    required this.dark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bg = dark ? const Color(0xFF1A1414) : const Color(0xFFFFF7F5);
    final minor = dark ? const Color(0xFF3A2626) : const Color(0xFFF6D3CC);
    final major = dark ? const Color(0xFF5E3434) : const Color(0xFFE8A196);
    final trace = dark ? const Color(0xFFE8E8E8) : const Color(0xFF111111);

    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    final pxPerSample = size.width / windowSamples;
    final pxPerSecond = pxPerSample * ecgSampleRate;
    final pxPerUv = size.height / (2 * rangeUv);
    final midY = size.height / 2;

    // Siatka: 0.04 s × 0.1 mV (małe), 0.2 s × 0.5 mV (duże). Przesuwa się razem z zapisem.
    final minorP = Paint()..color = minor..strokeWidth = 0.5;
    final majorP = Paint()..color = major..strokeWidth = 1;
    final offsetSec = (end / ecgSampleRate) % 0.2;
    for (var k = 0;; k++) {
      final x = size.width - (offsetSec + k * 0.04) * pxPerSecond;
      if (x < 0) break;
      final isMajor = k % 5 == 0;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), isMajor ? majorP : minorP);
    }
    for (var k = 0;; k++) {
      final dy = k * 100 * pxPerUv;
      if (dy > midY) break;
      final p = k % 5 == 0 ? majorP : minorP;
      canvas.drawLine(Offset(0, midY - dy), Offset(size.width, midY - dy), p);
      canvas.drawLine(Offset(0, midY + dy), Offset(size.width, midY + dy), p);
    }

    if (end <= start) return;
    final path = Path();
    for (var i = start; i < end; i++) {
      final x = size.width - (end - 1 - i) * pxPerSample;
      final y = midY - buffer.at(i) * pxPerUv;
      if (i == start) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = trace
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // Skala: 1 mV.
    final tp = TextPainter(
      text: TextSpan(text: '1 mV', style: TextStyle(color: major, fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout();
    final barH = 1000 * pxPerUv;
    final bp = Paint()..color = major..strokeWidth = 2;
    canvas.drawLine(Offset(8, midY + barH / 2), Offset(8, midY - barH / 2), bp);
    tp.paint(canvas, Offset(12, midY - barH / 2));
  }

  @override
  bool shouldRepaint(covariant _EcgPainter old) => true;
}

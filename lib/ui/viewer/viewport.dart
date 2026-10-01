import 'package:flutter/foundation.dart';

/// Widoczny fragment zapisu (w próbkach), współdzielony przez wykres EKG i tachogram.
class EcgViewport extends ChangeNotifier {
  final int totalSamples;
  final int sampleRate;
  double _start = 0;
  double _span;

  EcgViewport({required this.totalSamples, required this.sampleRate, double seconds = 10})
      : _span = seconds * sampleRate;

  double get start => _start;
  double get span => _span;
  double get end => _start + _span;
  double get center => _start + _span / 2;

  double get minSpan => 2.5 * sampleRate;
  double get maxSpan => 60.0 * sampleRate;

  void set(double start, [double? span]) {
    final sp = (span ?? _span).clamp(minSpan, maxSpan).toDouble();
    final st = start.clamp(0, (totalSamples - sp).clamp(0, double.infinity)).toDouble();
    if (st == _start && sp == _span) return;
    _start = st;
    _span = sp;
    notifyListeners();
  }

  void centerOn(num sample, {double? span}) {
    final sp = span ?? _span;
    set(sample - sp / 2, sp);
  }

  /// Zmiana skali z zachowaniem próbki pod punktem [focusFrac] (0..1 szerokości).
  void zoom(double newSpan, double focusFrac) {
    final focus = _start + focusFrac * _span;
    final sp = newSpan.clamp(minSpan, maxSpan).toDouble();
    set(focus - focusFrac * sp, sp);
  }
}

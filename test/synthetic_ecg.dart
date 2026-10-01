import 'dart:math';
import 'dart:typed_data';

import 'package:polar_ecg/analysis/ecg_recording.dart';

/// Generator syntetycznego EKG (suma funkcji Gaussa) ze znanymi pozycjami i typami pobudzeń.
class SyntheticEcg {
  static const fs = 130;
  final Random rnd;
  final List<double> beatTimes = []; // s
  final List<String> beatTypes = []; // N, S, V, A (N w AF)
  final List<List<double>> noiseBursts = []; // [t0, t1] s
  double _t = 1.0;

  SyntheticEcg({int seed = 1}) : rnd = Random(seed);

  double get time => _t;

  void sinus(double seconds, {double bpm = 70, double rsa = 0.04}) {
    final end = _t + seconds;
    final rr0 = 60 / bpm;
    while (_t < end) {
      _add('N');
      _t += rr0 * (1 + rsa * sin(2 * pi * _t / 4.5)) * (1 + 0.01 * _gauss());
    }
  }

  /// Rytm zatokowy z co k-tym pobudzeniem komorowym (przedwczesnym z pauzą wyrównawczą).
  void withPvcs(double seconds, {double bpm = 70, int every = 8}) {
    final end = _t + seconds;
    final rr = 60 / bpm;
    var k = 0;
    while (_t < end) {
      k++;
      if (k % every == 0) {
        _t -= rr * 0.35; // przedwczesne
        _add('V');
        _t += rr * 1.7; // pauza wyrównawcza
      } else {
        _add('N');
        _t += rr * (1 + 0.01 * _gauss());
      }
    }
  }

  void withPacs(double seconds, {double bpm = 70, int every = 9}) {
    final end = _t + seconds;
    final rr = 60 / bpm;
    var k = 0;
    while (_t < end) {
      k++;
      if (k % every == 0) {
        _t -= rr * 0.33;
        _add('S');
        _t += rr * 1.05;
      } else {
        _add('N');
        _t += rr * (1 + 0.01 * _gauss());
      }
    }
  }

  void af(double seconds) {
    final end = _t + seconds;
    while (_t < end) {
      _add('A');
      _t += 0.4 + rnd.nextDouble() * 0.7;
    }
  }

  void pause(double seconds) => _t += seconds - 0.85;

  void noise(double seconds) {
    noiseBursts.add([_t, _t + seconds]);
    sinus(seconds);
  }

  void _add(String type) {
    beatTimes.add(_t);
    beatTypes.add(type);
  }

  double _gauss() {
    final u = max(1e-12, rnd.nextDouble()), v = rnd.nextDouble();
    return sqrt(-2 * log(u)) * cos(2 * pi * v);
  }

  Float32List render() {
    final n = ((_t + 1.5) * fs).ceil();
    final x = Float64List(n);
    void g(double center, double amp, double sigma) {
      final c = center * fs, s = sigma * fs;
      for (var i = max(0, (c - 5 * s).floor()); i < min(n, (c + 5 * s).ceil()); i++) {
        final d = (i - c) / s;
        x[i] += amp * exp(-0.5 * d * d);
      }
    }

    for (var b = 0; b < beatTimes.length; b++) {
      final t = beatTimes[b];
      switch (beatTypes[b]) {
        case 'V':
          g(t, 1600, 0.035);
          g(t + 0.07, -500, 0.03);
          g(t + 0.3, -450, 0.06);
        case 'A':
          g(t - 0.03, -100, 0.01);
          g(t, 1200, 0.012);
          g(t + 0.03, -250, 0.012);
          g(t + 0.25, 280, 0.05);
        default: // N, S – ta sama morfologia QRS (S: inny załamek P)
          g(t - 0.2, beatTypes[b] == 'S' ? -80 : 110, 0.025);
          g(t - 0.03, -100, 0.01);
          g(t, 1200, 0.012);
          g(t + 0.03, -250, 0.012);
          g(t + 0.25, 300, 0.05);
      }
    }
    for (var i = 0; i < n; i++) {
      final t = i / fs;
      x[i] += 200 * sin(2 * pi * 0.25 * t) + 15 * _gauss() + 300; // dryf linii + szum + offset
      // Fale migotania w AF są w sygnale tylko pośrednio (brak P); szum mięśniowy:
      for (final nb in noiseBursts) {
        if (t >= nb[0] && t < nb[1]) x[i] += 600 * _gauss();
      }
    }
    return Float32List.fromList(x);
  }

  Timeline timeline(int length) => Timeline(DateTime(2026, 1, 1, 8), fs, [Segment(0, length, 0)]);
}

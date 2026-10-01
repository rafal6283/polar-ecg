import 'dart:math';
import 'dart:typed_data';

/// Sekcja bikwadratowa (RBJ Audio EQ Cookbook), postać transponowana II.
class Biquad {
  final double b0, b1, b2, a1, a2;

  const Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory Biquad._norm(double b0, double b1, double b2, double a0, double a1, double a2) =>
      Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);

  factory Biquad.lowpass(double fc, double fs, {double q = 0.7071}) {
    final w = 2 * pi * fc / fs, c = cos(w), al = sin(w) / (2 * q);
    return Biquad._norm((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al);
  }

  factory Biquad.highpass(double fc, double fs, {double q = 0.7071}) {
    final w = 2 * pi * fc / fs, c = cos(w), al = sin(w) / (2 * q);
    return Biquad._norm((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
  }

  factory Biquad.notch(double f0, double fs, {double q = 8}) {
    final w = 2 * pi * f0 / fs, c = cos(w), al = sin(w) / (2 * q);
    return Biquad._norm(1, -2 * c, 1, 1 + al, -2 * c, 1 - al);
  }

  void forward(Float64List x) {
    double z1 = 0, z2 = 0;
    for (var i = 0; i < x.length; i++) {
      final v = x[i];
      final y = b0 * v + z1;
      z1 = b1 * v - a1 * y + z2;
      z2 = b2 * v - a2 * y;
      x[i] = y;
    }
  }

  void backward(Float64List x) {
    double z1 = 0, z2 = 0;
    for (var i = x.length - 1; i >= 0; i--) {
      final v = x[i];
      final y = b0 * v + z1;
      z1 = b1 * v - a1 * y + z2;
      z2 = b2 * v - a2 * y;
      x[i] = y;
    }
  }
}

/// Filtracja dwukierunkowa (zerowe przesunięcie fazy) w miejscu.
void filtfilt(Float64List x, List<Biquad> sections) {
  for (final s in sections) {
    s.forward(x);
  }
  for (final s in sections) {
    s.backward(x);
  }
}

/// Filtracja dwukierunkowa fragmentu [start, end) sygnału, blokami,
/// żeby nie alokować pamięci na cały (np. 24-godzinny) zapis.
/// Poza granicami fragmentu sygnał jest przedłużany odbiciem nieparzystym.
void filtfiltRange(
  Float32List src,
  Float32List dst,
  int start,
  int end,
  List<Biquad> sections, {
  required int pad,
  int block = 1 << 15,
}) {
  if (end <= start) return;
  final buf = Float64List(block + 2 * pad);
  for (var cs = start; cs < end; cs += block) {
    final ce = min(cs + block, end);
    final a = cs - pad, b = ce + pad;
    final n = b - a;
    final view = Float64List.sublistView(buf, 0, n);
    for (var i = 0; i < n; i++) {
      view[i] = _ext(src, a + i, start, end);
    }
    filtfilt(view, sections);
    for (var i = cs; i < ce; i++) {
      dst[i] = view[i - a];
    }
  }
}

double _ext(Float32List s, int i, int start, int end) {
  if (i < start) {
    final r = min(2 * start - i, end - 1);
    return 2 * s[start] - s[r];
  }
  if (i >= end) {
    final r = max(2 * (end - 1) - i, start);
    return 2 * s[end - 1] - s[r];
  }
  return s[i];
}

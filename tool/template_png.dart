// Rysuje uśredniony zespół z punktami pomiarowymi: dart run tool/template_png.dart <katalog_zapisu>
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:polar_ecg/analysis/analyzer.dart';

import 'png.dart';

Future<void> main(List<String> args) async {
  final a = (await loadAnalysis(args.first))!;
  final t = a.template!;
  final fs = a.sampleRate;
  const w = 900, h = 400;
  final img = Img(w, h);
  double msOf(int k) => (k - a.templatePre) * 1000 / fs;
  int x(double ms) => ((ms + 300) / 900 * (w - 1)).round();
  final base = (a.stats['m_base_uv'] ?? 0).toDouble();
  int y(double uv) => (h / 2 - (uv - base) / 1500 * (h / 2)).round().clamp(0, h - 1);
  for (var ms = -300.0; ms <= 600; ms += 40) {
    img.vline(x(ms), 0, h - 1, ms % 200 == 0 ? const [232, 161, 150] : const [246, 211, 204]);
  }
  img.hline(0, w - 1, y(base), const [150, 150, 150]);
  for (var k = 1; k < t.length; k++) {
    img.line(x(msOf(k - 1)), y(t[k - 1]), x(msOf(k)), y(t[k]), const [17, 17, 17]);
  }
  const marks = {
    'm_p_on': [0, 150, 0],
    'm_qrs_on': [0, 0, 220],
    'm_j': [220, 0, 220],
    'm_t_peak': [255, 140, 0],
    'm_t_end': [220, 0, 0],
  };
  marks.forEach((k, col) {
    final v = a.stats[k];
    if (v == null) return;
    for (var dx = -1; dx <= 1; dx++) {
      img.vline(x(v.toDouble()) + dx, 0, h - 1, col);
    }
    print('$k = ${v.toStringAsFixed(1)} ms');
  });
  File('${args.first}/template.png').writeAsBytesSync(img.png());
  print('${args.first}/template.png');
}

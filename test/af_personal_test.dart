import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/af_personal.dart';
import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';

void main() {
  test('AfWindow.isAf – reguła głosowania jak w analizie', () {
    expect(const AfWindow(0, 10, true, -0.5, null).isAf(-1.0, 0.5), isTrue);
    expect(const AfWindow(0, 10, true, -1.5, null).isAf(-1.0, 0.5), isFalse);
    expect(const AfWindow(0, 10, false, -1.5, 0.2).isAf(-1.0, 0.5), isFalse);
    expect(const AfWindow(0, 10, true, -1.5, 0.2).isAf(-1.0, 0.5), isTrue);
    final w = AfWindow.fromJson(const AfWindow(5, 9, true, -0.8123, 0.4).toJson())!;
    expect((w.start, w.end, w.dash, w.cosen, w.pCorr), (5, 9, true, -0.812, 0.4));
  });

  test('dopasowanie progów do oznaczeń', () {
    // Napady: nieregularne, ale z umiarkowanym COSEn (-1.3) i brakiem P; fałszywe alarmy: Dash + COSEn -0.9, P obecne.
    final windows = <AfWindow>[];
    for (var i = 0; i < 20; i++) {
      windows.add(AfWindow(i * 100, i * 100 + 90, true, -1.3, 0.3)); // AF (domyślnie wykryte 2/3 głosów)
    }
    for (var i = 20; i < 40; i++) {
      windows.add(AfWindow(i * 100, i * 100 + 90, true, -0.9, 0.62)); // nie AF, domyślnie wykryte (Dash + COSEn)
    }
    for (var i = 40; i < 200; i++) {
      windows.add(AfWindow(i * 100, i * 100 + 90, false, -1.8, 0.8)); // zwykły rytm
    }
    final marks = [const AfMark(0, 1990, true), const AfMark(2000, 3990, false)];
    final data = labelWindows(windows, marks);
    expect(data.where((x) => x.$2).length, 20);
    expect(data.where((x) => !x.$2).length, 20);
    final bg = backgroundWindows(windows, marks, 300);
    expect(bg, isNotEmpty);
    final fit = fitAfThresholds(data, background: bg, recordings: 1, marksAf: 1, marksNo: 1);
    expect(fit.accepted, isTrue, reason: fit.reason);
    expect(fit.defaultScore, closeTo(0.5, 1e-9));
    expect(fit.bestScore, closeTo(1.0, 1e-9));
    // fałszywe alarmy odrzucone przez wymaganie braku P (P 0.62 ≥ próg), napady nadal wykryte
    expect(fit.pCorr, lessThanOrEqualTo(0.6));
    for (final (w, af) in data) {
      expect(w.isAf(fit.cosen, fit.pCorr), af);
    }
  });

  test('za mało oznaczeń – progi domyślne', () {
    final data = [for (var i = 0; i < 5; i++) (AfWindow(i, i + 1, true, -0.5, 0.2), true)];
    final fit = fitAfThresholds(data, recordings: 1, marksAf: 1, marksNo: 0);
    expect(fit.accepted, isFalse);
    const d = AnalysisSettings();
    expect((fit.cosen, fit.pCorr), (d.afCosen, d.afPCorr));
  });
}

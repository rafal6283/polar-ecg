import 'dart:convert';
import 'dart:io';

import 'analysis_result.dart';
import 'analyzer.dart';

/// Wynik dopasowania progów wykrywania AF do oznaczeń użytkownika.
class AfFit {
  final int recordings; // zapisy z oznaczeniami i oknami
  final int marksAf, marksNo; // oznaczenia: napad / to nie AF
  final int posWindows, negWindows; // okna analizy pod oznaczeniami
  final double defaultScore; // zrównoważona trafność przy progach domyślnych
  final double bestScore;
  final double cosen, pCorr; // najlepsze progi
  final String? reason; // dlaczego nie przyjęto (null = przyjęto)

  const AfFit({
    required this.recordings,
    required this.marksAf,
    required this.marksNo,
    required this.posWindows,
    required this.negWindows,
    required this.defaultScore,
    required this.bestScore,
    required this.cosen,
    required this.pCorr,
    this.reason,
  });

  bool get accepted => reason == null;
}

/// Okno z etykietą z ręcznego oznaczenia.
typedef LabeledWindow = (AfWindow w, bool af);

/// Minimalne liczby, poniżej których nie zmieniamy progów.
const afFitMinWindows = 10;
const afFitMinGain = 0.05;

/// Okna bez oznaczeń, z dala (≥ [gap] próbek) od oznaczeń AF, których progi domyślne nie uznają za AF –
/// zapis był przejrzany, więc to zwykły rytm. Służą jako hamulec: dopasowane progi nie mogą zwiększyć
/// liczby fałszywych okien AF w zwykłym rytmie o więcej niż [afFitMaxBgRise].
List<AfWindow> backgroundWindows(List<AfWindow> windows, List<AfMark> marks, int gap) {
  const d = AnalysisSettings();
  return [
    for (final w in windows)
      if (!w.isAf(d.afCosen, d.afPCorr) && !marks.any((m) => m.overlaps(w.start - gap, w.end + gap))) w
  ];
}

const afFitMaxBgRise = 0.01;

/// Okna nakładające się na oznaczenia (oznaczenie musi pokrywać ≥ połowę okna).
List<LabeledWindow> labelWindows(List<AfWindow> windows, List<AfMark> marks) {
  final out = <LabeledWindow>[];
  for (final w in windows) {
    final len = w.end - w.start;
    if (len <= 0) continue;
    for (final m in marks) {
      final ov = (w.end < m.end ? w.end : m.end) - (w.start > m.start ? w.start : m.start);
      if (ov * 2 >= len) {
        out.add((w, m.af));
        break;
      }
    }
  }
  return out;
}

double _balanced(List<LabeledWindow> data, double cosen, double pCorr) {
  var tp = 0, fn = 0, tn = 0, fp = 0;
  for (final (w, af) in data) {
    final d = w.isAf(cosen, pCorr);
    if (af) {
      d ? tp++ : fn++;
    } else {
      d ? fp++ : tn++;
    }
  }
  final se = tp + fn == 0 ? 0.0 : tp / (tp + fn);
  final sp = tn + fp == 0 ? 0.0 : tn / (tn + fp);
  return (se + sp) / 2;
}

/// Przeszukanie siatki progów (afCosen −1.6…−0.4, afPCorr 0.30…0.70) – zrównoważona trafność
/// (czułość i swoistość po równo), z ograniczeniem fałszywych AF w zwykłym rytmie ([background]). Przy remisie wygrywają progi bliższe domyślnym.
AfFit fitAfThresholds(List<LabeledWindow> data,
    {List<AfWindow> background = const [], int recordings = 0, int marksAf = 0, int marksNo = 0}) {
  const d = AnalysisSettings();
  final pos = data.where((x) => x.$2).length;
  final neg = data.length - pos;
  final def = _balanced(data, d.afCosen, d.afPCorr);
  var best = def, bc = d.afCosen, bp = d.afPCorr;
  var bestDist = 0.0;
  for (var i = 0; i <= 12; i++) {
    final c = -1.6 + i * 0.1;
    for (var j = 0; j <= 8; j++) {
      final p = 0.30 + j * 0.05;
      if (background.isNotEmpty &&
          background.where((w) => w.isAf(c, p)).length > background.length * afFitMaxBgRise) {
        continue;
      }
      final s = _balanced(data, c, p);
      final dist = (c - d.afCosen).abs() + (p - d.afPCorr).abs() * 2;
      if (s > best + 1e-9 || ((s - best).abs() <= 1e-9 && dist < bestDist)) {
        best = s;
        bc = double.parse(c.toStringAsFixed(2));
        bp = double.parse(p.toStringAsFixed(2));
        bestDist = dist;
      }
    }
  }
  String? reason;
  if (marksAf == 0 || marksNo == 0) {
    reason = 'Potrzebne oznaczenia obu rodzajów: potwierdzone napady i odrzucone („to nie AF”).';
  } else if (pos < afFitMinWindows || neg < afFitMinWindows) {
    reason = 'Za mało danych: $pos okien z AF i $neg bez AF (potrzeba po $afFitMinWindows).';
  } else if (best - def < afFitMinGain) {
    reason = 'Progi domyślne pasują do Twoich oznaczeń (zysk < ${(afFitMinGain * 100).round()} pkt).';
  }
  return AfFit(
    recordings: recordings,
    marksAf: marksAf,
    marksNo: marksNo,
    posWindows: pos,
    negWindows: neg,
    defaultScore: def,
    bestScore: best,
    cosen: reason == null ? bc : d.afCosen,
    pCorr: reason == null ? bp : d.afPCorr,
    reason: reason,
  );
}

Future<List<AfWindow>?> loadAfWindows(String path) async {
  final f = File('$path/$afWindowsFile');
  if (!await f.exists()) return null;
  try {
    return [for (final j in jsonDecode(await f.readAsString()) as List) AfWindow.fromJson(j)].whereType<AfWindow>().toList();
  } catch (_) {
    return null;
  }
}

/// Zbiera okna z oznaczonych zapisów w [root] (katalog zapisów) i dopasowuje progi.
/// Zapisy z oznaczeniami, ale bez `af_windows.json` (analizowane starszą wersją), są analizowane
/// ponownie przez [reanalyze] (np. w izolacie).
Future<AfFit> fitFromRecordings(Directory root, {Future<void> Function(String path)? reanalyze}) async {
  final data = <LabeledWindow>[];
  final bg = <AfWindow>[];
  var recs = 0, mAf = 0, mNo = 0;
  if (await root.exists()) {
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final marks = await loadAfMarks(e.path);
      if (marks.isEmpty) continue;
      var w = await loadAfWindows(e.path);
      if (w == null && reanalyze != null) {
        try {
          await reanalyze(e.path);
          w = await loadAfWindows(e.path);
        } catch (_) {}
      }
      if (w == null) continue;
      recs++;
      for (final m in marks) {
        m.af ? mAf++ : mNo++;
      }
      data.addAll(labelWindows(w, marks));
      bg.addAll(backgroundWindows(w, marks, 130 * 300)); // 5 min przy 130 Hz
    }
  }
  return fitAfThresholds(data, background: bg, recordings: recs, marksAf: mAf, marksNo: mNo);
}

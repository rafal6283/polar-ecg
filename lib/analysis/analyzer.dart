import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'analysis_result.dart';
import 'beat_model.g.dart';
import 'ecg_recording.dart';
import 'filters.dart';
import 'mlp.dart';
import 'morphology.dart';
import 'personal_profile.dart';
import 'qrs_detector.dart';

part 'beat_features.dart';
part 'rhythms.dart';
part 'st_trend.dart';

/// Klasyfikator pobudzeń (MLP) – null, jeśli model nie został jeszcze wytrenowany.
final Mlp? beatModel = beatModelJson.isEmpty ? null : Mlp.fromJson(jsonDecode(beatModelJson) as Map<String, dynamic>);

class AnalysisSettings {
  final double pauseSeconds;
  final double bradyBpm;
  final double tachyBpm;
  final double afMinSeconds;

  // Progi klasyfikacji (strojone na MIT-BIH DS1, oceniane na DS2).
  final double noiseIdxLimit; // wskaźnik szumu wokół pobudzenia
  final double noiseExclSec; // okno wykluczenia wokół R przy liczeniu szumu
  final double sPrematurity; // RR/lokalny RR poniżej => przedwczesne nadkomorowe
  final double vCorrHard, vCorrSoft, vWidthHard, vWidthSoft, vPrematurity;
  final double sPrevRatio, sNextRatio; // RR < sPrev×poprzedni i następny > sNext×bieżący => S
  final double vGroupCorr, vGroupMargin; // przypisanie do wzorca komorowego
  final bool useModel; // klasyfikator MLP zamiast reguł
  final bool collectFeatures; // zwróć cechy pobudzeń (uczenie modelu)
  final bool usePersonal; // profil osobisty (wzorce, k-NN z ręcznych poprawek)
  final double afVotes; // min. liczba głosów (Dash, COSEn, brak P) dla okna AF
  final double afPCorr; // mediana korelacji okolicy P poniżej => brak załamka P
  final double afCosen; // próg COSEn
  final double afGapSec; // łączenie epizodów AF rozdzielonych krótszą przerwą
  final double svtOnset; // nagły początek SVT: RR < svtOnset × mediana poprzednich (0 = wyłączone)
  final double svtMinBeats; // minimalna długość utrwalonego SVT (pobudzenia)
  final double avbCorr; // blok AV II°: korelacja zablokowanego P z wzorcem P (> 1 = wyłączone)
  final double avbMin; // blok AV II°: min. liczba zablokowanych P w odstępach < 60 s
  final double aflCorr; // trzepotanie: autokorelacja fal F (> 1 = wyłączone)
  final double stDevUv; // próg epizodu zmiany ST [µV] (0 = bez wykrywania)
  final double stSmooth; // wygładzanie trendu ST: mediana z ±n okien 10 s
  final double stMinSec; // minimalny czas epizodu ST
  final double rescueCorr; // odzysk uderzeń odrzuconych tylko przez wskaźnik szumu (0 = wyłączony)

  const AnalysisSettings({
    this.pauseSeconds = 2.0,
    this.bradyBpm = 40,
    this.tachyBpm = 120,
    this.afMinSeconds = 30,
    this.noiseIdxLimit = 0.024, // H10: czyste 0.005–0.018, zakłócenia ruchowe ≥ 0.027
    this.noiseExclSec = 0.15,
    this.sPrematurity = 0.85,
    this.vCorrHard = 0.7,
    this.vCorrSoft = 0.85,
    this.vWidthHard = 1.6,
    this.vWidthSoft = 1.35,
    this.vPrematurity = 0.85,
    this.sPrevRatio = 0.75,
    this.sNextRatio = 1.3,
    this.vGroupCorr = 0.85,
    this.vGroupMargin = 0.1,
    this.useModel = true,
    this.collectFeatures = false,
    this.usePersonal = true,
    // Strojone na afdb (oba odprowadzenia), sprawdzone na ltafdb (1961 h, odłożona): czas AF Se 89.3 -> 91.6%,
    // Sp 93.0 -> 93.2%, fałszywe epizody 25.5 -> 6.8 na dobę.
    this.afVotes = 2,
    this.afPCorr = 0.5,
    this.afCosen = -1.0,
    this.afGapSec = 60,
    this.svtOnset = 0.8,
    this.svtMinBeats = 5,
    // mitdb 231 (jedyny zapis z blokiem II°): 5/5 epizodów, 0 fałszywych; ltafdb (1960 h): 0.9 fałszywych/dobę.
    this.avbCorr = 0.9,
    this.avbMin = 3,
    // Wyłączone: na mitdb/afdb Se 7% (1/14 epizodów) przy 24 fałszywych/dobę w zgrubnym AF – fale F
    // rzadko widoczne w jednym odprowadzeniu 130 Hz. AFL ze zmiennym przewodzeniem wykrywa detektor AF,
    // AFL 2:1 – nagły częstoskurcz ~150/min. Do oceny: rhythm_eval.dart … AFL afl aflCorr=0.45.
    this.aflCorr = 2,
    this.stDevUv = 100,
    this.stSmooth = 2, // edb (połowa testowa): epizody Se 63% +P 66%
    this.stMinSec = 30,
    this.rescueCorr = 0.95,
  });

  AnalysisSettings copyWith(Map<String, double> v) => AnalysisSettings(
        pauseSeconds: v['pauseSeconds'] ?? pauseSeconds,
        bradyBpm: v['bradyBpm'] ?? bradyBpm,
        tachyBpm: v['tachyBpm'] ?? tachyBpm,
        afMinSeconds: v['afMinSeconds'] ?? afMinSeconds,
        noiseIdxLimit: v['noiseIdxLimit'] ?? noiseIdxLimit,
        noiseExclSec: v['noiseExclSec'] ?? noiseExclSec,
        sPrematurity: v['sPrematurity'] ?? sPrematurity,
        vCorrHard: v['vCorrHard'] ?? vCorrHard,
        vCorrSoft: v['vCorrSoft'] ?? vCorrSoft,
        vWidthHard: v['vWidthHard'] ?? vWidthHard,
        vWidthSoft: v['vWidthSoft'] ?? vWidthSoft,
        vPrematurity: v['vPrematurity'] ?? vPrematurity,
        sPrevRatio: v['sPrevRatio'] ?? sPrevRatio,
        sNextRatio: v['sNextRatio'] ?? sNextRatio,
        vGroupCorr: v['vGroupCorr'] ?? vGroupCorr,
        vGroupMargin: v['vGroupMargin'] ?? vGroupMargin,
        useModel: v.containsKey('useModel') ? v['useModel'] != 0 : useModel,
        collectFeatures: v.containsKey('collectFeatures') ? v['collectFeatures'] != 0 : collectFeatures,
        usePersonal: v.containsKey('usePersonal') ? v['usePersonal'] != 0 : usePersonal,
        afVotes: v['afVotes'] ?? afVotes,
        afPCorr: v['afPCorr'] ?? afPCorr,
        afCosen: v['afCosen'] ?? afCosen,
        afGapSec: v['afGapSec'] ?? afGapSec,
        svtOnset: v['svtOnset'] ?? svtOnset,
        svtMinBeats: v['svtMinBeats'] ?? svtMinBeats,
        avbCorr: v['avbCorr'] ?? avbCorr,
        avbMin: v['avbMin'] ?? avbMin,
        aflCorr: v['aflCorr'] ?? aflCorr,
        stDevUv: v['stDevUv'] ?? stDevUv,
        stSmooth: v['stSmooth'] ?? stSmooth,
        stMinSec: v['stMinSec'] ?? stMinSec,
        rescueCorr: v['rescueCorr'] ?? rescueCorr,
      );
}

class AnalysisOutput {
  final AnalysisResult result;
  final Float32List filtered;

  /// Cechy pobudzeń (gdy settings.collectFeatures) – indeksy jak result.rPeaks.
  final List<Float64List?>? features;

  /// Wzorzec prawidłowego pobudzenia (QRS i szeroki) – do profilu osobistego.
  final Float64List? normalTemplate, normalWideTemplate;

  /// Cechy i etykiety pobudzeń poprawionych ręcznie – przykłady do profilu.
  final List<Float64List> correctedFeatures;
  final List<int> correctedLabels;

  AnalysisOutput(
    this.result,
    this.filtered, [
    this.features,
  ]) : normalTemplate = null,
       normalWideTemplate = null,
       correctedFeatures = const [],
       correctedLabels = const [];

  AnalysisOutput.full(
    this.result,
    this.filtered,
    this.features, {
    this.normalTemplate,
    this.normalWideTemplate,
    this.correctedFeatures = const [],
    this.correctedLabels = const [],
  });
}

const analysisFile = 'analysis.json';
const summaryFile = 'summary.json';

/// Krótkie podsumowanie zapisu do trendów (szybkie wczytywanie wielu zapisów).
Map<String, dynamic> recordingSummary(AnalysisResult a) {
  const keys = [
    'duration_s', 'analyzed_s', 'hr_mean', 'hr_min', 'hr_max', 'hr_rest', 'rmssd_ms', 'sdnn_ms', 'pnn50_pct',
    'v_per_h', 's_per_h', 'af_burden_pct', 'qtc_ms', 'qrs_ms', 'pr_ms', 'longest_pause_s', 'beats',
  ];
  final s = a.stats.values;
  final h = a.timeline.started.hour;
  final dur = (s['duration_s'] ?? 0).toDouble();
  return {
    'version': AnalysisResult.version,
    'started': a.timeline.started.toIso8601String(),
    for (final k in keys) k: s[k],
    'events': a.events.length,
    'events_high': a.events.where((e) => e.severity == Severity.high).length,
    // Pomiar poranny: krótki (1–15 min) zapis rozpoczęty między 5:00 a 10:00.
    'morning': h >= 5 && h < 10 && dur >= 60 && dur <= 900,
  };
}
const filteredFile = 'ecg_filtered.f32';

/// Ręczne poprawki: próbka R → etykieta (BeatType) albo [correctionDelete].
const correctionsFile = 'corrections.json';
const correctionDelete = 9;

Future<Map<int, int>> loadCorrections(String path) async {
  final f = File('$path/$correctionsFile');
  if (!await f.exists()) return {};
  final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  return {for (final e in j.entries) int.parse(e.key): e.value as int};
}

Future<void> saveCorrections(String path, Map<int, int> c) =>
    File('$path/$correctionsFile').writeAsString(jsonEncode({for (final e in c.entries) '${e.key}': e.value}));

/// Pełna analiza zapisu z katalogu: wczytanie, analiza, zapis wyników obok danych.
/// Uwzględnia ręczne poprawki i profil osobisty; aktualizuje profil (wzorce, przykłady).
/// Funkcja najwyższego poziomu – można ją uruchomić w osobnym izolacie (Isolate.run).
Future<AnalysisResult> analyzeRecordingDir(String path, {AnalysisSettings settings = const AnalysisSettings()}) async {
  final dir = Directory(path);
  final rec = await EcgRecording.load(dir);
  final corrections = await loadCorrections(path);
  final profileFile = PersonalProfile.fileIn(dir.parent.parent);
  final profile = settings.usePersonal ? await PersonalProfile.load(profileFile) : null;
  final out = analyzeEcg(rec.uv, rec.timeline,
      settings: settings, profile: profile, corrections: corrections, activity: rec.activity);
  final f = out.filtered;
  await File('${dir.path}/$filteredFile').writeAsBytes(f.buffer.asUint8List(f.offsetInBytes, f.lengthInBytes));
  await File('${dir.path}/$analysisFile').writeAsString(jsonEncode(out.result.toJson()));
  await File('${dir.path}/$summaryFile').writeAsString(jsonEncode(recordingSummary(out.result)));

  // Nauka profilu: wzorce z dobrych zapisów, przykłady z ręcznych poprawek.
  if (settings.usePersonal) {
    final p = profile ?? PersonalProfile();
    var changed = false;
    final s = out.result.stats;
    final good = (s['n'] ?? 0) >= 200 && (s['q'] ?? 0) < 0.2 * (s['beats'] ?? 1);
    if (good && out.normalTemplate != null) {
      p.addTemplates(out.normalTemplate!, out.normalWideTemplate!);
      changed = true;
    }
    if (corrections.isNotEmpty) {
      p.setExamples(dir.uri.pathSegments.where((x) => x.isNotEmpty).last, out.correctedFeatures, out.correctedLabels);
      changed = true;
    }
    if (changed) await p.save(profileFile);
  }
  return out.result;
}

/// Wczytuje zapisane wyniki analizy (null, jeśli brak lub nieaktualna wersja).
Future<AnalysisResult?> loadAnalysis(String path) async {
  final af = File('$path/$analysisFile');
  if (!await af.exists() || !await File('$path/$filteredFile').exists()) return null;
  try {
    final j = jsonDecode(await af.readAsString()) as Map<String, dynamic>;
    if (j['version'] != AnalysisResult.version) return null;
    return AnalysisResult.fromJson(j);
  } catch (_) {
    return null;
  }
}

Future<Float32List> loadFiltered(String path) async {
  var bytes = await File('$path/$filteredFile').readAsBytes();
  // Widok Float32 wymaga wyrównania do 4 bajtów – w razie potrzeby kopiujemy.
  if (bytes.offsetInBytes % 4 != 0) bytes = Uint8List.fromList(bytes);
  return bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
}

/// Analiza w osobnym izolacie. Funkcja najwyższego poziomu – domknięcie
/// przechwytuje tylko ścieżkę (nie obiekty interfejsu, których nie da się przesłać).
Future<AnalysisResult> analyzeInBackground(String path, [AnalysisSettings settings = const AnalysisSettings()]) =>
    Isolate.run(() => analyzeRecordingDir(path, settings: settings));

/// Analiza sygnału w µV. Czysta funkcja – używana też w testach i narzędziu na PC.
///  [profile] – profil osobisty (wzorzec zastępczy, k-NN z poprawek),
///  [corrections] – ręczne poprawki (próbka R → etykieta / usunięcie / dodanie),
///  [activity] – aktywność z akcelerometru [mg] w oknach 2 s (jak maska szumu).
AnalysisOutput analyzeEcg(
  Float32List raw,
  Timeline tl, {
  AnalysisSettings settings = const AnalysisSettings(),
  PersonalProfile? profile,
  Map<int, int>? corrections,
  Float32List? activity,
}) {
  final fs = tl.sampleRate;
  final corr = corrections ?? const <int, int>{};

  // 1. Filtracja 0.5–40 Hz + 50 Hz, bez przesunięcia fazy.
  final filtered = Float32List(raw.length);
  final sections = [
    Biquad.highpass(0.5, fs.toDouble()),
    Biquad.lowpass(40, fs.toDouble()),
    Biquad.notch(50, fs.toDouble()),
  ];
  for (final s in tl.segments) {
    filtfiltRange(raw, filtered, s.start, s.end, sections, pad: fs * 5);
  }

  // 2. Jakość sygnału w oknach 2 s.
  final noiseWin = 2 * fs;
  final noisyMask = _noiseMask(filtered, noiseWin);

  // 3. Detekcja QRS w każdym ciągłym fragmencie + ręczne usunięcia/dodania.
  final detector = QrsDetector(fs);
  var peaks = <int>[];
  for (final s in tl.segments) {
    peaks.addAll(detector.detect(filtered, s.start, s.end));
  }
  if (corr.isNotEmpty) peaks = _applyPeakCorrections(peaks, corr, raw.length);
  final beatSeg = [for (final p in peaks) tl.segmentIndexOf(p)];

  // 4. Klasyfikacja; znaczniki uznane za artefakty usuwamy i klasyfikujemy ponownie
  //    (poza pobudzeniami poprawionymi ręcznie).
  final keepSamples = corr.keys.toSet();
  _Ctx make(List<int> r, List<int> sg) => _Ctx(fs, filtered, Int32List.fromList(r), Int32List.fromList(sg),
      noisyMask, noiseWin, tl, settings, profile: profile, activity: activity);
  var ctx = make(peaks, beatSeg)..classify();
  for (var pass = 0; pass < 2; pass++) {
    final drop = ctx.artifactBeats()..removeWhere((i) => keepSamples.contains(ctx.r[i]));
    if (drop.isEmpty) break;
    final keep = [for (var i = 0; i < ctx.n; i++) if (!drop.contains(i)) i];
    ctx = make([for (final i in keep) ctx.r[i]], [for (final i in keep) ctx.seg[i]])..classify();
  }
  final r = ctx.r;
  final n = r.length;

  // 5. Etykiety z poprawek mają pierwszeństwo.
  final corrFeatures = <Float64List>[];
  final corrLabels = <int>[];
  for (final e in corr.entries) {
    if (e.value == correctionDelete) continue;
    final k = _nearestBeat(r, e.key, 4);
    if (k < 0) continue;
    ctx.labels[k] = e.value;
    final x = ctx.features?[k];
    if (x != null) {
      corrFeatures.add(x);
      corrLabels.add(e.value);
    }
  }

  ctx.detectAf();
  final events = ctx.detectEvents();
  final stats = ctx.computeStats(events);
  final morph = measureMorphology(filtered, r, ctx.labels, ctx.inAf, tl);
  if (morph != null) stats.values.addAll(morph.values);
  final noisyRanges = _ranges(noisyMask, noiseWin, raw.length);
  stats.values['hf_2_8_pct'] = bandEnergy2to8(filtered, tl, noisyRanges);
  if (activity != null) stats.values.addAll(ctx.activityStats());

  final result = AnalysisResult(
    timeline: tl,
    rPeaks: r,
    labels: ctx.labels,
    inAf: ctx.inAf,
    noisy: noisyRanges,
    events: events..sort((a, b) => a.startSample.compareTo(b.startSample)),
    stats: stats,
    analyzedAt: DateTime.now(),
    template: morph?.template,
    templatePre: morph?.pre ?? 0,
    probs: ctx.probs,
    activity: activity,
    corrected: {for (final e in corr.entries) e.key: e.value},
  );
  assert(result.labels.length == n);

  // Wzorzec prawidłowego pobudzenia tego zapisu (do profilu osobistego).
  final normals = [for (var i = 0; i < n; i++) if (ctx.labels[i] == BeatType.normal && ctx.inAf[i] == 0) i];
  return AnalysisOutput.full(
    result,
    filtered,
    settings.collectFeatures ? ctx.features : null,
    normalTemplate: normals.length >= 50 ? ctx._medianBeat(ctx._spread(normals, 200)) : null,
    normalWideTemplate: normals.length >= 50 ? ctx._medianBeat(ctx._spread(normals, 200), wide: true) : null,
    correctedFeatures: corrFeatures,
    correctedLabels: corrLabels,
  );
}

/// Usuwa znaczniki oznaczone do usunięcia i dodaje brakujące (gdy poprawka wskazuje miejsce bez R).
List<int> _applyPeakCorrections(List<int> peaks, Map<int, int> corr, int total) {
  final out = [...peaks];
  for (final e in corr.entries) {
    final k = _nearestBeatList(out, e.key, 4);
    if (e.value == correctionDelete) {
      if (k >= 0) out.removeAt(k);
    } else if (k < 0 && e.key >= 0 && e.key < total) {
      out.add(e.key);
    }
  }
  out.sort();
  return out;
}

int _nearestBeatList(List<int> r, int sample, int tol) {
  var best = -1;
  for (var i = 0; i < r.length; i++) {
    if ((r[i] - sample).abs() <= tol && (best < 0 || (r[i] - sample).abs() < (r[best] - sample).abs())) best = i;
  }
  return best;
}

int _nearestBeat(Int32List r, int sample, int tol) {
  var lo = 0, hi = r.length;
  while (lo < hi) {
    final m = (lo + hi) >> 1;
    if (r[m] < sample - tol) {
      lo = m + 1;
    } else {
      hi = m;
    }
  }
  var best = -1;
  for (var i = lo; i < r.length && r[i] <= sample + tol; i++) {
    if (best < 0 || (r[i] - sample).abs() < (r[best] - sample).abs()) best = i;
  }
  return best;
}

/// Amplituda międzyszczytowa i średnia |druga różnica| (miara składowej w.cz.) w [a, b).
({double p2p, double hf}) _quality(Float32List f, int a, int b) {
  var mx = -double.infinity, mn = double.infinity, hf = 0.0;
  for (var i = a; i < b; i++) {
    final v = f[i];
    if (v > mx) mx = v;
    if (v < mn) mn = v;
    if (i >= a + 2) hf += (v - 2 * f[i - 1] + f[i - 2]).abs();
  }
  return (p2p: mx - mn, hf: b - a > 2 ? hf / (b - a - 2) : 0);
}

bool _isNoisy(({double p2p, double hf}) q) => q.p2p > 8000 || (q.p2p > 0 && q.hf / q.p2p > 0.12);

Uint8List _noiseMask(Float32List f, int win) {
  final nw = (f.length + win - 1) ~/ win;
  final mask = Uint8List(nw);
  final flat = Uint8List(nw);
  for (var w = 0; w < nw; w++) {
    final a = w * win, b = min(f.length, a + win);
    if (b - a < 3) continue;
    final q = _quality(f, a, b);
    // > 8 mV: ruch/odklejenie; duży udział w.cz.: szum mięśniowy.
    if (_isNoisy(q)) mask[w] = 1;
    if (q.p2p < 150) flat[w] = 1;
  }
  // Płaska linia = brak kontaktu, ale dopiero od 8 s – krótsza może być prawdziwą pauzą.
  var w = 0;
  while (w < nw) {
    if (flat[w] == 0) {
      w++;
      continue;
    }
    var e = w;
    while (e + 1 < nw && flat[e + 1] == 1) {
      e++;
    }
    if (e - w + 1 >= 4) { // 4 okna × 2 s
      for (var k = w; k <= e; k++) {
        mask[k] = 1;
      }
    }
    w = e + 1;
  }
  return mask;
}

List<List<int>> _ranges(Uint8List mask, int win, int total) {
  final out = <List<int>>[];
  int? s;
  for (var w = 0; w <= mask.length; w++) {
    final on = w < mask.length && mask[w] == 1;
    if (on && s == null) s = w * win;
    if (!on && s != null) {
      out.add([s, min(total, w * win)]);
      s = null;
    }
  }
  return out;
}

double _median(List<double> v) {
  if (v.isEmpty) return double.nan;
  final s = [...v]..sort();
  final m = s.length >> 1;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

class _Ctx {
  final int fs;
  final Float32List f;
  final Int32List r;
  final Int32List seg;
  final Uint8List noisyMask;
  final int noiseWin;
  final Timeline tl;
  final AnalysisSettings cfg;
  final PersonalProfile? profile;
  final Float32List? activity; // mg w oknach noiseWin
  late final Uint8List labels = Uint8List(r.length);
  late final Uint8List inAf = Uint8List(r.length);
  late final Uint8List beatNoisy;

  _Ctx(this.fs, this.f, this.r, this.seg, this.noisyMask, this.noiseWin, this.tl, this.cfg, {this.profile, this.activity}) {
    beatNoisy = Uint8List(r.length);
    final half = fs ~/ 2;
    final noiseIdx = _noiseIdx = _beatNoiseIndex();
    for (var i = 0; i < r.length; i++) {
      final w = r[i] ~/ noiseWin;
      final s = tl.segments[seg[i]];
      final local = _quality(f, max(s.start, r[i] - half), min(s.end, r[i] + half));
      // Podczas intensywnego ruchu (akcelerometr) próg szumu jest ostrzejszy – częstsze artefakty.
      final limit = activityAt(r[i]) > 150 ? cfg.noiseIdxLimit * 0.75 : cfg.noiseIdxLimit;
      final hard = (w < noisyMask.length && noisyMask[w] == 1) || _isNoisy(local);
      beatNoisy[i] = (hard || noiseIdx[i] > limit) ? 1 : 0;
      // Kandydat do odzysku: odrzucony wyłącznie przez umiarkowanie podwyższony wskaźnik szumu
      // (np. fale migotania, drobne drżenie linii izoelektrycznej).
      if (!hard && noiseIdx[i] > limit && noiseIdx[i] < 2.5 * limit) _rescued[i] = 2;
    }
  }

  /// 0 – zwykłe, 2 – kandydat do odzysku, 1 – odzyskane (może być tylko N).
  late final Uint8List _rescued = Uint8List(r.length);

  /// Odzysk kandydatów: QRS niemal identyczny z medianą czytelnych pobudzeń z otoczenia
  /// (korelacja ≥ rescueCorr, ta sama szerokość i amplituda). Zakłócenie ruchowe H10 praktycznie
  /// nie daje takiego kształtu, a odzyskane pobudzenie może być wyłącznie N (bez fałszywych V/S).
  void _rescueNoisy() {
    if (cfg.rescueCorr <= 0 || !_rescued.contains(2)) return;
    const block = 256;
    final nBlocks = (n + block - 1) ~/ block;
    final clean = [for (var i = 0; i < n; i++) if (beatNoisy[i] == 0) i];
    if (clean.length < 8) return;
    final global = _medianBeat(_spread(clean, 200));
    for (var b = 0; b < nBlocks; b++) {
      final lo = max(0, (b - 1) * block), hi = min(n, (b + 2) * block);
      final cand = [for (var i = lo; i < hi; i++) if (beatNoisy[i] == 0) i];
      final t = cand.length >= 8 ? _medianBeat(_spread(cand, 64)) : global;
      final tw = _eqWidth(t), tp = _p2p(t);
      for (var i = b * block; i < min(n, (b + 1) * block); i++) {
        if (_rescued[i] != 2) continue;
        _rescued[i] = 0;
        final w = _window(i);
        if (w == null || tp <= 0) continue;
        final ar = _p2p(w) / tp, wr = _eqWidth(w) / tw;
        if (_pearson(w, t) >= cfg.rescueCorr && ar > 0.7 && ar < 1.4 && wr < 1.15) _rescued[i] = 1;
      }
    }
    for (var i = 0; i < n; i++) {
      if (_rescued[i] == 1) beatNoisy[i] = 0;
    }
  }


  /// Wskaźnik szumu wokół pobudzenia: średnia |druga różnica| w ±0.5 s z pominięciem
  /// ±0.1 s wokół wszystkich załamków R, odniesiona do lokalnej amplitudy R.
  Float64List _beatNoiseIndex() {
    final out = Float64List(n);
    if (n == 0) return out;
    final excl = (cfg.noiseExclSec * fs).round(), half = fs ~/ 2;
    final amps = [for (final p in r) f[p].abs().toDouble()];
    for (var i = 0; i < n; i++) {
      final ref = _median([for (var j = max(0, i - 16); j < min(n, i + 17); j++) amps[j]]);
      if (ref <= 0) continue;
      final s = tl.segments[seg[i]];
      var hf = 0.0, cnt = 0;
      var k = max(0, i - 8);
      for (var t = max(s.start + 2, r[i] - half); t < min(s.end, r[i] + half); t++) {
        while (k < n && r[k] < t - excl) {
          k++;
        }
        if (k < n && (r[k] - t).abs() <= excl) continue;
        hf += (f[t] - 2 * f[t - 1] + f[t - 2]).abs();
        cnt++;
      }
      if (cnt > 0) out[i] = hf / cnt / ref;
    }
    return out;
  }

  /// Znaczniki, które nie są pobudzeniami: nieprawidłowy kształt, niska amplituda
  /// i "wstawione" w normalny odstęp RR (suma sąsiednich RR ≈ lokalny RR).
  Set<int> artifactBeats() {
    final out = <int>{};
    for (var i = 1; i < n - 1; i++) {
      // Niezależnie od etykiety: prawdziwe pobudzenie (także N/S z modelu) nie ma niskiego R
      // i jednocześnie nie dzieli prawidłowego odstępu RR na dwie części.
      if (_peakRatio[i].isNaN || _peakRatio[i] >= 0.55) continue;
      if (rr(i) <= 0 || rr(i + 1) <= 0) continue;
      final loc = localRr(i);
      if (loc.isNaN) continue;
      final sum = (rr(i) + rr(i + 1)) / loc;
      if (sum > 0.8 && sum < 1.25) out.add(i);
    }
    return out;
  }

  late final Float64List _ampRatio = Float64List(n)..fillRange(0, n, double.nan);
  late final Float64List _noiseIdx;
  late final Float64List _loc = Float64List(n)..fillRange(0, n, double.nan);
  late final int _wPre = (0.3 * fs).round();
  late final int _wPost = (0.45 * fs).round();
  List<Float64List?>? features;

  /// Prawdopodobieństwa klas z modelu [pN, pS, pV] na pobudzenie (null bez modelu).
  Float32List? probs;

  /// Wysokość szczytu R względem szczytu wzorca (ten sam kierunek polaryzacji).
  late final Float64List _peakRatio = Float64List(n)..fillRange(0, n, double.nan);

  int get n => r.length;

  /// Odstęp RR kończący się na pobudzeniu i (w próbkach), lub -1 gdy nieciągły.
  int rr(int i) => (i > 0 && i < n && seg[i] == seg[i - 1]) ? r[i] - r[i - 1] : -1;

  bool cleanRr(int i) => rr(i) > 0 && beatNoisy[i] == 0 && beatNoisy[i - 1] == 0;

  /// Mediana RR z otoczenia (±8), bez odstępów sąsiadujących z pobudzeniem i.
  double localRr(int i) {
    final v = <double>[];
    for (var j = max(1, i - 8); j <= min(n - 1, i + 9); j++) {
      if (j == i || j == i + 1) continue;
      if (cleanRr(j)) v.add(rr(j).toDouble());
    }
    return _median(v);
  }

  // ---------------- Klasyfikacja pobudzeń ----------------

  late final int _pre = (0.09 * fs).round();
  late final int _post = (0.125 * fs).round();

  Float64List? _window(int i) {
    final s = tl.segments[seg[i]];
    final a = r[i] - _pre, b = r[i] + _post;
    if (a < s.start || b >= s.end) return null;
    final w = Float64List(b - a + 1);
    for (var k = 0; k < w.length; k++) {
      w[k] = f[a + k];
    }
    return w;
  }

  void classify() {
    if (n == 0) return;
    _rescueNoisy();
    final prem = Float64List(n)..fillRange(0, n, double.nan);
    final nextRatio = Float64List(n)..fillRange(0, n, double.nan);
    for (var i = 1; i < n; i++) {
      final loc = _loc[i] = localRr(i);
      if (loc.isNaN) continue;
      if (rr(i) > 0) prem[i] = rr(i) / loc;
      if (i + 1 < n && rr(i + 1) > 0) nextRatio[i] = rr(i + 1) / loc;
    }

    // Wzorce lokalne: bloki po 256 pobudzeń, mediana z regularnych pobudzeń.
    // (Morfologia z elektrody piersiowej zmienia się z pozycją ciała.)
    const blockSize = 256;
    final nBlocks = (n + blockSize - 1) ~/ blockSize;
    final templates = List<Float64List?>.filled(nBlocks, null);
    final wide = List<Float64List?>.filled(nBlocks, null);
    for (var b = 0; b < nBlocks; b++) {
      final cand = <int>[];
      for (var i = b * blockSize; i < min(n, (b + 1) * blockSize); i++) {
        if (beatNoisy[i] == 1) continue;
        final p = prem[i], q = nextRatio[i];
        if (p.isNaN || q.isNaN || p < 0.85 || p > 1.15 || q < 0.85 || q > 1.15) continue;
        cand.add(i);
      }
      if (cand.length >= 8) {
        templates[b] = _medianBeat(_spread(cand, 64));
        wide[b] = _medianBeat(_spread(cand, 64), wide: true);
      }
    }
    if (templates.every((t) => t == null) && (profile?.hasTemplate ?? false)) {
      // Za mało regularnych pobudzeń (np. częste dodatkowe) – wzorzec z profilu osobistego,
      // najbardziej podobny do mediany czytelnych pobudzeń.
      final clean = [for (var i = 0; i < n; i++) if (beatNoisy[i] == 0) i];
      final probe = clean.length >= 4 ? _medianBeat(_spread(clean, 200)) : null;
      final k = profile!.bestTemplateFor(probe);
      if (profile!.qrsTemplates[k].length == _pre + _post + 1 && profile!.wideTemplates[k].length == _wPre + _wPost + 1) {
        for (var b = 0; b < nBlocks; b++) {
          templates[b] = profile!.qrsTemplates[k];
          wide[b] = profile!.wideTemplates[k];
        }
      }
    }
    if (templates.every((t) => t == null)) {
      final clean = [for (var i = 0; i < n; i++) if (beatNoisy[i] == 0) i];
      if (clean.length >= 4) {
        final g = _medianBeat(_spread(clean, 200));
        final gw = _medianBeat(_spread(clean, 200), wide: true);
        for (var b = 0; b < nBlocks; b++) {
          templates[b] = g;
          wide[b] = gw;
        }
      }
    } else {
      // Uzupełnij brakujące bloki najbliższym dostępnym wzorcem.
      for (var b = 0; b < nBlocks; b++) {
        if (templates[b] != null) continue;
        for (var d = 1; d < nBlocks; d++) {
          final src = (b - d >= 0 && templates[b - d] != null)
              ? b - d
              : (b + d < nBlocks && templates[b + d] != null ? b + d : -1);
          if (src >= 0) {
            templates[b] = templates[src];
            wide[b] = wide[src];
            break;
          }
        }
      }
    }

    final minRr = 0.24 * fs;
    for (var i = 0; i < n; i++) {
      final t = templates[i ~/ blockSize];
      final w = _window(i);
      if (t != null && w != null) {
        _ampRatio[i] = _p2p(w) / _p2p(t);
        if (t[_pre].abs() > 1) _peakRatio[i] = w[_pre] / t[_pre];
      }
      if (beatNoisy[i] == 1 || (rr(i) > 0 && rr(i) < minRr)) {
        labels[i] = BeatType.unknown;
        continue;
      }
      final p = prem[i];
      if (t == null || w == null) {
        labels[i] = (!p.isNaN && p < cfg.sPrematurity) ? BeatType.supraventricular : BeatType.normal;
        continue;
      }
      final corr = _pearson(w, t);
      final wr = _eqWidth(w) / _eqWidth(t);
      final ar = _ampRatio[i];
      if (ar > 4 || ar < 0.25) {
        labels[i] = BeatType.unknown;
        continue;
      }
      final premature = !p.isNaN && p < cfg.vPrematurity;
      final abnormal =
          corr < cfg.vCorrHard || wr > cfg.vWidthHard || (corr < cfg.vCorrSoft && (wr > cfg.vWidthSoft || premature));
      _corrN[i] = corr;
      if (_rescued[i] == 1) {
        labels[i] = abnormal || _isSvPremature(i, p) ? BeatType.unknown : BeatType.normal;
      } else if (abnormal) {
        labels[i] = BeatType.ventricular;
      } else if (_isSvPremature(i, p)) {
        labels[i] = BeatType.supraventricular;
      } else {
        labels[i] = BeatType.normal;
      }
    }
    // Cechy i klasyfikator MLP (reguły powyżej zostają jako zapas, gdy brak modelu).
    final model = cfg.useModel ? beatModel : null;
    if (model == null && !cfg.collectFeatures) {
      _refineWithVTemplate(templates, blockSize, prem);
      return;
    }
    final rrs = [for (var i = 1; i < n; i++) if (cleanRr(i)) rr(i).toDouble()];
    final globalRr = rrs.isEmpty ? fs.toDouble() : _median(rrs);
    features = List<Float64List?>.filled(n, null);
    if (model != null) probs = Float32List(n * 3);
    final tV = model?.meta['tV'] ?? 0.5, tS = model?.meta['tS'] ?? 0.5;
    for (var i = 0; i < n; i++) {
      if (labels[i] == BeatType.unknown) continue;
      final b = i ~/ blockSize;
      final x = beatFeatures(i, templates[b], wide[b], globalRr, prem, nextRatio);
      features![i] = x;
      if (model == null) continue;
      final p = model.predict(x);
      probs!.setRange(i * 3, i * 3 + 3, p);
      labels[i] = p[2] >= tV
          ? BeatType.ventricular
          : p[1] >= tS
              ? BeatType.supraventricular
              : BeatType.normal;
      // Personalizacja: pobudzenia bardzo podobne do oznaczonych ręcznie dostają tę samą etykietę.
      final pr = profile;
      if (pr != null && pr.examples >= 20) {
        final k = pr.knnLabel(x, model.mean, model.std);
        if (k != null) labels[i] = k;
      }
      if (_rescued[i] == 1 && labels[i] != BeatType.normal) labels[i] = BeatType.unknown;
    }
    if (model == null) _refineWithVTemplate(templates, blockSize, prem);
  }

  late final Float64List _corrN = Float64List(n)..fillRange(0, n, double.nan);

  /// Przedwczesne nadkomorowe: krótkie względem otoczenia LUB wyraźnie krótsze od poprzedniego
  /// odstępu z następującą dłuższą przerwą (odporne na niemiarowość zatokową).
  bool _isSvPremature(int i, double p) {
    if (!p.isNaN && p < cfg.sPrematurity) return true;
    final cur = rr(i);
    final prev = i > 1 ? rr(i - 1) : -1;
    final next = i + 1 < n ? rr(i + 1) : -1;
    if (cur <= 0 || prev <= 0 || next <= 0) return false;
    return cur < cfg.sPrevRatio * prev && next > cfg.sNextRatio * cur;
  }

  /// Drugi wzorzec – "komorowy" – z pewnych pobudzeń V; każde pobudzenie przypisujemy
  /// do bardziej podobnego wzorca (grupowanie morfologii jak w analizie holterowskiej).
  void _refineWithVTemplate(List<Float64List?> templates, int blockSize, Float64List prem) {
    final sure = [for (var i = 0; i < n; i++) if (labels[i] == BeatType.ventricular && _corrN[i] < 0.6) i];
    if (sure.length < 5) return;
    // Morfologie V mogą być różne (wieloogniskowe) – tworzymy do 3 grup zachłannie.
    final groups = <Float64List>[];
    final remaining = [...sure];
    while (remaining.isNotEmpty && groups.length < 3) {
      final seedIdx = remaining.removeAt(0);
      final seed = _window(seedIdx);
      if (seed == null) continue;
      final members = [seedIdx, for (final i in remaining) if (_window(i) case final w? when _pearson(w, seed) > 0.85) i];
      if (members.length >= 3) groups.add(_medianBeat(_spread(members, 64)));
      final memberSet = members.toSet();
      remaining.removeWhere(memberSet.contains);
    }
    if (groups.isEmpty) return;
    for (var i = 0; i < n; i++) {
      final l = labels[i];
      if (l == BeatType.unknown || _corrN[i].isNaN || _rescued[i] == 1) continue;
      final w = _window(i);
      if (w == null) continue;
      var cV = -1.0;
      for (final g in groups) {
        cV = max(cV, _pearson(w, g));
      }
      final cN = _corrN[i];
      if (l != BeatType.ventricular && cV > cfg.vGroupCorr && cV > cN + cfg.vGroupMargin) {
        labels[i] = BeatType.ventricular;
      } else if (l == BeatType.ventricular && cN > 0.9 && cN > cV + cfg.vGroupMargin) {
        labels[i] = _isSvPremature(i, prem[i]) ? BeatType.supraventricular : BeatType.normal;
      }
    }
  }

  List<int> _spread(List<int> idx, int maxN) {
    if (idx.length <= maxN) return idx;
    return [for (var k = 0; k < maxN; k++) idx[k * idx.length ~/ maxN]];
  }

  Float64List _medianBeat(List<int> idx, {bool wide = false}) {
    final wins = [for (final i in idx) wide ? _wideWindow(i) : _window(i)].whereType<Float64List>().toList();
    final len = wide ? _wPre + _wPost + 1 : _pre + _post + 1;
    final t = Float64List(len);
    if (wins.isEmpty) return t;
    for (var k = 0; k < len; k++) {
      t[k] = _median([for (final w in wins) w[k]]);
    }
    return t;
  }

  static double _pearson(Float64List a, Float64List b) {
    final len = a.length;
    var ma = 0.0, mb = 0.0;
    for (var i = 0; i < len; i++) {
      ma += a[i];
      mb += b[i];
    }
    ma /= len;
    mb /= len;
    var sab = 0.0, saa = 0.0, sbb = 0.0;
    for (var i = 0; i < len; i++) {
      final x = a[i] - ma, y = b[i] - mb;
      sab += x * y;
      saa += x * x;
      sbb += y * y;
    }
    if (saa == 0 || sbb == 0) return 0;
    return sab / sqrt(saa * sbb);
  }

  /// Szerokość równoważna: pole pod |x| / amplituda – miara szerokości zespołu.
  static double _eqWidth(Float64List w) {
    final base = (w[0] + w[1] + w[2] + w[w.length - 1] + w[w.length - 2] + w[w.length - 3]) / 6;
    var sum = 0.0, mx = 0.0;
    for (final v in w) {
      final a = (v - base).abs();
      sum += a;
      if (a > mx) mx = a;
    }
    return mx == 0 ? 1 : sum / mx;
  }

  static double _p2p(Float64List w) {
    var mx = -double.infinity, mn = double.infinity;
    for (final v in w) {
      mx = max(mx, v);
      mn = min(mn, v);
    }
    return max(1, mx - mn);
  }

  // ---------------- Migotanie przedsionków ----------------

  /// Wykrywanie migotania przedsionków – głosowanie trzech niezależnych wskaźników
  /// w oknach 32 odstępów RR (krok 4):
  ///  1. kryteria Dash i wsp. (2009): nRMSSD > 0.1, wsp. punktów zwrotnych w granicach
  ///     losowości, entropia Shannona histogramu RR,
  ///  2. COSEn (Lake i Moorman 2011) > −1.4 – entropia próbkowa RR skorygowana o średni RR,
  ///  3. brak załamka P – niska korelacja okolicy P z wzorcem rytmu zatokowego (cecha klasyfikatora).
  /// AF, gdy ≥ 2 głosy (lub 1 i 2, jeśli brak informacji o P) przy nRMSSD > 0.06.
  void detectAf() {
    final rrs = <double>[];
    final idx = <int>[];
    for (var i = 1; i < n; i++) {
      if (!cleanRr(i)) continue;
      final a = labels[i - 1], b = labels[i];
      if (a == BeatType.ventricular || a == BeatType.unknown || b == BeatType.ventricular || b == BeatType.unknown) {
        continue;
      }
      rrs.add(rr(i) / fs);
      idx.add(i);
    }
    final feats = features;
    const w = 32, step = 4, trim = 2;
    for (var w0 = 0; w0 + w <= rrs.length; w0 += step) {
      if (idx[w0 + w - 1] - idx[w0] > w * 2) continue; // za dużo odrzuconych pobudzeń
      final vals = rrs.sublist(w0, w0 + w);
      final sorted = [...vals]..sort();
      final lo = sorted[trim], hi = sorted[w - 1 - trim];
      final x = [for (final v in vals) if (v >= lo && v <= hi) v];
      if (x.length < 16) continue;
      final m = x.reduce((a, b) => a + b) / x.length;
      var ss = 0.0;
      for (var k = 1; k < x.length; k++) {
        ss += (x[k] - x[k - 1]) * (x[k] - x[k - 1]);
      }
      final nrmssd = sqrt(ss / (x.length - 1)) / m;
      if (nrmssd <= 0.06) continue;
      var tp = 0;
      for (var k = 1; k < x.length - 1; k++) {
        if ((x[k] - x[k - 1]) * (x[k + 1] - x[k]) < 0) tp++;
      }
      final nn = x.length;
      final mu = (2 * nn - 4) / 3, sd = sqrt((16 * nn - 29) / 90);
      final dash = nrmssd > 0.1 && tp > mu - 2 * sd && tp < mu + 2 * sd && _shannon(x) > 0.6;
      final cosen = _cosen(vals) > cfg.afCosen;
      bool? pAbsent;
      if (feats != null) {
        final pc = <double>[
          for (var k = w0; k < w0 + w; k++)
            if (feats[idx[k]] != null) feats[idx[k]]![10]
        ];
        if (pc.length >= w ~/ 2) pAbsent = _median(pc) < cfg.afPCorr;
      }
      final votes = (dash ? 1 : 0) + (cosen ? 1 : 0) + ((pAbsent ?? false) ? 1 : 0);
      final isAf = pAbsent == null ? (dash && cosen) : votes >= cfg.afVotes;
      if (!isAf) continue;
      // Środkowa połowa okna (dokładniejsze granice); przy brzegach zapisu – całe okno.
      final from = w0 == 0 ? idx[0] - 1 : idx[w0 + w ~/ 4];
      final to = w0 + w + step > rrs.length ? idx[w0 + w - 1] : idx[w0 + 3 * w ~/ 4];
      for (var b = from; b <= to; b++) {
        inAf[b] = 1;
      }
    }
    // Połącz epizody rozdzielone krótką przerwą (np. kilka regularniejszych odstępów w trakcie AF).
    if (cfg.afGapSec > 0) {
      var last = -1;
      for (var k = 0; k < n; k++) {
        if (inAf[k] == 0) continue;
        if (last >= 0 && k > last + 1 && seg[k] == seg[last] && (r[k] - r[last]) / fs <= cfg.afGapSec) {
          for (var q = last + 1; q < k; q++) {
            inAf[q] = 1;
          }
        }
        last = k;
      }
    }
    // Usuń epizody krótsze niż próg; w AF pobudzenia "przedwczesne" nie są S.
    var i = 0;
    while (i < n) {
      if (inAf[i] == 0) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < n && inAf[j + 1] == 1) {
        j++;
      }
      final dur = (r[j] - r[i]) / fs;
      for (var k = i; k <= j; k++) {
        if (dur < cfg.afMinSeconds) {
          inAf[k] = 0;
        } else if (labels[k] == BeatType.supraventricular) {
          labels[k] = BeatType.normal;
        }
      }
      i = j + 1;
    }
  }

  /// COSEn: SampEn(m=1, r=30 ms) + ln(2r) − ln(średni RR) [RR w sekundach].
  static double _cosen(List<double> x) {
    const r = 0.03;
    final n = x.length;
    var a = 0, b = 0;
    for (var i = 0; i < n - 1; i++) {
      for (var j = i + 1; j < n - 1; j++) {
        if ((x[i] - x[j]).abs() <= r) {
          b++;
          if ((x[i + 1] - x[j + 1]).abs() <= r) a++;
        }
      }
    }
    final mean = x.reduce((p, q) => p + q) / n;
    // Brak dopasowań = bardzo duża nieregularność; ograniczamy entropię z góry.
    final sampEn = (a == 0 || b == 0) ? -log(1 / max(1, b * (n - 1))) : -log(a / b);
    return sampEn + log(2 * r) - log(mean);
  }

  static double _shannon(List<double> x) {
    var mn = double.infinity, mx = -double.infinity;
    for (final v in x) {
      mn = min(mn, v);
      mx = max(mx, v);
    }
    if (mx <= mn) return 0;
    const bins = 16;
    final h = List<int>.filled(bins, 0);
    for (final v in x) {
      h[min(bins - 1, ((v - mn) / (mx - mn) * bins).floor())]++;
    }
    var e = 0.0;
    for (final c in h) {
      if (c == 0) continue;
      final p = c / x.length;
      e -= p * log(p);
    }
    return e / log(bins);
  }

  // ---------------- Zdarzenia ----------------

  int _bpm(int samples) => (60 * fs / samples).round();

  String _dur(int samples) {
    final s = samples / fs;
    if (s < 60) return '${s.toStringAsFixed(1)} s';
    final m = s ~/ 60;
    if (m < 60) return '$m min ${(s % 60).round()} s';
    return '${m ~/ 60} h ${m % 60} min';
  }

  List<EcgEvent> detectEvents() {
    final ev = <EcgEvent>[];
    _afEvents(ev);
    _pauses(ev);
    _ventricularRuns(ev);
    _patterns(ev);
    _svRuns(ev);
    if (cfg.svtOnset > 0) _sustainedSvt(ev);
    _rateEpisodes(ev);
    if (cfg.stDevUv > 0) _stEvents(ev);
    if (cfg.avbCorr <= 1) _avBlocks(ev);
    if (cfg.aflCorr <= 1) _flutter(ev);
    return ev;
  }

  void _afEvents(List<EcgEvent> ev) {
    var i = 0;
    while (i < n) {
      if (inAf[i] == 0) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < n && inAf[j + 1] == 1) {
        j++;
      }
      final hr = _bpm(((r[j] - r[i]) / max(1, j - i)).round());
      ev.add(EcgEvent(EventType.af, r[i], r[j], 'czas ${_dur(r[j] - r[i])}, średnio $hr/min'));
      i = j + 1;
    }
  }

  void _pauses(List<EcgEvent> ev) {
    final limit = cfg.pauseSeconds * fs;
    final guard = (0.25 * fs).round();
    for (var i = 1; i < n; i++) {
      final d = rr(i);
      if (d <= limit) continue;
      if (labels[i] == BeatType.unknown || labels[i - 1] == BeatType.unknown) continue;
      if (_overlapsNoise(r[i - 1], r[i])) continue;
      // Kontrola przeoczonego QRS: w przerwie nie może być nic o amplitudzie zbliżonej do R.
      final ref = 0.5 * min(f[r[i - 1]].abs(), f[r[i]].abs());
      var missed = false;
      for (var k = r[i - 1] + guard; k < r[i] - guard; k++) {
        if (f[k].abs() > ref) {
          missed = true;
          break;
        }
      }
      if (missed) continue;
      final sec = d / fs;
      ev.add(EcgEvent(EventType.pause, r[i - 1], r[i], '${sec.toStringAsFixed(1)} s',
          severity: sec >= 3 ? Severity.high : Severity.medium));
    }
  }

  bool _overlapsNoise(int a, int b) {
    for (var w = a ~/ noiseWin; w <= b ~/ noiseWin && w < noisyMask.length; w++) {
      if (noisyMask[w] == 1) return true;
    }
    return false;
  }

  void _ventricularRuns(List<EcgEvent> ev) {
    var i = 0;
    while (i < n) {
      if (labels[i] != BeatType.ventricular) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < n && labels[j + 1] == BeatType.ventricular && seg[j + 1] == seg[i]) {
        j++;
      }
      final c = j - i + 1;
      if (c == 2) {
        ev.add(EcgEvent(EventType.couplet, r[i], r[j], ''));
      } else if (c >= 3) {
        final hr = _bpm(((r[j] - r[i]) / (c - 1)).round());
        ev.add(EcgEvent(hr > 100 ? EventType.vt : EventType.ivr, r[i], r[j], '$c pobudzeń, $hr/min'));
      }
      i = j + 1;
    }
  }

  void _patterns(List<EcgEvent> ev) {
    for (final period in [2, 3]) {
      var i = period - 1;
      while (i < n) {
        if (labels[i] != BeatType.ventricular) {
          i++;
          continue;
        }
        var cycles = 0;
        var j = i;
        while (j < n && labels[j] == BeatType.ventricular && seg[j] == seg[i]) {
          var ok = true;
          for (var k = 1; k < period; k++) {
            if (j - k < 0 || labels[j - k] != BeatType.normal) ok = false;
          }
          if (!ok) break;
          cycles++;
          j += period;
        }
        if (cycles >= 3) {
          final last = j - period;
          ev.add(EcgEvent(period == 2 ? EventType.bigeminy : EventType.trigeminy, r[i - (period - 1)], r[last],
              '$cycles cykli, ${_dur(r[last] - r[i - (period - 1)])}'));
          i = last + 1;
        } else {
          i++;
        }
      }
    }
  }

  void _svRuns(List<EcgEvent> ev) {
    var i = 0;
    while (i < n) {
      if (labels[i] != BeatType.supraventricular || inAf[i] == 1) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < n && labels[j + 1] == BeatType.supraventricular && seg[j + 1] == seg[i]) {
        j++;
      }
      final c = j - i + 1;
      if (c >= 3) {
        final hr = _bpm(((r[j] - r[i]) / (c - 1)).round());
        ev.add(EcgEvent(hr > 100 ? EventType.svt : EventType.svRun, r[i], r[j], '$c pobudzeń, $hr/min'));
      }
      i = j + 1;
    }
  }

  /// Utrwalony częstoskurcz nadkomorowy: nagły początek (odstęp RR krótszy o ≥ 20% od mediany 8 poprzednich),
  /// rytm miarowy > 100/min z wąskimi zespołami przez ≥ svtMinBeats, koniec przy powrocie do rytmu wyjściowego.
  /// Częstoskurcz zatokowy narasta stopniowo, więc nie spełnia kryterium nagłego początku.
  void _sustainedSvt(List<EcgEvent> ev) {
    bool ok(int i) => cleanRr(i) && labels[i] != BeatType.ventricular && labels[i] != BeatType.unknown &&
        labels[i - 1] != BeatType.ventricular && labels[i - 1] != BeatType.unknown && inAf[i] == 0;
    final prev = <double>[];
    var i = 1;
    while (i < n) {
      if (!ok(i)) {
        prev.clear();
        i++;
        continue;
      }
      final cur = rr(i).toDouble();
      if (prev.length >= 6) {
        final base = _median(prev);
        if (cur < cfg.svtOnset * base && 60 * fs / cur > 100) {
          // Przebieg częstoskurczu: odstępy miarowe (±15% mediany bieżących) i krótsze niż 0.85 × wyjściowy.
          final run = <double>[cur];
          var j = i;
          while (j + 1 < n && ok(j + 1)) {
            final x = rr(j + 1).toDouble();
            final m = _median(run);
            if (x > 0.85 * base || (x - m).abs() > 0.15 * m) break;
            run.add(x);
            j++;
          }
          final beats = j - i + 2; // z pobudzeniem rozpoczynającym
          if (beats >= cfg.svtMinBeats) {
            final a = r[i - 1], b = r[j];
            final dup = ev.any((e) => (e.type == EventType.svt || e.type == EventType.svRun) &&
                e.startSample <= b && a <= e.endSample);
            if (!dup) {
              final hr = _bpm(_median(run).round());
              ev.add(EcgEvent(EventType.svt, a, b, '$beats pobudzeń, $hr/min, nagły początek'));
            }
            prev.clear();
            i = j + 1;
            continue;
          }
        }
      }
      prev.add(cur);
      if (prev.length > 8) prev.removeAt(0);
      i++;
    }
  }

  /// Tętno chwilowe: mediana 8 ostatnich czystych odstępów RR.
  late final Float64List _hr = () {
    final hr = Float64List(n)..fillRange(0, n, double.nan);
    final last = <double>[];
    for (var i = 1; i < n; i++) {
      if (!cleanRr(i) || labels[i] == BeatType.unknown || labels[i - 1] == BeatType.unknown) continue;
      last.add(rr(i).toDouble());
      if (last.length > 8) last.removeAt(0);
      if (last.length >= 4) hr[i] = 60 * fs / _median(last);
    }
    return hr;
  }();

  void _rateEpisodes(List<EcgEvent> ev) {
    void scan(bool Function(double) cond, EventType type, double minSec, bool skipAf) {
      var i = 0;
      while (i < n) {
        final h = _hr[i];
        if (h.isNaN || !cond(h) || (skipAf && inAf[i] == 1)) {
          i++;
          continue;
        }
        var j = i;
        var extreme = h;
        while (j + 1 < n && seg[j + 1] == seg[i]) {
          final h2 = _hr[j + 1];
          if (!h2.isNaN && (!cond(h2) || (skipAf && inAf[j + 1] == 1))) break;
          j++;
          if (!h2.isNaN) extreme = type == EventType.brady ? min(extreme, h2) : max(extreme, h2);
        }
        if ((r[j] - r[i]) / fs >= minSec) {
          final lbl = type == EventType.brady ? 'min.' : 'maks.';
          final act = meanActivity(r[i], r[j]);
          final ctxText = act == null ? '' : (act > 60 ? ', podczas aktywności' : ', w spoczynku');
          // Tachykardia w spoczynku jest istotniejsza niż podczas wysiłku.
          final sev = type == EventType.tachy && act != null ? (act > 60 ? Severity.low : Severity.medium) : null;
          ev.add(EcgEvent(type, r[i], r[j], '${_dur(r[j] - r[i])}, $lbl ${extreme.round()}/min$ctxText', severity: sev));
        }
        i = j + 1;
      }
    }

    scan((h) => h < cfg.bradyBpm, EventType.brady, 10, false);
    scan((h) => h > cfg.tachyBpm, EventType.tachy, 30, true);
  }

  // ---------------- Aktywność (akcelerometr) ----------------

  double activityAt(int sample) {
    final a = activity;
    if (a == null) return 0;
    final w = sample ~/ noiseWin;
    return w < a.length ? a[w] : 0;
  }

  double? meanActivity(int from, int to) {
    final a = activity;
    if (a == null) return null;
    var s = 0.0, c = 0;
    for (var w = from ~/ noiseWin; w <= to ~/ noiseWin && w < a.length; w++) {
      if (a[w] < 0) continue; // brak danych
      s += a[w];
      c++;
    }
    return c == 0 ? null : s / c;
  }

  /// Rozkład aktywności i tętno spoczynkowe.
  Map<String, num?> activityStats() {
    final a = activity!;
    var rest = 0, light = 0, moderate = 0, vigorous = 0;
    for (final v in a) {
      if (v < 0) continue;
      if (v < 15) {
        rest++;
      } else if (v < 60) {
        light++;
      } else if (v < 200) {
        moderate++;
      } else {
        vigorous++;
      }
    }
    final tot = rest + light + moderate + vigorous;
    final restRr = <double>[];
    for (var i = 1; i < n; i++) {
      if (cleanRr(i) && labels[i] == BeatType.normal && labels[i - 1] == BeatType.normal && activityAt(r[i]) < 15) {
        restRr.add(rr(i).toDouble());
      }
    }
    return {
      'act_rest_pct': tot == 0 ? null : 100 * rest / tot,
      'act_light_pct': tot == 0 ? null : 100 * light / tot,
      'act_moderate_pct': tot == 0 ? null : 100 * moderate / tot,
      'act_vigorous_pct': tot == 0 ? null : 100 * vigorous / tot,
      'hr_rest': restRr.length < 30 ? null : 60 * fs / _median(restRr),
    };
  }

  // ---------------- Statystyki ----------------

  AnalysisStats computeStats(List<EcgEvent> events) {
    final total = tl.totalDuration.inMilliseconds / 1000;
    var noisySamples = 0;
    for (var w = 0; w < noisyMask.length; w++) {
      if (noisyMask[w] == 1) noisySamples += noiseWin;
    }
    final analyzed = max(0.0, total - noisySamples / fs);

    // Tętno minutowe.
    final perMinute = <int, List<double>>{};
    final allRr = <double>[];
    for (var i = 1; i < n; i++) {
      if (!cleanRr(i) || labels[i] == BeatType.unknown || labels[i - 1] == BeatType.unknown) continue;
      final v = rr(i).toDouble();
      allRr.add(v);
      perMinute.putIfAbsent(tl.offsetOf(r[i]).inMinutes, () => []).add(v);
    }
    double? hrMin, hrMax;
    int? hrMinAt, hrMaxAt;
    perMinute.forEach((minute, v) {
      if (v.length < 20) return;
      final hr = 60 * fs / (v.reduce((a, b) => a + b) / v.length);
      final at = tl.sampleAt(Duration(minutes: minute));
      if (hrMin == null || hr < hrMin!) {
        hrMin = hr;
        hrMinAt = at;
      }
      if (hrMax == null || hr > hrMax!) {
        hrMax = hr;
        hrMaxAt = at;
      }
    });
    final hrMean = allRr.isEmpty ? null : 60 * fs / (allRr.reduce((a, b) => a + b) / allRr.length);

    // HRV z odstępów NN (oba pobudzenia N, poza AF, zmiana < 20%).
    final nn = <double>[];
    final nnPairs = <List<double>>[];
    double? prev;
    for (var i = 1; i < n; i++) {
      final ok = cleanRr(i) &&
          labels[i] == BeatType.normal &&
          labels[i - 1] == BeatType.normal &&
          inAf[i] == 0 &&
          inAf[i - 1] == 0;
      if (!ok) {
        prev = null;
        continue;
      }
      final v = rr(i) * 1000 / fs;
      if (prev != null && (v - prev).abs() / prev > 0.2) {
        prev = v;
        continue;
      }
      nn.add(v);
      if (prev != null) nnPairs.add([prev, v]);
      prev = v;
    }
    double? meanNn, sdnn, rmssd, pnn50, pnn200, sd1, sd2;
    if (nn.length >= 10) {
      meanNn = nn.reduce((a, b) => a + b) / nn.length;
      sdnn = sqrt(nn.map((v) => (v - meanNn!) * (v - meanNn)).reduce((a, b) => a + b) / (nn.length - 1));
    }
    if (nnPairs.length >= 10) {
      final diffs = nnPairs.map((p) => p[1] - p[0]).toList();
      rmssd = sqrt(diffs.map((d) => d * d).reduce((a, b) => a + b) / diffs.length);
      pnn50 = 100 * diffs.where((d) => d.abs() > 50).length / diffs.length;
      final md = diffs.reduce((a, b) => a + b) / diffs.length;
      final sdsd = sqrt(diffs.map((d) => (d - md) * (d - md)).reduce((a, b) => a + b) / diffs.length);
      sd1 = sdsd / sqrt2;
      if (sdnn != null) sd2 = sqrt(max(0.0, 2 * sdnn * sdnn - sd1 * sd1));
    }

    // pNN200 – wskaźnik niemiarowości: wszystkie czytelne kolejne RR (bez filtra 20%).
    var big = 0, pairs = 0;
    for (var i = 2; i < n; i++) {
      if (!cleanRr(i) || !cleanRr(i - 1)) continue;
      if (labels[i] == BeatType.unknown || labels[i - 1] == BeatType.unknown || labels[i - 2] == BeatType.unknown) {
        continue;
      }
      pairs++;
      if ((rr(i) - rr(i - 1)).abs() * 1000 / fs > 200) big++;
    }
    if (pairs >= 10) pnn200 = 100 * big / pairs;

    var afSamples = 0;
    var longestPause = 0;
    for (final e in events) {
      if (e.type == EventType.af) afSamples += e.endSample - e.startSample;
      if (e.type == EventType.pause) longestPause = max(longestPause, e.endSample - e.startSample);
    }
    int cnt(int t) => labels.where((l) => l == t).length;
    final hours = max(analyzed / 3600, 1e-9);

    return AnalysisStats({
      'duration_s': total,
      'analyzed_s': analyzed,
      'beats': n,
      'n': cnt(BeatType.normal),
      's': cnt(BeatType.supraventricular),
      'v': cnt(BeatType.ventricular),
      'q': cnt(BeatType.unknown),
      'v_per_h': analyzed > 0 ? cnt(BeatType.ventricular) / hours : null,
      's_per_h': analyzed > 0 ? cnt(BeatType.supraventricular) / hours : null,
      'hr_mean': hrMean,
      'hr_min': hrMin,
      'hr_min_at': hrMinAt,
      'hr_max': hrMax,
      'hr_max_at': hrMaxAt,
      'af_burden_pct': analyzed > 0 ? 100 * afSamples / fs / analyzed : null,
      'longest_pause_s': longestPause > 0 ? longestPause / fs : null,
      'mean_nn_ms': meanNn,
      'sdnn_ms': sdnn,
      'rmssd_ms': rmssd,
      'pnn50_pct': pnn50,
      'pnn200_pct': pnn200,
      'sd1_ms': sd1,
      'sd2_ms': sd2,
    });
  }
}

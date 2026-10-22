import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Wynik prowadzonego pomiaru HRV (spoczynek, zwykle rano po przebudzeniu).
class HrvMeasurement {
  final DateTime time;
  final int seconds; // czas właściwego pomiaru
  final int beats; // odstępy RR użyte do obliczeń
  final double correctedPct; // odstępy odrzucone jako artefakty / pobudzenia dodatkowe
  final double hr, rmssd, sdnn, pnn50;
  final double? activityMg; // ruch w trakcie (akcelerometr)

  HrvMeasurement({
    required this.time,
    required this.seconds,
    required this.beats,
    required this.correctedPct,
    required this.hr,
    required this.rmssd,
    required this.sdnn,
    required this.pnn50,
    this.activityMg,
  });

  /// ln RMSSD – skala używana do oceny dzień po dniu (rozkład bliższy normalnemu).
  double get lnRmssd => log(max(1e-6, rmssd));

  /// Pomiar wiarygodny: dość uderzeń, mało korekt.
  bool get reliable => beats >= 60 && correctedPct <= 5;

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        's': seconds,
        'n': beats,
        'corr': double.parse(correctedPct.toStringAsFixed(2)),
        'hr': double.parse(hr.toStringAsFixed(1)),
        'rmssd': double.parse(rmssd.toStringAsFixed(1)),
        'sdnn': double.parse(sdnn.toStringAsFixed(1)),
        'pnn50': double.parse(pnn50.toStringAsFixed(1)),
        if (activityMg != null) 'act': double.parse(activityMg!.toStringAsFixed(1)),
      };

  factory HrvMeasurement.fromJson(Map<String, dynamic> j) => HrvMeasurement(
        time: DateTime.parse(j['t'] as String),
        seconds: (j['s'] as num).toInt(),
        beats: (j['n'] as num).toInt(),
        correctedPct: (j['corr'] as num).toDouble(),
        hr: (j['hr'] as num).toDouble(),
        rmssd: (j['rmssd'] as num).toDouble(),
        sdnn: (j['sdnn'] as num).toDouble(),
        pnn50: (j['pnn50'] as num).toDouble(),
        activityMg: (j['act'] as num?)?.toDouble(),
      );
}

/// Oblicza HRV z odstępów RR [ms]. Odrzuca odstępy fizjologicznie niemożliwe (< 300 / > 2000 ms) i różniące się
/// o > 20% od mediany 5 sąsiednich (artefakty, pobudzenia dodatkowe z pauzą); różnice kolejnych odstępów liczone
/// tylko między dwoma zachowanymi sąsiadami.
HrvMeasurement? computeHrv(List<double> rrMs, {required DateTime time, required int seconds, double? activityMg}) {
  if (rrMs.length < 20) return null;
  final keep = List<bool>.filled(rrMs.length, true);
  for (var i = 0; i < rrMs.length; i++) {
    final v = rrMs[i];
    if (v < 300 || v > 2000) {
      keep[i] = false;
      continue;
    }
    final nb = [for (var k = max(0, i - 2); k <= min(rrMs.length - 1, i + 2); k++) if (k != i) rrMs[k]]..sort();
    final med = nb[nb.length ~/ 2];
    if ((v - med).abs() > 0.2 * med) keep[i] = false;
  }
  final good = [for (var i = 0; i < rrMs.length; i++) if (keep[i]) rrMs[i]];
  if (good.length < 20) return null;
  final mean = good.reduce((a, b) => a + b) / good.length;
  final sdnn = sqrt(good.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / good.length);
  var ss = 0.0, n = 0, nn50 = 0;
  for (var i = 1; i < rrMs.length; i++) {
    if (!keep[i] || !keep[i - 1]) continue;
    final d = rrMs[i] - rrMs[i - 1];
    ss += d * d;
    n++;
    if (d.abs() > 50) nn50++;
  }
  if (n < 10) return null;
  return HrvMeasurement(
    time: time,
    seconds: seconds,
    beats: good.length,
    correctedPct: 100 * (rrMs.length - good.length) / rrMs.length,
    hr: 60000 / mean,
    rmssd: sqrt(ss / n),
    sdnn: sdnn,
    pnn50: 100 * nn50 / n,
    activityMg: activityMg,
  );
}

enum HrvStatus {
  low('poniżej Twojej normy'),
  normal('w Twojej normie'),
  high('powyżej Twojej normy'),
  unknown('za mało pomiarów do oceny');

  final String label;
  const HrvStatus(this.label);
}

/// Ocena względem własnej normy: średnia ± 0,5 SD ln RMSSD z wiarygodnych pomiarów z poprzednich 30 dni
/// (co najmniej 5) – podejście „najmniejszej istotnej zmiany” stosowane w monitorowaniu regeneracji.
({HrvStatus status, double? loMs, double? hiMs}) hrvBaseline(List<HrvMeasurement> history, HrvMeasurement m) {
  final from = m.time.subtract(const Duration(days: 30));
  final prev = [
    for (final h in history)
      if (h.reliable && h.time.isBefore(m.time) && h.time.isAfter(from)) h.lnRmssd
  ];
  if (prev.length < 5) return (status: HrvStatus.unknown, loMs: null, hiMs: null);
  final mean = prev.reduce((a, b) => a + b) / prev.length;
  final sd = sqrt(prev.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / prev.length);
  final swc = max(0.5 * sd, 0.05);
  final st = m.lnRmssd < mean - swc ? HrvStatus.low : (m.lnRmssd > mean + swc ? HrvStatus.high : HrvStatus.normal);
  return (status: st, loMs: exp(mean - swc), hiMs: exp(mean + swc));
}

/// Historia pomiarów porannych: `<katalog aplikacji>/hrv_morning.json`.
class HrvHistory {
  static const fileName = 'hrv_morning.json';

  static Future<List<HrvMeasurement>> load(Directory appDir) async {
    final f = File('${appDir.path}/$fileName');
    if (!f.existsSync()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      return [for (final j in list) HrvMeasurement.fromJson(j as Map<String, dynamic>)]
        ..sort((a, b) => a.time.compareTo(b.time));
    } catch (_) {
      return [];
    }
  }

  static Future<void> add(Directory appDir, HrvMeasurement m) async {
    final all = [...await load(appDir), m]..sort((a, b) => a.time.compareTo(b.time));
    await File('${appDir.path}/$fileName').writeAsString(jsonEncode([for (final h in all) h.toJson()]));
  }

  static Future<void> remove(Directory appDir, DateTime time) async {
    final all = (await load(appDir))..removeWhere((h) => h.time == time);
    await File('${appDir.path}/$fileName').writeAsString(jsonEncode([for (final h in all) h.toJson()]));
  }
}

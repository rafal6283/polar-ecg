import 'dart:convert';
import 'dart:io';

import 'package:health/health.dart';

import '../analysis/analysis_result.dart';
import '../analysis/analyzer.dart';
import '../analysis/hrv_session.dart';
import '../recording/recorder.dart';

/// Tętno minutowe z zapisu: (początek minuty, średnie tętno) – tylko minuty z ≥ 20 czytelnymi odstępami N–N.
List<(DateTime, double)> minuteHeartRate(AnalysisResult a) {
  final fs = a.sampleRate;
  final perMin = <int, List<double>>{};
  for (var i = 1; i < a.rPeaks.length; i++) {
    if (a.labels[i] == BeatType.unknown || a.labels[i - 1] == BeatType.unknown) continue;
    final rr = (a.rPeaks[i] - a.rPeaks[i - 1]) / fs;
    if (rr < 0.25 || rr > 2.5) continue;
    perMin.putIfAbsent(a.timeline.offsetOf(a.rPeaks[i]).inMinutes, () => []).add(rr);
  }
  final out = <(DateTime, double)>[];
  for (final e in perMin.entries.toList()..sort((x, y) => x.key.compareTo(y.key))) {
    if (e.value.length < 20) continue;
    out.add((a.timeline.started.add(Duration(minutes: e.key)), 60 * e.value.length / e.value.reduce((x, y) => x + y)));
  }
  return out;
}

/// Eksport do Health Connect (Android) / Zdrowia (iOS): tętno minutowe, tętno spoczynkowe, sen z akcelerometru,
/// poranne HRV (RMSSD w Health Connect, SDNN w Zdrowiu – Apple przyjmuje tylko SDNN). Wysłane zapisy są
/// pamiętane w `health_export.json`, a identyfikatory rekordów zapobiegają duplikatom.
class HealthExport {
  static const _stateFile = 'health_export.json';

  static List<HealthDataType> get _types => Platform.isIOS
      ? [HealthDataType.HEART_RATE, HealthDataType.RESTING_HEART_RATE, HealthDataType.HEART_RATE_VARIABILITY_SDNN,
          HealthDataType.SLEEP_ASLEEP]
      : [HealthDataType.HEART_RATE, HealthDataType.RESTING_HEART_RATE, HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
          HealthDataType.SLEEP_SESSION];

  /// Zwraca opis wyniku dla użytkownika.
  static Future<String> exportAll({void Function(String)? progress}) async {
    final health = Health();
    await health.configure();
    if (Platform.isAndroid && !await health.isHealthConnectAvailable()) {
      await health.installHealthConnect();
      return 'Zainstaluj lub zaktualizuj Health Connect i spróbuj ponownie.';
    }
    final types = _types;
    final ok = await health.requestAuthorization(types, permissions: [for (final _ in types) HealthDataAccess.WRITE]);
    if (!ok) return 'Brak zgody na zapis danych zdrowotnych.';

    final root = await Recorder.recordingsRoot();
    final state = File('${root.parent.path}/$_stateFile');
    final done = <String>{};
    if (state.existsSync()) {
      try {
        done.addAll((jsonDecode(state.readAsStringSync()) as List).cast<String>());
      } catch (_) {}
    }
    var recs = 0, points = 0;
    Future<void> write(HealthDataType type, double value, DateTime start, String id, [DateTime? end]) async {
      final res = await health.writeHealthData(
        value: value,
        type: type,
        startTime: start,
        endTime: end ?? start.add(const Duration(minutes: 1)),
        clientRecordId: 'polarekg-$id',
      );
      if (res) points++;
    }

    final dirs = root.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final d in dirs) {
      final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (done.contains('rec:$name')) continue;
      final a = await loadAnalysis(d.path);
      if (a == null) continue;
      progress?.call('Zapis $name…');
      for (final (t, hr) in minuteHeartRate(a)) {
        await write(HealthDataType.HEART_RATE, hr, t, '$name-${t.millisecondsSinceEpoch}');
      }
      final s = a.stats;
      final rest = s['hr_rest'];
      if (rest != null) await write(HealthDataType.RESTING_HEART_RATE, rest.toDouble(), a.timeline.started, '$name-rest');
      final s0 = s['sleep_start'], s1 = s['sleep_end'];
      if (s0 != null && s1 != null) {
        final from = a.timeline.timeOf(s0.toInt()), to = a.timeline.timeOf(s1.toInt());
        await write(Platform.isIOS ? HealthDataType.SLEEP_ASLEEP : HealthDataType.SLEEP_SESSION, 0, from,
            '$name-sleep', to);
      }
      done.add('rec:$name');
      recs++;
    }
    var hrv = 0;
    for (final m in await HrvHistory.load(root.parent)) {
      final key = 'hrv:${m.time.toIso8601String()}';
      if (done.contains(key) || !m.reliable) continue;
      await write(Platform.isIOS ? HealthDataType.HEART_RATE_VARIABILITY_SDNN : HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
          Platform.isIOS ? m.sdnn : m.rmssd, m.time, 'hrv-${m.time.millisecondsSinceEpoch}');
      done.add(key);
      hrv++;
    }
    await state.writeAsString(jsonEncode(done.toList()));
    if (recs == 0 && hrv == 0) return 'Brak nowych danych – wszystko zostało już wysłane.';
    return 'Wysłano: zapisy $recs, pomiary HRV $hrv ($points wartości).';
  }
}

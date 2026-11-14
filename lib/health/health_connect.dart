import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

import '../analysis/hrv_session.dart';
import '../analysis/night_minutes.dart';
import '../recording/recorder.dart';
import '../settings/app_settings.dart';

/// Zapis do Health Connect (Android): tętno minuta po minucie z zapisów, HRV (RMSSD) co 5 min
/// i z porannych pomiarów, tętno spoczynkowe. Inne aplikacje (np. Rytm Snu, Doba) widzą te dane.
class HealthConnect {
  static final _h = Health();
  static bool _configured = false;
  static const _types = [
    HealthDataType.HEART_RATE,
    HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    HealthDataType.RESTING_HEART_RATE,
  ];
  static const markerFile = 'health_connect.json';

  static bool get supported => Platform.isAndroid;

  static Future<void> _cfg() async {
    if (_configured) return;
    await _h.configure();
    _configured = true;
  }

  /// null = gotowe; inaczej komunikat dla użytkownika.
  static Future<String?> connect() async {
    if (!supported) return 'Health Connect jest tylko na Androidzie';
    try {
      await _cfg();
      final st = await _h.getHealthConnectSdkStatus();
      if (st != HealthConnectSdkStatus.sdkAvailable) {
        await _h.installHealthConnect();
        return 'Zainstaluj lub zaktualizuj Health Connect i spróbuj ponownie';
      }
      final ok = await _h.requestAuthorization(_types,
          permissions: [for (final _ in _types) HealthDataAccess.WRITE]);
      return ok ? null : 'Bez zgody na zapis tętna i HRV nie da się przesyłać danych';
    } catch (e) {
      return 'Health Connect: $e';
    }
  }

  static Future<bool> _write(double v, HealthDataType t, DateTime a, DateTime b) async {
    try {
      return await _h.writeHealthData(value: v, type: t, startTime: a, endTime: b, recordingMethod: RecordingMethod.automatic);
    } catch (e) {
      debugPrint('HC $t: $e');
      return false;
    }
  }

  /// Wysyła zapisy z ostatnich 30 dni, których jeszcze nie wysłano. Zwraca liczbę zapisów.
  static Future<int> pushPending() async {
    if (!supported || !AppSettings.instance.healthConnect) return 0;
    try {
      await _cfg();
      if (await _h.getHealthConnectSdkStatus() != HealthConnectSdkStatus.sdkAvailable) return 0;
    } catch (_) {
      return 0;
    }
    final root = await Recorder.recordingsRoot();
    final since = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    var n = 0;
    for (final d in root.listSync().whereType<Directory>()) {
      final mark = File('${d.path}/$markerFile');
      if (await mark.exists()) continue;
      final m = await loadMinuteSummary(d.path);
      final rows = (m?['minutes'] as List?)?.cast<List>();
      if (m == null || rows == null || rows.isEmpty) continue;
      if (((m['started_ms'] as num?) ?? 0) < since) continue;
      var ok = true;
      final hrv5 = <double>[];
      DateTime? hrvStart;
      for (final r in rows) {
        final end = DateTime.fromMillisecondsSinceEpoch((r[0] as num).toInt());
        final start = end.subtract(const Duration(minutes: 1));
        if (r[1] != null && r[6] != 1) ok &= await _write((r[1] as num).toDouble(), HealthDataType.HEART_RATE, start, end);
        if (r[2] != null && r[6] != 1) {
          hrvStart ??= start;
          hrv5.add((r[2] as num).toDouble());
        }
        if (hrvStart != null && end.difference(hrvStart).inMinutes >= 5) {
          if (hrv5.length >= 3) {
            ok &= await _write(hrv5.reduce((a, b) => a + b) / hrv5.length, HealthDataType.HEART_RATE_VARIABILITY_RMSSD, hrvStart, end);
          }
          hrv5.clear();
          hrvStart = null;
        }
      }
      if (ok) {
        await mark.writeAsString(jsonEncode({'at': DateTime.now().toIso8601String(), 'minutes': rows.length}));
        n++;
      }
    }
    return n;
  }

  /// Poranny pomiar HRV: RMSSD i tętno spoczynkowe.
  static Future<void> pushMorning(HrvMeasurement m) async {
    if (!supported || !AppSettings.instance.healthConnect || !m.reliable) return;
    try {
      await _cfg();
      final end = m.time.add(Duration(seconds: m.seconds));
      await _write(m.rmssd, HealthDataType.HEART_RATE_VARIABILITY_RMSSD, m.time, end);
      await _write(m.hr, HealthDataType.RESTING_HEART_RATE, m.time, end);
    } catch (_) {}
  }
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../analysis/analysis_result.dart';
import '../analysis/live_analyzer.dart';
import '../settings/app_settings.dart';

/// Alarmy w czasie rzeczywistym (wyłączalne w ustawieniach): powiadomienie z dźwiękiem
/// i/lub wibracją przy zdarzeniach z analizy na żywo i przekroczeniu progów tętna.
/// Każdy rodzaj alarmu ma okres wyciszenia, żeby nie powtarzał się co kilka sekund.
class AlarmService {
  final AppSettings settings;
  final _plugin = FlutterLocalNotificationsPlugin();
  final Map<String, DateTime> _lastFired = {};
  int _seenEvents = 0;
  bool _ready = false;
  int _id = 100;

  /// Ostatni alarm (do pokazania w aplikacji).
  String? lastAlarm;
  DateTime? lastAlarmTime;

  AlarmService(this.settings);

  Future<void> init() async {
    if (_ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
      _ready = true;
    } catch (e) {
      debugPrint('Powiadomienia niedostępne: $e');
    }
  }

  /// Nowa sesja analizy na żywo – zdarzenia liczone od początku.
  void reset() => _seenEvents = 0;

  /// Sprawdza stan analizy na żywo; wywoływane po każdym przeliczeniu (co 5 s).
  Future<void> check(LiveAnalyzer live) async {
    if (!settings.alarmsEnabled) {
      _seenEvents = live.events.length;
      return;
    }
    final hr = live.hrNow;
    if (hr != null && live.qualityPct >= 60) {
      if (hr > settings.alarmHrHigh) await _fire('hr_high', 'Wysokie tętno', '${hr.round()}/min');
      if (hr < settings.alarmHrLow) await _fire('hr_low', 'Niskie tętno', '${hr.round()}/min');
    }
    for (var i = _seenEvents; i < live.events.length; i++) {
      final e = live.events[i];
      final l = e.label;
      if (settings.alarmPause && l.startsWith(EventType.pause.label)) {
        await _fire('pause', 'Pauza w rytmie serca', l);
      } else if (settings.alarmAf && l.startsWith('Podejrzenie migotania')) {
        await _fire('af', 'Niemiarowy rytm', 'Podejrzenie migotania przedsionków');
      } else if (settings.alarmVt && (l.startsWith(EventType.vt.label) || l.startsWith(EventType.ivr.label))) {
        await _fire('vt', 'Salwa pobudzeń komorowych', l);
      } else if (settings.alarmContact && l == contactEventLabel) {
        await _fire('contact', 'Słaby kontakt elektrod', 'Sygnał zakłócony od ponad minuty – zwilż elektrody i popraw pasek',
            quiet: true, cooldownMin: 30);
      }
    }
    _seenEvents = live.events.length;
  }

  /// Alarm próbny (z ustawień); zwraca komunikat dla użytkownika, gdy powiadomienie nie może się pojawić.
  Future<String?> test() async {
    await _fire('test_${DateTime.now().millisecondsSinceEpoch}', 'Test alarmu', 'Tak będą wyglądać alarmy z analizy EKG');
    if (!_ready) return 'Powiadomienia niedostępne na tym urządzeniu';
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (await android?.areNotificationsEnabled() == false) {
        return 'Powiadomienia aplikacji są wyłączone – włącz je w ustawieniach systemu (Aplikacje → Polar EKG)';
      }
    }
    return null;
  }

  /// [quiet] – bez dźwięku i wibracji (np. w nocy nie budzi), tylko powiadomienie.
  Future<void> _fire(String kind, String title, String body, {bool quiet = false, double? cooldownMin}) async {
    final now = DateTime.now();
    final last = _lastFired[kind];
    if (last != null && now.difference(last).inSeconds < (cooldownMin ?? settings.alarmCooldownMin) * 60) return;
    _lastFired[kind] = now;
    lastAlarm = '$title: $body';
    lastAlarmTime = now;
    final sound = settings.alarmSound && !quiet, vibrate = settings.alarmVibrate && !quiet;
    if (vibrate) await HapticFeedback.heavyImpact();
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _id++,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            // Osobne kanały – Android zapamiętuje dźwięk/wibrację per kanał.
            quiet ? 'notice' : 'alarm_${sound ? 's' : ''}${vibrate ? 'v' : ''}',
            quiet ? 'Ostrzeżenia EKG' : 'Alarmy EKG',
            channelDescription: 'Alarmy z analizy rytmu serca w czasie rzeczywistym',
            importance: quiet ? Importance.defaultImportance : Importance.max,
            priority: quiet ? Priority.defaultPriority : Priority.high,
            playSound: sound,
            enableVibration: vibrate,
            category: AndroidNotificationCategory.alarm,
          ),
          iOS: DarwinNotificationDetails(presentSound: sound),
        ),
      );
    } catch (e) {
      debugPrint('Alarm: $e');
    }
  }
}

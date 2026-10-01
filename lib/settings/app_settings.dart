import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analysis/analyzer.dart';

/// Ustawienia aplikacji (trwałe, SharedPreferences).
class AppSettings extends ChangeNotifier {
  /// Wspólna instancja (ładowana w main).
  static final AppSettings instance = AppSettings();

  SharedPreferences? _p;

  // Profil osoby
  String name = '';
  int? birthYear;
  String sex = ''; // 'M', 'K' lub '' (nie podano)

  // Nagrywanie
  bool accEnabled = true;

  // Analiza
  double pauseSeconds = 2.0;
  double bradyBpm = 40;
  double tachyBpm = 120;
  double afMinSeconds = 30;
  bool usePersonal = true;

  // Alarmy w czasie rzeczywistym
  bool alarmsEnabled = false;
  double alarmHrHigh = 150;
  double alarmHrLow = 40;
  bool alarmPause = true;
  bool alarmAf = true;
  bool alarmVt = true;
  bool alarmSound = true;
  bool alarmVibrate = true;
  double alarmCooldownMin = 2;

  Future<void> load() async {
    final p = _p = await SharedPreferences.getInstance();
    name = p.getString('name') ?? name;
    birthYear = p.getInt('birthYear');
    sex = p.getString('sex') ?? sex;
    accEnabled = p.getBool('accEnabled') ?? accEnabled;
    pauseSeconds = p.getDouble('pauseSeconds') ?? pauseSeconds;
    bradyBpm = p.getDouble('bradyBpm') ?? bradyBpm;
    tachyBpm = p.getDouble('tachyBpm') ?? tachyBpm;
    afMinSeconds = p.getDouble('afMinSeconds') ?? afMinSeconds;
    usePersonal = p.getBool('usePersonal') ?? usePersonal;
    alarmsEnabled = p.getBool('alarmsEnabled') ?? alarmsEnabled;
    alarmHrHigh = p.getDouble('alarmHrHigh') ?? alarmHrHigh;
    alarmHrLow = p.getDouble('alarmHrLow') ?? alarmHrLow;
    alarmPause = p.getBool('alarmPause') ?? alarmPause;
    alarmAf = p.getBool('alarmAf') ?? alarmAf;
    alarmVt = p.getBool('alarmVt') ?? alarmVt;
    alarmSound = p.getBool('alarmSound') ?? alarmSound;
    alarmVibrate = p.getBool('alarmVibrate') ?? alarmVibrate;
    alarmCooldownMin = p.getDouble('alarmCooldownMin') ?? alarmCooldownMin;
    notifyListeners();
  }

  /// Zmienia ustawienie i zapisuje je trwale.
  Future<void> update(void Function(AppSettings s) change) async {
    change(this);
    notifyListeners();
    final p = _p ?? await SharedPreferences.getInstance();
    await Future.wait([
      p.setString('name', name),
      if (birthYear != null) p.setInt('birthYear', birthYear!) else p.remove('birthYear'),
      p.setString('sex', sex),
      p.setBool('accEnabled', accEnabled),
      p.setDouble('pauseSeconds', pauseSeconds),
      p.setDouble('bradyBpm', bradyBpm),
      p.setDouble('tachyBpm', tachyBpm),
      p.setDouble('afMinSeconds', afMinSeconds),
      p.setBool('usePersonal', usePersonal),
      p.setBool('alarmsEnabled', alarmsEnabled),
      p.setDouble('alarmHrHigh', alarmHrHigh),
      p.setDouble('alarmHrLow', alarmHrLow),
      p.setBool('alarmPause', alarmPause),
      p.setBool('alarmAf', alarmAf),
      p.setBool('alarmVt', alarmVt),
      p.setBool('alarmSound', alarmSound),
      p.setBool('alarmVibrate', alarmVibrate),
      p.setDouble('alarmCooldownMin', alarmCooldownMin),
    ]);
  }

  int? get age => birthYear == null ? null : DateTime.now().year - birthYear!;

  /// Górna granica QTc zależna od płci (mężczyźni 450, kobiety 460 ms).
  double get qtcUpper => sex == 'M' ? 450 : 460;

  AnalysisSettings get analysis => AnalysisSettings(
        pauseSeconds: pauseSeconds,
        bradyBpm: bradyBpm,
        tachyBpm: tachyBpm,
        afMinSeconds: afMinSeconds,
        usePersonal: usePersonal,
      );
}

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:path_provider/path_provider.dart';

import 'alarms/alarm_service.dart';
import 'analysis/analysis_result.dart';
import 'analysis/live_analyzer.dart';
import 'analysis/personal_profile.dart';
import 'ble/polar_h10.dart';
import 'ble/polar_protocol.dart';
import 'recording/recorder.dart';
import 'settings/app_settings.dart';

enum LinkState { disconnected, connecting, connected, reconnecting }

/// Bufor kołowy ostatnich próbek EKG do wykresu na żywo.
class EcgBuffer {
  static const capacity = ecgSampleRate * 20;
  final Float32List _data = Float32List(capacity);
  int total = 0; // liczba próbek od początku sesji

  // Filtr górnoprzepustowy ~0.5 Hz (usuwa dryf linii izoelektrycznej) – tylko do wyświetlania.
  double _prevIn = 0, _prevOut = 0;
  static final double _alpha = 1 / (1 + 2 * pi * 0.5 / ecgSampleRate);

  void addAll(List<int> samplesUv) {
    for (final s in samplesUv) {
      final x = s.toDouble();
      final y = total == 0 ? 0.0 : _alpha * (_prevOut + x - _prevIn);
      _prevIn = x;
      _prevOut = y;
      _data[total % capacity] = y;
      total++;
    }
  }

  /// Próbka o bezwzględnym indeksie (w µV, po filtrze).
  double at(int index) => _data[index % capacity];

  void clear() {
    total = 0;
    _prevIn = 0;
    _prevOut = 0;
  }
}

class AppController extends ChangeNotifier {
  final AppSettings settings;
  PersonalProfile? _profile;

  AppController(this.settings) : alarms = AlarmService(settings);

  final AlarmService alarms;

  PolarH10? device;
  LinkState link = LinkState.disconnected;
  String? error;

  final EcgBuffer ecg = EcgBuffer();
  int? heartRate;
  double? lastRr;
  bool? skinContact;
  int? battery;
  final List<double> _recentRr = [];

  LiveAnalyzer? live;
  Timer? _liveTimer;

  Recorder? recorder;
  bool get isRecording => recorder != null;

  bool _userDisconnect = false;
  final List<StreamSubscription> _subs = [];
  Timer? _uiTimer;

  /// RMSSD z ostatnich 30 odstępów RR [ms].
  double? get rmssd {
    if (_recentRr.length < 3) return null;
    var sum = 0.0;
    for (var i = 1; i < _recentRr.length; i++) {
      final d = _recentRr[i] - _recentRr[i - 1];
      sum += d * d;
    }
    return sqrt(sum / (_recentRr.length - 1));
  }

  Future<void> connect(BluetoothDevice bt) async {
    await PolarH10.stopScan();
    error = null;
    _userDisconnect = false;
    link = LinkState.connecting;
    notifyListeners();

    final dev = PolarH10(bt);
    device = dev;
    ecg.clear();
    _profile = await _loadProfile();
    live = _newLive();
    await alarms.init();
    _recentRr.clear();
    heartRate = null;
    lastRr = null;

    _subs.add(dev.ecg.listen((f) {
      ecg.addAll(f.samplesUv);
      live?.addSamples(f.samplesUv);
      recorder?.addEcg(f);
    }));
    _subs.add(dev.hr.listen((m) {
      heartRate = m.bpm;
      skinContact = m.skinContact;
      if (m.rrMs.isNotEmpty) {
        lastRr = m.rrMs.last;
        _recentRr.addAll(m.rrMs);
        while (_recentRr.length > 30) {
          _recentRr.removeAt(0);
        }
      }
      recorder?.addHr(m);
    }));
    _subs.add(dev.acc.listen((f) {
      live?.addAcc(f);
      recorder?.addAcc(f);
    }));

    try {
      await dev.connect();
      await dev.startEcg();
      if (settings.accEnabled) {
        try {
          await dev.startAcc();
        } catch (e) {
          debugPrint('Akcelerometr niedostępny: $e'); // EKG działa dalej bez niego
        }
      }
      battery = await dev.readBattery();
      link = LinkState.connected;
      _subs.add(dev.connectionState.listen(_onConnectionState));
      // Wykres odświeża się sam (Ticker); tu tylko liczby ~2x/s.
      _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => notifyListeners());
      _liveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _runLive());
    } catch (e) {
      error = 'Nie udało się połączyć: $e';
      await _teardown();
    }
    notifyListeners();
  }

  void _onConnectionState(BluetoothConnectionState s) {
    if (s == BluetoothConnectionState.disconnected && !_userDisconnect && link == LinkState.connected) {
      recorder?.addEvent('disconnected');
      _reconnectLoop();
    }
  }

  Future<void> _reconnectLoop() async {
    link = LinkState.reconnecting;
    notifyListeners();
    while (!_userDisconnect && device != null) {
      try {
        await device!.reconnect();
        link = LinkState.connected;
        recorder?.addEvent('reconnected');
        live?.markGap();
        notifyListeners();
        return;
      } catch (_) {
        await Future.delayed(const Duration(seconds: 3));
      }
    }
  }

  LiveAnalyzer _newLive() {
    alarms.reset();
    return LiveAnalyzer(ecgSampleRate, settings: settings.analysis, profile: _profile);
  }

  Future<PersonalProfile?> _loadProfile() async {
    if (!settings.usePersonal) return null;
    try {
      return await PersonalProfile.load(PersonalProfile.fileIn(await getApplicationDocumentsDirectory()));
    } catch (_) {
      return null;
    }
  }

  void _runLive() {
    try {
      final l = live;
      if (l != null && l.process()) {
        alarms.check(l);
        notifyListeners();
      }
    } catch (e, st) {
      debugPrint('Analiza na żywo: $e\n$st');
    }
  }

  Future<void> disconnect() async {
    _userDisconnect = true;
    if (isRecording) await stopRecording();
    try {
      await device?.disconnect();
    } catch (_) {}
    await _teardown();
    notifyListeners();
  }

  Future<void> _teardown() async {
    _uiTimer?.cancel();
    _liveTimer?.cancel();
    _liveTimer = null;
    _uiTimer = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    device?.dispose();
    device = null;
    link = LinkState.disconnected;
  }

  Future<void> startRecording() async {
    final dev = device;
    if (dev == null || isRecording) return;
    await _startForegroundService();
    recorder = await Recorder.start(deviceName: dev.name, deviceId: dev.id, withAcc: dev.accEnabled);
    live = _newLive(); // statystyki od początku nagrania
    notifyListeners();
  }

  /// Znacznik objawu w trwającym nagraniu (także w analizie na żywo jako zdarzenie).
  Future<void> addMarker(String symptom, String note) async {
    await recorder?.addMarker(symptom, note);
    live?.events.add(LiveEvent(DateTime.now(), 'Objaw: $symptom', Severity.medium));
    notifyListeners();
  }

  Future<void> stopRecording() async {
    final r = recorder;
    recorder = null;
    notifyListeners();
    await r?.stop();
    await FlutterForegroundTask.stopService();
  }

  // --- Usługa pierwszoplanowa: utrzymuje aplikację przy życiu przy wygaszonym ekranie ---

  static void initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ecg_recording',
        channelName: 'Zapis EKG',
        channelDescription: 'Widoczne podczas nagrywania EKG z opaski.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
      ),
    );
  }

  Future<void> _startForegroundService() async {
    if (!Platform.isAndroid) return; // iOS: tryb tła bluetooth-central w Info.plist
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
      notificationTitle: 'Nagrywanie EKG',
      notificationText: 'Zapis z opaski Polar H10 trwa',
      callback: foregroundStartCallback,
    );
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}

@pragma('vm:entry-point')
void foregroundStartCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

/// Pusta obsługa – cała praca z BLE odbywa się w głównym izolacie,
/// usługa służy tylko do tego, by system nie uśpił/zabił aplikacji.
class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

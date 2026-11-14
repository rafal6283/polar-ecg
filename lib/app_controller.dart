import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:path_provider/path_provider.dart';

import 'alarms/alarm_service.dart';
import 'analysis/analysis_result.dart';
import 'analysis/analyzer.dart';
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

  /// Odstępy RR [ms] z opaski w miarę napływu (np. prowadzony pomiar HRV).
  final StreamController<List<double>> _rrCtrl = StreamController.broadcast();
  Stream<List<double>> get rrStream => _rrCtrl.stream;

  @visibleForTesting
  void injectRr(List<double> rr) => _rrCtrl.add(rr);

  LiveAnalyzer? live;
  Timer? _liveTimer;

  Recorder? recorder;
  bool get isRecording => recorder != null;

  // --- Automatyczny zapis (rejestrator pętlowy) i tryb czuwania ---
  /// Ostatnie 3 min danych, gdy nic nie jest nagrywane – automatyczny zapis zaczyna się od nich.
  static const _preSec = 180;
  final List<EcgFrame> _preEcg = [];
  final List<HrMeasurement> _preHr = [];
  final List<AccFrame> _preAcc = [];

  /// Bieżące nagranie zostało uruchomione automatycznie (powód: [autoReason]).
  bool autoRecording = false;
  String? autoReason;
  DateTime? _lastAlertEvent; // ostatnie zdarzenie wysokiej wagi w czasie automatycznego zapisu
  int _autoSeen = 0;

  /// Tryb czuwania: opaska wysyła tylko tętno i odstępy RR (bez EKG – mniejszy pobór), aplikacja ocenia
  /// niemiarowość; przy podejrzeniu AF włącza EKG i automatyczny zapis.
  bool watching = false;
  DateTime? watchStarted;
  final List<double> _watchRr = []; // [s]
  int _watchNew = 0, _watchHits = 0;

  /// Ostatnia ocena okna RR w czuwaniu (do wyświetlenia).
  bool? watchIrregular;

  void _keepPre<T>(List<T> list, T item, DateTime Function(T) at) {
    list.add(item);
    final limit = DateTime.now().subtract(const Duration(seconds: _preSec));
    while (list.isNotEmpty && at(list.first).isBefore(limit)) {
      list.removeAt(0);
    }
  }

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

    _subs.add(
      dev.ecg.listen((f) {
        ecg.addAll(f.samplesUv);
        live?.addSamples(f.samplesUv);
        final r = recorder;
        if (r != null) {
          r.addEcg(f);
        } else {
          _keepPre(_preEcg, f, (x) => x.received);
        }
      }),
    );
    _subs.add(
      dev.hr.listen((m) {
        heartRate = m.bpm;
        skinContact = m.skinContact;
        if (m.rrMs.isNotEmpty) {
          lastRr = m.rrMs.last;
          _rrCtrl.add(m.rrMs);
          if (watching && !isRecording) {
            _watchCheck(m.rrMs);
          } else {
            live?.addDeviceRr(m.rrMs);
          }
          _recentRr.addAll(m.rrMs);
          while (_recentRr.length > 30) {
            _recentRr.removeAt(0);
          }
        }
        final r = recorder;
        if (r != null) {
          r.addHr(m);
        } else {
          _keepPre(_preHr, m, (x) => x.received);
        }
      }),
    );
    _subs.add(
      dev.acc.listen((f) {
        live?.addAcc(f);
        final r = recorder;
        if (r != null) {
          r.addAcc(f);
        } else {
          _keepPre(_preAcc, f, (x) => x.received);
        }
      }),
    );

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
      if (settings.lastDeviceId != dev.id) await settings.update((s) => s.lastDeviceId = dev.id);
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

  /// Połączenie z ostatnio używaną opaską bez skanowania (np. po uruchomieniu ze skrótu).
  Future<void> connectLast() async {
    if (settings.lastDeviceId.isEmpty || device != null) return;
    await connect(BluetoothDevice.fromId(settings.lastDeviceId));
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
        if (watching && !isRecording) await _ecgOff();
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
        _autoCheck(l);
        notifyListeners();
      }
    } catch (e, st) {
      debugPrint('Analiza na żywo: $e\n$st');
    }
  }

  Future<void> disconnect() async {
    _userDisconnect = true;
    watching = false;
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
    autoRecording = false;
    _clearPre();
    live = _newLive(); // statystyki od początku nagrania
    notifyListeners();
  }

  void _clearPre() {
    _preEcg.clear();
    _preHr.clear();
    _preAcc.clear();
  }

  /// Automatyczny zapis: nagranie zaczyna się od danych z bufora (do 3 min przed zdarzeniem); analiza na żywo
  /// nie jest zerowana (stan AF musi trwać, żeby wiedzieć, kiedy skończyć).
  Future<void> _startAuto(String reason) async {
    final dev = device;
    if (dev == null || isRecording) return;
    await _startForegroundService();
    var startedAt = DateTime.now();
    if (_preEcg.isNotEmpty) {
      final f = _preEcg.first;
      startedAt = f.received.subtract(Duration(microseconds: (f.samplesUv.length * 1e6 / ecgSampleRate).round()));
    }
    final r = await Recorder.start(
      deviceName: dev.name,
      deviceId: dev.id,
      withAcc: dev.accEnabled,
      startedAt: startedAt,
    );
    for (final f in _preEcg) {
      r.addEcg(f);
    }
    for (final m in _preHr) {
      r.addHr(m);
    }
    for (final f in _preAcc) {
      r.addAcc(f);
    }
    _clearPre();
    r.addEvent('auto $reason');
    recorder = r;
    autoRecording = true;
    autoReason = reason;
    _lastAlertEvent = DateTime.now();
    _autoSeen = live?.events.length ?? 0;
    notifyListeners();
  }

  /// Zdarzenia wymagające zapisu: podejrzenie AF, częstoskurcz komorowy, pauza ≥ 3 s (wysoka waga).
  static bool _isAlert(LiveEvent e) =>
      e.label.startsWith('Podejrzenie migotania') || (e.severity == Severity.high && !e.label.startsWith('Objaw'));

  void _autoCheck(LiveAnalyzer l) {
    final events = l.events;
    if (_autoSeen > events.length) _autoSeen = 0; // lista przycięta
    var alert = false;
    String? label;
    for (var i = _autoSeen; i < events.length; i++) {
      if (_isAlert(events[i])) {
        alert = true;
        label = events[i].label;
      }
    }
    _autoSeen = events.length;
    if (alert || l.afNow) _lastAlertEvent = DateTime.now();
    final cooled = _lastAutoEnd == null || DateTime.now().difference(_lastAutoEnd!) > const Duration(minutes: 10);
    if (!isRecording && settings.autoRecord && cooled && (alert || l.afNow)) {
      _startAuto(label ?? 'Podejrzenie migotania przedsionków');
      return;
    }
    // Koniec automatycznego zapisu: ≥ 3 min nagrania i 2 min bez AF / zdarzeń wysokiej wagi.
    final r = recorder;
    if (autoRecording &&
        r != null &&
        !l.afNow &&
        r.elapsed > const Duration(minutes: 3) &&
        DateTime.now().difference(_lastAlertEvent ?? DateTime.now()) > const Duration(minutes: 2)) {
      _finishAuto();
    }
  }

  DateTime? _lastAutoEnd;

  Future<void> _finishAuto() async {
    _lastAutoEnd = DateTime.now();
    final r = recorder;
    final reason = autoReason;
    await stopRecording();
    if (r != null) {
      await alarms.notice(
        'Zapisano automatycznie fragment EKG',
        '${reason ?? 'Zdarzenie'} – zapis ${r.elapsed.inMinutes} min w Zapisach',
      );
    }
    if (watching) await _ecgOff();
  }

  // --- Tryb czuwania ---

  Future<void> startWatch() async {
    final dev = device;
    if (dev == null || watching || isRecording) return;
    await _startForegroundService(text: 'Czuwanie – opaska monitoruje rytm (RR)');
    watching = true;
    watchStarted = DateTime.now();
    _watchRr.clear();
    _watchHits = 0;
    watchIrregular = null;
    await _ecgOff();
    notifyListeners();
  }

  Future<void> stopWatch() async {
    if (!watching) return;
    watching = false;
    final dev = device;
    if (dev != null && !isRecording) {
      try {
        await dev.startEcg();
        if (settings.accEnabled) await dev.startAcc();
      } catch (_) {}
      await FlutterForegroundTask.stopService();
    }
    live = _newLive();
    notifyListeners();
  }

  Future<void> _ecgOff() async {
    final dev = device;
    if (dev == null) return;
    try {
      await dev.stopEcg();
      if (dev.accEnabled) await dev.stopAcc();
    } catch (_) {}
    _clearPre();
  }

  /// Okno 32 odstępów RR co 4 nowe; 2 kolejne okna z cechami AF → EKG i automatyczny zapis.
  void _watchCheck(List<double> rrMs) {
    for (final v in rrMs) {
      _watchRr.add(v / 1000);
      _watchNew++;
    }
    while (_watchRr.length > 32) {
      _watchRr.removeAt(0);
    }
    if (_watchRr.length < 32 || _watchNew < 4) return;
    _watchNew = 0;
    final af = deviceRrWindowAf(_watchRr, cosenThreshold: settings.analysis.afCosen);
    watchIrregular = af;
    _watchHits = af ? _watchHits + 1 : 0;
    if (_watchHits >= 2 && settings.autoRecord) {
      _watchHits = 0;
      _watchTrigger();
    }
  }

  Future<void> _watchTrigger() async {
    final dev = device;
    if (dev == null || isRecording) return;
    try {
      await dev.startEcg();
      if (settings.accEnabled) await dev.startAcc();
    } catch (_) {}
    live = _newLive();
    await _startAuto('Podejrzenie migotania przedsionków (czuwanie, RR)');
    await alarms.alertAfFromWatch();
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
    autoRecording = false;
    notifyListeners();
    await r?.stop();
    if (!watching) await FlutterForegroundTask.stopService();
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

  Future<void> _startForegroundService({String text = 'Zapis z opaski Polar H10 trwa'}) async {
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
      notificationTitle: 'Polar EKG',
      notificationText: text,
      callback: foregroundStartCallback,
    );
  }

  @override
  void dispose() {
    _teardown();
    _rrCtrl.close();
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

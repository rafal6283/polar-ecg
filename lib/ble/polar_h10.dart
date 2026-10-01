import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'polar_protocol.dart';

/// Połączenie z jedną opaską Polar H10: EKG (PMD), tętno/RR, bateria.
class PolarH10 {
  static final pmdService = Guid('FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8');
  static final _pmdControl = Guid('FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8');
  static final _pmdData = Guid('FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8');
  static final _hrService = Guid('180D');
  static final _hrMeasurement = Guid('2A37');
  static final _batteryService = Guid('180F');
  static final _batteryLevel = Guid('2A19');

  final BluetoothDevice device;

  PolarH10(this.device);

  String get name => device.advName.isNotEmpty ? device.advName : device.platformName;
  String get id => device.remoteId.str;

  final _ecgCtrl = StreamController<EcgFrame>.broadcast();
  final _hrCtrl = StreamController<HrMeasurement>.broadcast();
  final _accCtrl = StreamController<AccFrame>.broadcast();
  Stream<EcgFrame> get ecg => _ecgCtrl.stream;
  Stream<AccFrame> get acc => _accCtrl.stream;
  bool accEnabled = false;
  Stream<HrMeasurement> get hr => _hrCtrl.stream;
  Stream<BluetoothConnectionState> get connectionState => device.connectionState;

  BluetoothCharacteristic? _control;
  BluetoothCharacteristic? _battery;
  final List<StreamSubscription> _subs = [];
  Completer<List<int>>? _pendingResponse;

  /// Skanuje w poszukiwaniu opasek Polar (nazwa zaczyna się od "Polar").
  static Future<void> startScan() => FlutterBluePlus.startScan(
        withKeywords: const ['Polar'],
        timeout: const Duration(seconds: 15),
      );

  static Future<void> stopScan() => FlutterBluePlus.stopScan();

  static Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  static Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  /// Łączy, wykrywa usługi i włącza powiadomienia. Nie startuje jeszcze EKG.
  Future<void> connect() async {
    await device.connect(
      license: License.nonprofit, // użytek prywatny; komercyjnie wymagana płatna licencja FBP
      timeout: const Duration(seconds: 15),
      mtu: Platform.isAndroid ? 232 : null,
    );
    await _setup();
  }

  Future<void> _setup() async {
    _cancelSubs();
    final services = await device.discoverServices();

    final pmd = services.where((s) => s.uuid == pmdService).firstOrNull;
    if (pmd == null) throw Exception('Urządzenie nie udostępnia EKG (brak usługi PMD).');
    final control = pmd.characteristics.firstWhere((c) => c.uuid == _pmdControl);
    final data = pmd.characteristics.firstWhere((c) => c.uuid == _pmdData);
    _control = control;

    final hrChar = services
        .where((s) => s.uuid == _hrService)
        .expand((s) => s.characteristics)
        .where((c) => c.uuid == _hrMeasurement)
        .firstOrNull;
    _battery = services
        .where((s) => s.uuid == _batteryService)
        .expand((s) => s.characteristics)
        .where((c) => c.uuid == _batteryLevel)
        .firstOrNull;

    _subs.add(control.onValueReceived.listen(_onControlResponse));
    await control.setNotifyValue(true);

    _subs.add(data.onValueReceived.listen((v) {
      if (v.isEmpty) return;
      if (v[0] == 0x00) {
        final frame = parseEcgFrame(v);
        if (frame != null) _ecgCtrl.add(frame);
      } else if (v[0] == 0x02) {
        final frame = parseAccFrame(v);
        if (frame != null) _accCtrl.add(frame);
      }
    }));
    await data.setNotifyValue(true);

    if (hrChar != null) {
      _subs.add(hrChar.onValueReceived.listen((v) {
        final m = parseHrMeasurement(v);
        if (m != null) _hrCtrl.add(m);
      }));
      await hrChar.setNotifyValue(true);
    }
  }

  void _onControlResponse(List<int> v) {
    // Odpowiedź: [0xF0, opCode, typPomiaru, kodBłędu, ...]
    if (v.isNotEmpty && v[0] == 0xF0) {
      final p = _pendingResponse;
      if (p != null && !p.isCompleted) p.complete(v);
    }
  }

  Future<void> _sendControl(List<int> cmd) async {
    final control = _control;
    if (control == null) throw StateError('Brak połączenia');
    final completer = Completer<List<int>>();
    _pendingResponse = completer;
    await control.write(cmd);
    final resp = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Opaska nie odpowiedziała na komendę'),
    );
    final error = resp.length > 3 ? resp[3] : 0;
    if (error != 0 && error != 6) {
      throw Exception('Opaska odrzuciła komendę: ${pmdErrorText(error)}');
    }
  }

  Future<void> startEcg() => _sendControl(pmdStartEcg);

  Future<void> stopEcg() => _sendControl(pmdStopEcg);

  Future<void> startAcc() async {
    await _sendControl(pmdStartAcc);
    accEnabled = true;
  }

  Future<void> stopAcc() async {
    accEnabled = false;
    await _sendControl(pmdStopAcc);
  }

  Future<int?> readBattery() async {
    final b = _battery;
    if (b == null) return null;
    final v = await b.read();
    return v.isEmpty ? null : v[0];
  }

  /// Ponowne połączenie po zerwaniu (np. wyjście poza zasięg).
  Future<void> reconnect() async {
    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 10),
      mtu: Platform.isAndroid ? 232 : null,
    );
    await _setup();
    await startEcg();
    if (accEnabled) await startAcc();
  }

  Future<void> disconnect() async {
    try {
      if (accEnabled) await stopAcc();
      await stopEcg();
    } catch (_) {}
    _cancelSubs();
    await device.disconnect();
  }

  void _cancelSubs() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  void dispose() {
    _cancelSubs();
    _ecgCtrl.close();
    _hrCtrl.close();
    _accCtrl.close();
  }
}

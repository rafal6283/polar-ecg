import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../ble/polar_protocol.dart';
import 'binary_format.dart';

/// Zapis sesji do katalogu recordings/RRRRMMDD_GGMMSS/:
///   ecg.bin     EKG (format binarny, patrz binary_format.dart)
///   acc.bin     akcelerometr x,y,z [mG] (jeśli włączony)
///   rr.csv      phone_ms,hr_bpm,rr_ms (odstępy RR z opaski)
///   events.csv  phone_ms,event (start, przerwy, ponowne połączenia)
///   markers.json znaczniki objawów
///   meta.json   urządzenie, start, koniec, liczba próbek
class Recorder {
  final Directory dir;
  final DateTime started;
  final String deviceName;
  final String deviceId;
  final BinaryStreamWriter _ecg;
  final BinaryStreamWriter? _acc;
  final IOSink _rr;
  final IOSink _events;
  int ecgSamples = 0;
  int accSamples = 0;
  int rrCount = 0;
  int? _lastFrameTs;
  int? lastEcgTimestampNs; // do wiązania znaczników objawów z sygnałem
  final List<Map<String, dynamic>> markers = [];

  Recorder._(this.dir, this.started, this.deviceName, this.deviceId, this._ecg, this._acc, this._rr, this._events);

  static Future<Directory> recordingsRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/recordings');
    await root.create(recursive: true);
    return root;
  }

  static Future<Recorder> start({required String deviceName, required String deviceId, bool withAcc = true}) async {
    final now = DateTime.now();
    final root = await recordingsRoot();
    final dir = Directory('${root.path}/${_stamp(now)}');
    await dir.create(recursive: true);
    final ecg = BinaryStreamWriter.create(File('${dir.path}/ecg.bin'), 'PECG', fs: ecgSampleRate, channels: 1, param: 14);
    final acc = withAcc
        ? BinaryStreamWriter.create(File('${dir.path}/acc.bin'), 'PACC', fs: accSampleRate, channels: 3, param: 8)
        : null;
    final rr = File('${dir.path}/rr.csv').openWrite()..writeln('phone_ms,hr_bpm,rr_ms');
    final events = File('${dir.path}/events.csv').openWrite()..writeln('phone_ms,event');
    final r = Recorder._(dir, now, deviceName, deviceId, ecg, acc, rr, events);
    await r._writeMeta(null);
    r.addEvent('start');
    return r;
  }

  void addEcg(EcgFrame f) {
    final n = f.samplesUv.length;
    const stepNs = 1000000000 ~/ ecgSampleRate;
    final firstTs = f.sensorTimestampNs - (n - 1) * stepNs;
    final last = _lastFrameTs;
    // Przerwa w danych większa niż ~0.5 s = utracone ramki (np. zerwane połączenie).
    if (last != null && firstTs - last > 500000000) {
      addEvent('gap ${((firstTs - last) / 1e9).toStringAsFixed(1)}s');
    }
    _ecg.addFrame(f.sensorTimestampNs, f.samplesUv);
    ecgSamples += n;
    _lastFrameTs = f.sensorTimestampNs;
    lastEcgTimestampNs = f.sensorTimestampNs;
  }

  void addAcc(AccFrame f) {
    _acc?.addFrame(f.sensorTimestampNs, f.xyz);
    accSamples += f.count;
  }

  void addHr(HrMeasurement m) {
    final t = m.received.millisecondsSinceEpoch;
    if (m.rrMs.isEmpty) {
      _rr.writeln('$t,${m.bpm},');
    } else {
      for (final rr in m.rrMs) {
        _rr.writeln('$t,${m.bpm},${rr.toStringAsFixed(1)}');
        rrCount++;
      }
    }
  }

  void addEvent(String event) {
    _events.writeln('${DateTime.now().millisecondsSinceEpoch},$event');
  }

  /// Znacznik objawu: zapisany z czasem telefonu i zegara opaski (do odnalezienia w sygnale).
  Future<void> addMarker(String symptom, String note) async {
    markers.add({
      'phone_ms': DateTime.now().millisecondsSinceEpoch,
      'sensor_ns': lastEcgTimestampNs,
      'symptom': symptom,
      'note': note,
    });
    addEvent('marker $symptom');
    await File('${dir.path}/markers.json').writeAsString(jsonEncode(markers));
  }

  Duration get elapsed => DateTime.now().difference(started);

  Future<void> stop() async {
    addEvent('stop');
    await _ecg.close();
    await _acc?.close();
    await Future.wait([_rr.flush(), _events.flush()]);
    await Future.wait([_rr.close(), _events.close()]);
    await _writeMeta(DateTime.now());
  }

  Future<void> _writeMeta(DateTime? ended) async {
    final meta = {
      'format': 'polar-ecg/2',
      'device_name': deviceName,
      'device_id': deviceId,
      'sample_rate_hz': ecgSampleRate,
      'unit': 'uV',
      'started': started.toIso8601String(),
      if (ended != null) 'ended': ended.toIso8601String(),
      'ecg_samples': ecgSamples,
      'acc_samples': accSamples,
      'acc_rate_hz': _acc == null ? null : accSampleRate,
      'rr_count': rrCount,
    };
    await File('${dir.path}/meta.json').writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
  }

  static String _stamp(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }
}

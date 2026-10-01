import 'dart:math';
import 'dart:typed_data';

import '../ble/polar_protocol.dart';
import 'analysis_result.dart';
import 'analyzer.dart';
import 'ecg_recording.dart';
import 'personal_profile.dart';

class LiveEvent {
  final DateTime time;
  final String label;
  final Severity severity;

  LiveEvent(this.time, this.label, this.severity);
}

/// Analiza w czasie rzeczywistym: co kilka sekund analizuje ostatnie 90 s sygnału
/// tym samym algorytmem co zapisy i dolicza nowe pobudzenia do statystyk sesji.
class LiveAnalyzer {
  final int fs;
  static const _windowSec = 90, _guardSec = 2;

  late final Float32List _ring = Float32List(fs * 180);
  int _total = 0; // próbek od początku sesji
  int _processed = 0; // koniec przeanalizowanego fragmentu (indeks bezwzględny)
  int _lastBeat = -1 << 40; // pozycja ostatniego policzonego pobudzenia
  DateTime _lastSampleTime = DateTime.now();
  final DateTime started = DateTime.now();

  // Statystyki sesji.
  int beats = 0, normal = 0, sv = 0, ve = 0, unknown = 0;
  double? hrNow, hrMin, hrMax;
  double _rrSum = 0;
  int _rrCount = 0;
  final List<double> _nn = []; // ostatnie odstępy NN [ms] (do SDNN/RMSSD)
  final List<double> _rr8 = [];
  bool afNow = false;
  double qualityPct = 100; // % czytelnych pobudzeń w ostatnim oknie
  DateTime? lastV, lastS;
  final List<LiveEvent> events = [];

  /// Parametry przebiegu z ostatniego okna (90 s).
  double? qrsMs, qtcMs, prMs, tPosPct;

  final AnalysisSettings settings;
  final PersonalProfile? profile;

  // Akcelerometr: aktywność (odch. std. modułu w ostatnich 2 s) i pozycja ciała.
  final List<double> _accMag = [];
  double? activityMg;
  List<double>? _gravity; // wolno zmienny kierunek grawitacji
  List<double>? _upright; // kierunek pionowy – uczony podczas chodzenia
  late final Float32List _actByWin = Float32List(180 ~/ 2)..fillRange(0, 90, -1);

  LiveAnalyzer(this.fs, {this.settings = const AnalysisSettings(), this.profile});

  /// W oknie 90 s nie ma stabilnego odniesienia dla ST – zmiany ST tylko w analizie całego zapisu.
  late final AnalysisSettings _windowSettings = settings.copyWith({'stDevUv': 0});

  /// Poziom aktywności słownie.
  String? get activityLabel {
    final a = activityMg;
    if (a == null) return null;
    if (a < 15) return 'spoczynek';
    if (a < 60) return 'lekki ruch';
    if (a < 200) return 'umiarkowany';
    return 'intensywny';
  }

  /// Pozycja ciała względem kierunku pionowego wyuczonego podczas chodzenia.
  String? get posture {
    final g = _gravity, u = _upright;
    if (g == null) return null;
    if (u == null) return 'nieznana (przejdź się chwilę)';
    final ng = sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
    if (ng == 0) return null;
    final cosA = (g[0] * u[0] + g[1] * u[1] + g[2] * u[2]) / ng;
    final angle = acos(cosA.clamp(-1.0, 1.0)) * 180 / pi;
    if (angle < 35) return 'pionowo';
    if (angle > 60) return 'leżąc';
    return 'pochylony / półleżąc';
  }

  void addAcc(AccFrame f) {
    for (var i = 0; i + 2 < f.xyz.length; i += 3) {
      final x = f.xyz[i].toDouble(), y = f.xyz[i + 1].toDouble(), z = f.xyz[i + 2].toDouble();
      _accMag.add(sqrt(x * x + y * y + z * z));
      final g = _gravity ??= [x, y, z];
      const a = 0.02; // filtr dolnoprzepustowy ~0.08 Hz przy 25 Hz
      g[0] += a * (x - g[0]);
      g[1] += a * (y - g[1]);
      g[2] += a * (z - g[2]);
    }
    while (_accMag.length > 2 * accSampleRate) {
      _accMag.removeAt(0);
    }
    if (_accMag.length >= accSampleRate) {
      final m = _accMag.reduce((a, b) => a + b) / _accMag.length;
      activityMg = sqrt(_accMag.map((v) => (v - m) * (v - m)).reduce((a, b) => a + b) / _accMag.length);
      _actByWin[(_total ~/ (2 * fs)) % _actByWin.length] = activityMg!;
      // Chodzenie (umiarkowany, rytmiczny ruch) => ciało pionowo: uczymy kierunek pionowy.
      final g = _gravity;
      if (g != null && activityMg! > 40 && activityMg! < 300) {
        final ng = sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
        if (ng > 0) {
          final u = _upright ??= [g[0] / ng, g[1] / ng, g[2] / ng];
          for (var k = 0; k < 3; k++) {
            u[k] += 0.01 * (g[k] / ng - u[k]);
          }
          final nu = sqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2]);
          for (var k = 0; k < 3; k++) {
            u[k] /= nu;
          }
        }
      }
    }
  }

  double? get hrMean => _rrCount == 0 ? null : 60000 / (_rrSum / _rrCount);
  Duration get elapsed => DateTime.now().difference(started);

  double? get rmssd {
    if (_nn.length < 10) return null;
    var s = 0.0;
    final from = max(1, _nn.length - 60);
    for (var i = from; i < _nn.length; i++) {
      final d = _nn[i] - _nn[i - 1];
      s += d * d;
    }
    return sqrt(s / (_nn.length - from));
  }

  double? get sdnn {
    if (_nn.length < 20) return null;
    final m = _nn.reduce((a, b) => a + b) / _nn.length;
    return sqrt(_nn.map((v) => (v - m) * (v - m)).reduce((a, b) => a + b) / (_nn.length - 1));
  }

  double get vPerHour => elapsed.inSeconds < 60 ? 0 : ve / (elapsed.inSeconds / 3600);

  void addSamples(List<int> uv) {
    for (final v in uv) {
      _ring[_total % _ring.length] = v.toDouble();
      _total++;
    }
    _lastSampleTime = DateTime.now();
  }

  /// Po zerwaniu połączenia sygnał nie jest ciągły – zaczynamy okno od nowa.
  void markGap() {
    _processed = _total;
    _lastBeat = _total;
  }

  DateTime _timeOf(int absSample) =>
      _lastSampleTime.subtract(Duration(microseconds: ((_total - absSample) * 1e6 / fs).round()));

  /// Wywoływane okresowo (np. co 5 s). Zwraca true, gdy statystyki się zmieniły.
  bool process() {
    final end = _total - _guardSec * fs;
    if (end - _processed < 3 * fs) return false;
    final start = max(max(0, _total - _ring.length), end - _windowSec * fs);
    final len = end - start;
    if (len < 10 * fs) return false;
    final window = Float32List(len);
    for (var i = 0; i < len; i++) {
      window[i] = _ring[(start + i) % _ring.length];
    }
    final win = 2 * fs;
    final act = activityMg == null
        ? null
        : Float32List.fromList([
            for (var w = 0; w * win < len; w++) _actByWin[((start + w * win) ~/ win) % _actByWin.length],
          ]);
    final res = analyzeEcg(window, Timeline(started, fs, [Segment(0, len, 0)]),
            settings: _windowSettings, profile: profile, activity: act)
        .result;
    final r = res.rPeaks;

    var clean = 0, inWindow = 0;
    for (var k = 0; k < r.length; k++) {
      final abs = start + r[k];
      if (r[k] > len - fs * 30) {
        inWindow++;
        if (res.labels[k] != BeatType.unknown) clean++;
      }
      // Pozycja tego samego R może się różnić o próbkę między oknami – liczymy po ostatnim policzonym.
      if (abs <= _lastBeat + fs * 0.2 || abs >= end) continue;
      _lastBeat = abs;
      beats++;
      switch (res.labels[k]) {
        case BeatType.normal:
          normal++;
        case BeatType.supraventricular:
          sv++;
          lastS = _timeOf(abs);
        case BeatType.ventricular:
          ve++;
          lastV = _timeOf(abs);
        default:
          unknown++;
      }
      if (k == 0 || res.labels[k] == BeatType.unknown || res.labels[k - 1] == BeatType.unknown) continue;
      final rr = (r[k] - r[k - 1]) * 1000 / fs;
      if (rr > 3000) continue;
      _rrSum += rr;
      _rrCount++;
      _rr8.add(rr);
      if (_rr8.length > 8) _rr8.removeAt(0);
      if (_rr8.length >= 4) {
        final s = [..._rr8]..sort();
        final hr = 60000 / s[s.length ~/ 2];
        hrNow = hr;
        hrMin = hrMin == null ? hr : min(hrMin!, hr);
        hrMax = hrMax == null ? hr : max(hrMax!, hr);
      }
      if (res.labels[k] == BeatType.normal && res.labels[k - 1] == BeatType.normal && res.inAf[k] == 0) {
        _nn.add(rr);
        if (_nn.length > 600) _nn.removeAt(0);
      }
    }
    qualityPct = inWindow == 0 ? 0 : 100 * clean / inWindow;
    double? stat(String k) => res.stats[k]?.toDouble();
    if (stat('qrs_ms') != null) {
      qrsMs = stat('qrs_ms');
      qtcMs = stat('qtc_ms');
      prMs = stat('pr_ms');
      tPosPct = stat('t_pos_pct');
    }

    // Zdarzenia zaczynające się w nowo przetworzonym fragmencie.
    for (final e in res.events) {
      final abs = start + e.startSample;
      if (abs < _processed || abs >= end) continue;
      if (e.type == EventType.af) continue; // AF raportujemy jako zmianę stanu poniżej
      events.add(LiveEvent(_timeOf(abs), '${e.type.label}${e.detail.isEmpty ? '' : ' (${e.detail})'}', e.severity));
    }
    final afWas = afNow;
    afNow = r.isNotEmpty && res.inAf[r.length - 1] == 1;
    if (afNow && !afWas) events.add(LiveEvent(_timeOf(end), 'Podejrzenie migotania przedsionków', Severity.high));
    if (!afNow && afWas) events.add(LiveEvent(_timeOf(end), 'Koniec niemiarowości', Severity.low));
    if (events.length > 50) events.removeRange(0, events.length - 50);

    _processed = end;
    return true;
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'ecg_recording.dart';

/// Typ pobudzenia (kod jak w MIT-BIH/AAMI).
class BeatType {
  static const normal = 0; // N
  static const supraventricular = 1; // S – przedwczesne nadkomorowe
  static const ventricular = 2; // V – komorowe
  static const unknown = 3; // Q – nieczytelne / artefakt

  static const letters = ['N', 'S', 'V', 'Q'];
}

enum Severity { low, medium, high }

enum EventType {
  af('Migotanie przedsionków', Severity.high),
  pause('Pauza', Severity.medium),
  vt('Częstoskurcz komorowy (nsVT)', Severity.high),
  ivr('Salwa pobudzeń komorowych', Severity.medium),
  couplet('Para pobudzeń komorowych', Severity.low),
  bigeminy('Bigeminia komorowa', Severity.low),
  trigeminy('Trigeminia komorowa', Severity.low),
  svt('Częstoskurcz nadkomorowy', Severity.medium),
  svRun('Salwa pobudzeń nadkomorowych', Severity.low),
  brady('Bradykardia', Severity.medium),
  tachy('Tachykardia', Severity.low);

  final String label;
  final Severity defaultSeverity;

  const EventType(this.label, this.defaultSeverity);
}

class EcgEvent {
  final EventType type;
  final int startSample;
  final int endSample;
  final Severity severity;
  final String detail;

  EcgEvent(this.type, this.startSample, this.endSample, this.detail, {Severity? severity})
      : severity = severity ?? type.defaultSeverity;

  Map<String, dynamic> toJson() => {
        't': type.name,
        's': startSample,
        'e': endSample,
        'sev': severity.name,
        'd': detail,
      };

  factory EcgEvent.fromJson(Map<String, dynamic> j) => EcgEvent(
        EventType.values.byName(j['t'] as String),
        j['s'] as int,
        j['e'] as int,
        j['d'] as String,
        severity: Severity.values.byName(j['sev'] as String),
      );
}

class AnalysisStats {
  final Map<String, num?> values;

  AnalysisStats(this.values);

  num? operator [](String k) => values[k];
}

class AnalysisResult {
  static const version = 3;

  final Timeline timeline;
  final Int32List rPeaks;
  final Uint8List labels; // BeatType
  final Uint8List inAf; // 1 = pobudzenie w epizodzie AF
  final List<List<int>> noisy; // [start, end) fragmentów z artefaktami
  final List<EcgEvent> events;
  final AnalysisStats stats;
  final DateTime analyzedAt;

  /// Uśredniony zespół (µV) i indeks R w nim – null, gdy za mało prawidłowych pobudzeń.
  final Float32List? template;
  final int templatePre;

  /// Prawdopodobieństwa klas z modelu [pN, pS, pV] na pobudzenie (null bez modelu).
  final Float32List? probs;

  /// Aktywność z akcelerometru [mg] w oknach 2 s (-1 = brak danych); null bez akcelerometru.
  final Float32List? activity;

  /// Ręczne poprawki uwzględnione w analizie: próbka R → etykieta (9 = usunięte).
  final Map<int, int> corrected;

  AnalysisResult({
    required this.timeline,
    required this.rPeaks,
    required this.labels,
    required this.inAf,
    required this.noisy,
    required this.events,
    required this.stats,
    required this.analyzedAt,
    this.template,
    this.templatePre = 0,
    this.probs,
    this.activity,
    this.corrected = const {},
  });

  /// Prawdopodobieństwo klasy [cls] (BeatType: 0 N, 1 S, 2 V) dla pobudzenia [i].
  double? prob(int i, int cls) => probs == null || cls > 2 ? null : probs![i * 3 + cls];

  int get sampleRate => timeline.sampleRate;

  int count(int type) => labels.where((l) => l == type).length;

  /// Indeks pierwszego pobudzenia o pozycji >= sample.
  int beatIndexAtOrAfter(num sample) {
    var lo = 0, hi = rPeaks.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (rPeaks[mid] < sample) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'analyzed_at': analyzedAt.toIso8601String(),
        'started': timeline.started.toIso8601String(),
        'sample_rate': timeline.sampleRate,
        'segments': [for (final s in timeline.segments) s.toJson()],
        'r_peaks': rPeaks,
        'labels': String.fromCharCodes(labels.map((l) => BeatType.letters[l].codeUnitAt(0))),
        'af': String.fromCharCodes(inAf.map((v) => v == 1 ? 0x31 : 0x30)),
        'noisy': noisy,
        'events': [for (final e in events) e.toJson()],
        'stats': stats.values,
        if (template != null) 'template': [for (final v in template!) v.round()],
        'template_pre': templatePre,
        if (probs != null) 'probs': base64Encode(Uint8List.fromList([for (final p in probs!) (p * 255).round()])),
        if (activity != null) 'activity': [for (final a in activity!) a.round()],
        'corrected': {for (final e in corrected.entries) '${e.key}': e.value},
      };

  factory AnalysisResult.fromJson(Map<String, dynamic> j) {
    final labelsStr = j['labels'] as String;
    final afStr = j['af'] as String;
    return AnalysisResult(
      timeline: Timeline(
        DateTime.parse(j['started'] as String),
        j['sample_rate'] as int,
        [for (final s in j['segments'] as List) Segment.fromJson(s as List)],
      ),
      rPeaks: Int32List.fromList((j['r_peaks'] as List).cast<int>()),
      labels: Uint8List.fromList([for (final c in labelsStr.codeUnits) BeatType.letters.indexOf(String.fromCharCode(c))]),
      inAf: Uint8List.fromList([for (final c in afStr.codeUnits) c == 0x31 ? 1 : 0]),
      noisy: [for (final r in j['noisy'] as List) (r as List).cast<int>()],
      events: [for (final e in j['events'] as List) EcgEvent.fromJson(e as Map<String, dynamic>)],
      stats: AnalysisStats((j['stats'] as Map<String, dynamic>).cast<String, num?>()),
      analyzedAt: DateTime.parse(j['analyzed_at'] as String),
      template: j['template'] == null
          ? null
          : Float32List.fromList([for (final v in j['template'] as List) (v as num).toDouble()]),
      templatePre: (j['template_pre'] as int?) ?? 0,
      probs: j['probs'] == null
          ? null
          : Float32List.fromList([for (final b in base64Decode(j['probs'] as String)) b / 255]),
      activity: j['activity'] == null
          ? null
          : Float32List.fromList([for (final v in j['activity'] as List) (v as num).toDouble()]),
      corrected: {
        for (final e in (j['corrected'] as Map<String, dynamic>? ?? {}).entries) int.parse(e.key): e.value as int
      },
    );
  }
}

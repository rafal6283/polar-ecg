import 'dart:math';

import 'analysis_result.dart';

/// Napad migotania przedsionków z okolicznościami: tętno komór w czasie AF i stan w 5 min przed początkiem
/// (tętno, pobudzenia dodatkowe, ruch). Okoliczności pomagają lekarzowi odróżnić napady „spoczynkowe/nocne”
/// (często przy wolnym rytmie) od „wysiłkowych” (po przyspieszeniu rytmu, przy ruchu).
class AfEpisode {
  final String recording; // nazwa katalogu zapisu
  final DateTime start, end;
  final int startSample, endSample;
  final double hrMean, hrMax; // tętno komór w AF (maks. – średnia z 30 s)

  /// 5 min przed napadem (tylko czytelne pobudzenia poza AF); null, gdy brak danych.
  final double? hrBefore, hrLastMin;
  final int sBefore, vBefore, sRunsBefore;
  final double? actBefore; // średnia aktywność [mg]
  final int contextSec; // ile sekund zapisu przed napadem było dostępne (maks. 300)
  final bool confirmed; // potwierdzony/dodany ręcznie przez użytkownika
  final bool fromStart, toEnd; // napad trwał (prawdopodobnie) już na początku / jeszcze na końcu zapisu

  AfEpisode({
    required this.recording,
    required this.start,
    required this.end,
    required this.startSample,
    required this.endSample,
    required this.hrMean,
    required this.hrMax,
    this.hrBefore,
    this.hrLastMin,
    this.sBefore = 0,
    this.vBefore = 0,
    this.sRunsBefore = 0,
    this.actBefore,
    this.contextSec = 0,
    this.fromStart = false,
    this.toEnd = false,
    this.confirmed = false,
  });

  Duration get duration => end.difference(start);

  /// Okoliczności początku napadu (opis, bez rozpoznania).
  List<String> get circumstances {
    final out = <String>[];
    if (fromStart) {
      out.add('trwał prawdopodobnie już przy rozpoczęciu zapisu');
      return out;
    }
    if (contextSec < 120) {
      out.add('za mało zapisu przed napadem');
      return out;
    }
    final h = start.hour;
    if (h >= 22 || h < 7) out.add('w nocy');
    final act = actBefore;
    if (act != null) {
      out.add(act < 15 ? 'w spoczynku' : (act < 60 ? 'przy lekkim ruchu' : 'przy wysiłku'));
    }
    final hb = hrBefore;
    if (hb != null) {
      if (hb < 60) {
        out.add('wolny rytm przed napadem (${hb.round()}/min)');
      } else if (hb > 100) {
        out.add('szybki rytm przed napadem (${hb.round()}/min)');
      }
      final hl = hrLastMin;
      if (hl != null && hl > hb * 1.15) out.add('przyspieszenie tuż przed napadem');
    }
    if (sRunsBefore > 0) {
      out.add('salwy pobudzeń S przed napadem');
    } else if (sBefore >= 5) {
      out.add('liczne pobudzenia S przed napadem ($sBefore)');
    }
    return out;
  }

  /// Typ okoliczności do zestawień: 'rest' (spoczynek/noc, wolny lub zwykły rytm), 'exertion' (ruch/szybki rytm),
  /// 'unknown'.
  String get pattern {
    if (fromStart || contextSec < 120) return 'unknown';
    final act = actBefore, hb = hrBefore;
    if ((act != null && act >= 60) || (hb != null && hb > 100)) return 'exertion';
    final night = start.hour >= 22 || start.hour < 7;
    if ((act != null && act < 15 || act == null && night) && (hb == null || hb < 85)) return 'rest';
    return 'unknown';
  }

  Map<String, dynamic> toJson() => {
        'rec': recording,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'ss': startSample,
        'es': endSample,
        'hr': _r1(hrMean),
        'hr_max': _r1(hrMax),
        if (hrBefore != null) 'hr_before': _r1(hrBefore!),
        if (hrLastMin != null) 'hr_last_min': _r1(hrLastMin!),
        's_before': sBefore,
        'v_before': vBefore,
        's_runs_before': sRunsBefore,
        if (actBefore != null) 'act_before': _r1(actBefore!),
        'context_s': contextSec,
        'from_start': fromStart,
        'to_end': toEnd,
        if (confirmed) 'ok': true,
      };

  factory AfEpisode.fromJson(Map<String, dynamic> j) => AfEpisode(
        recording: j['rec'] as String? ?? '',
        start: DateTime.parse(j['start'] as String),
        end: DateTime.parse(j['end'] as String),
        startSample: (j['ss'] as num?)?.toInt() ?? 0,
        endSample: (j['es'] as num?)?.toInt() ?? 0,
        hrMean: (j['hr'] as num).toDouble(),
        hrMax: (j['hr_max'] as num).toDouble(),
        hrBefore: (j['hr_before'] as num?)?.toDouble(),
        hrLastMin: (j['hr_last_min'] as num?)?.toDouble(),
        sBefore: (j['s_before'] as num?)?.toInt() ?? 0,
        vBefore: (j['v_before'] as num?)?.toInt() ?? 0,
        sRunsBefore: (j['s_runs_before'] as num?)?.toInt() ?? 0,
        actBefore: (j['act_before'] as num?)?.toDouble(),
        contextSec: (j['context_s'] as num?)?.toInt() ?? 0,
        fromStart: j['from_start'] as bool? ?? false,
        toEnd: j['to_end'] as bool? ?? false,
        confirmed: j['ok'] as bool? ?? false,
      );

  static double _r1(double v) => (v * 10).round() / 10;
}

/// Napady AF z wyniku analizy zapisu.
List<AfEpisode> afEpisodes(AnalysisResult a, {String recording = ''}) {
  final fs = a.sampleRate;
  final r = a.rPeaks;
  final out = <AfEpisode>[];
  const ctx = 300; // s przed napadem
  for (final e in a.events) {
    if (e.type != EventType.af) continue;
    final i0 = a.beatIndexAtOrAfter(e.startSample), i1 = a.beatIndexAtOrAfter(e.endSample + 1) - 1;
    if (i1 <= i0) continue;

    // Tętno komór w AF: średnie i maksymalne z okien 30 s.
    final hrMean = 60 * fs * (i1 - i0) / max(1, r[i1] - r[i0]);
    var hrMax = hrMean;
    for (var k = i0, j = i0; k < i1; k++) {
      while (j < i1 && r[j] - r[k] < 30 * fs) {
        j++;
      }
      if (r[j] - r[k] >= 25 * fs) hrMax = max(hrMax, 60 * fs * (j - k) / (r[j] - r[k]));
    }

    // Kontekst przed napadem (ten sam ciągły fragment zapisu).
    final segIdx = a.timeline.segmentIndexOf(e.startSample);
    final seg = a.timeline.segments[segIdx];
    final from = max(seg.start, e.startSample - ctx * fs);
    final contextSec = (e.startSample - from) ~/ fs;
    final rrAll = <double>[], rrLast = <double>[];
    var s = 0, v = 0, sRuns = 0, run = 0;
    for (var k = a.beatIndexAtOrAfter(from); k < i0; k++) {
      final l = a.labels[k];
      if (l == BeatType.supraventricular) {
        s++;
        run++;
        if (run == 3) sRuns++;
      } else {
        run = 0;
      }
      if (l == BeatType.ventricular) v++;
      if (k == 0 || r[k - 1] < from || a.inAf[k] == 1 || a.inAf[k - 1] == 1) continue;
      if (l == BeatType.unknown || a.labels[k - 1] == BeatType.unknown) continue;
      final rr = (r[k] - r[k - 1]) / fs;
      if (rr <= 0.25 || rr > 2.5) continue;
      rrAll.add(rr);
      if (r[k] >= e.startSample - 60 * fs) rrLast.add(rr);
    }
    double? hrOf(List<double> v) => v.length < 10 ? null : 60 * v.length / v.reduce((x, y) => x + y);

    double? act;
    final acc = a.activity;
    if (acc != null) {
      final w = 2 * fs;
      final vals = [
        for (var k = from ~/ w; k < e.startSample ~/ w && k < acc.length; k++)
          if (acc[k] >= 0) acc[k].toDouble()
      ];
      if (vals.length >= 10) act = vals.reduce((x, y) => x + y) / vals.length;
    }

    out.add(AfEpisode(
      recording: recording,
      start: a.timeline.timeOf(e.startSample),
      end: a.timeline.timeOf(e.endSample),
      startSample: e.startSample,
      endSample: e.endSample,
      hrMean: hrMean,
      hrMax: hrMax,
      hrBefore: hrOf(rrAll),
      hrLastMin: hrOf(rrLast),
      sBefore: s,
      vBefore: v,
      sRunsBefore: sRuns,
      actBefore: act,
      contextSec: contextSec,
      // < 30 s od początku zapisu – napad najpewniej trwał już wcześniej (pierwsze sekundy to zwykle zakłócenia
      // po założeniu opaski).
      fromStart: e.startSample - seg.start < 30 * fs && segIdx == 0,
      toEnd: seg.end - e.endSample < 10 * fs && segIdx == a.timeline.segments.length - 1,
      confirmed: a.afMarks.any((m) => m.af && m.overlaps(e.startSample, e.endSample)),
    ));
  }
  return out;
}

/// Zestawienie napadów AF z wielu zapisów (okres monitorowania = suma czasu zapisów).
class AfDiary {
  final List<AfEpisode> episodes;
  final double monitoredSec, afSec;

  /// Dzień (północ) → (monitorowane s, AF s).
  final Map<DateTime, (double, double)> days;

  AfDiary._(this.episodes, this.monitoredSec, this.afSec, this.days);

  /// [recs] – zapisy: początek, czas analizowany [s], napady.
  factory AfDiary.build(Iterable<({DateTime started, double seconds, List<AfEpisode> episodes})> recs) {
    final eps = <AfEpisode>[];
    final days = <DateTime, (double, double)>{};
    var mon = 0.0, af = 0.0;
    void addSpan(DateTime a, DateTime b, bool isAf) {
      var t = a;
      while (t.isBefore(b)) {
        final day = DateTime(t.year, t.month, t.day);
        final next = DateTime(t.year, t.month, t.day + 1);
        final stop = next.isBefore(b) ? next : b;
        final sec = stop.difference(t).inMilliseconds / 1000;
        final (m, f) = days[day] ?? (0.0, 0.0);
        days[day] = isAf ? (m, f + sec) : (m + sec, f);
        t = stop;
      }
    }

    for (final r in recs) {
      mon += r.seconds;
      addSpan(r.started, r.started.add(Duration(milliseconds: (r.seconds * 1000).round())), false);
      for (final e in r.episodes) {
        eps.add(e);
        af += e.duration.inMilliseconds / 1000;
        addSpan(e.start, e.end, true);
      }
    }
    eps.sort((a, b) => a.start.compareTo(b.start));
    return AfDiary._(eps, mon, af, days);
  }

  double? get burdenPct => monitoredSec <= 0 ? null : 100 * afSec / monitoredSec;

  AfEpisode? get longest =>
      episodes.isEmpty ? null : episodes.reduce((a, b) => a.duration >= b.duration ? a : b);

  /// Średnie tętno komór w AF (ważone czasem napadów).
  double? get hrInAf {
    var w = 0.0, s = 0.0;
    for (final e in episodes) {
      final d = e.duration.inMilliseconds / 1000;
      w += d;
      s += d * e.hrMean;
    }
    return w <= 0 ? null : s / w;
  }

  double? get hrMaxInAf => episodes.isEmpty ? null : episodes.map((e) => e.hrMax).reduce(max);

  /// Liczba początków napadów w każdej godzinie doby.
  List<int> get onsetHours {
    final h = List<int>.filled(24, 0);
    for (final e in episodes) {
      if (!e.fromStart) h[e.start.hour]++;
    }
    return h;
  }

  int countPattern(String p) => episodes.where((e) => e.pattern == p).length;

  int get withSBefore => episodes.where((e) => !e.fromStart && (e.sRunsBefore > 0 || e.sBefore >= 5)).length;
}

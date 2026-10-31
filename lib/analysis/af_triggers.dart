import 'dart:convert';
import 'dart:io';

import 'af_episodes.dart';
import 'hrv_session.dart';

/// Co poprzedza napady AF: dni z napadem i bez niego wobec snu (Rytm Snu), posiłków (Dziennik talerza),
/// ruchu (Doba) i porannego HRV. Dane z innych aplikacji przychodzą jako pliki „czynniki-dnia” v1
/// przez Koofr; napady – z zapisów Polar EKG i ze zdarzenia AFIB w Kresce. Czysty Dart.

String isoDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String shiftIso(String iso, int days) {
  final d = DateTime.parse('${iso}T12:00:00');
  return isoDay(DateTime(d.year, d.month, d.day + days, 12));
}

class TriggerDef {
  final String id, label, source;
  final int offset; // 0 = ten sam dzień, -1 = dzień wcześniej
  final bool Function(Map<String, num> row) test;
  const TriggerDef(this.id, this.label, this.source, this.offset, this.test);
}

const srcSleep = 'rytm-snu', srcMeals = 'dziennik-talerza', srcMove = 'doba', srcHrv = 'hrv';

final triggerDefs = <TriggerDef>[
  TriggerDef('short_sleep', 'Krótki sen (< 6 h)', srcSleep, 0, (r) => (r['sleep_min'] ?? 999) < 360),
  TriggerDef('bad_sleep', 'Słaba noc (ocena < 60)', srcSleep, 0, (r) => (r['score'] ?? 100) < 60),
  TriggerDef('apnea', 'Przerwy w oddechu ≥ 15/h', srcSleep, 0, (r) => (r['apnea_idx'] ?? 0) >= 15),
  TriggerDef('late_bed', 'Późne zaśnięcie (po 1:00)', srcSleep, 0, (r) {
    final h = r['bed_h'];
    return h != null && h >= 1 && h < 8;
  }),
  TriggerDef('alcohol_prev', 'Alkohol poprzedniego dnia', srcMeals, -1, (r) => (r['alcohol'] ?? 0) > 0),
  TriggerDef('alcohol', 'Alkohol tego dnia', srcMeals, 0, (r) => (r['alcohol'] ?? 0) > 0),
  TriggerDef('coffee', 'Kawa ≥ 3 razy', srcMeals, 0, (r) => (r['coffee'] ?? 0) >= 3),
  TriggerDef('late_dinner', 'Późna kolacja (po 21:00) dzień wcześniej', srcMeals, -1, (r) => (r['last_meal_h'] ?? 0) >= 21),
  TriggerDef('big_meal', 'Obfity posiłek (≥ 1000 kcal)', srcMeals, 0, (r) => (r['big_meal_kcal'] ?? 0) >= 1000),
  TriggerDef('active', 'Dużo ruchu (≥ 12 tys. kroków)', srcMove, 0, (r) => (r['steps'] ?? 0) >= 12000),
  TriggerDef('inactive', 'Mało ruchu (< 3 tys. kroków)', srcMove, 0, (r) => r['steps'] != null && r['steps']! < 3000),
  TriggerDef('sport', 'Trening ≥ 30 min', srcMove, 0, (r) => (r['sport_min'] ?? 0) >= 30),
  TriggerDef('sport_prev', 'Trening ≥ 30 min dzień wcześniej', srcMove, -1, (r) => (r['sport_min'] ?? 0) >= 30),
  TriggerDef('travel', 'Podróż ≥ 2 h', srcMove, 0, (r) => (r['travel_min'] ?? 0) >= 120),
  TriggerDef('hrv_low', 'HRV rano poniżej normy', srcHrv, 0, (r) => r['low'] == 1),
];

/// Źródło → data → wartości.
typedef FactorData = Map<String, Map<String, Map<String, num>>>;

/// Odczyt pliku „czynniki-dnia” v1: (źródło, dni).
(String, Map<String, Map<String, num>>)? parseFactors(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map || j['format'] != 'czynniki-dnia') return null;
    final days = <String, Map<String, num>>{};
    for (final d in (j['days'] as List? ?? const [])) {
      if (d is! Map || d['date'] is! String) continue;
      days[d['date'] as String] = {for (final e in d.entries) if (e.value is num) '${e.key}': e.value as num};
    }
    return ('${j['source']}', days);
  } catch (_) {
    return null;
  }
}

/// Zdarzenie AFIB z Kreski (plik „wymiana-zdarzen”, kind tracker): odcinki i początek prowadzenia.
({List<(DateTime, DateTime)> sessions, DateTime? since, DateTime? until, String name})? parseKreskaTracker(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map || j['format'] != 'wymiana-zdarzen' || j['source'] != 'kreska' || j['kind'] != 'tracker') return null;
    final s = <(DateTime, DateTime)>[];
    for (final e in (j['events'] as List? ?? const [])) {
      if (e is Map && e['start'] is num) {
        final a = DateTime.fromMillisecondsSinceEpoch((e['start'] as num).toInt());
        s.add((a, e['end'] is num ? DateTime.fromMillisecondsSinceEpoch((e['end'] as num).toInt()) : a));
      }
    }
    final w = (j['windows'] as List? ?? const []).whereType<Map>().toList();
    return (
      sessions: s,
      since: w.isEmpty || w.first['start'] is! num ? null : DateTime.fromMillisecondsSinceEpoch((w.first['start'] as num).toInt()),
      until: j['exported_at'] is num ? DateTime.fromMillisecondsSinceEpoch((j['exported_at'] as num).toInt()) : null,
      name: '${j['counter'] ?? ''}',
    );
  } catch (_) {
    return null;
  }
}

/// Czy zdarzenie z Kreski to migotanie (nazwa: AF, AFIB, migotanie, arytmia).
bool isAfTrackerName(String name) {
  final n = name.toLowerCase();
  return RegExp(r'\baf\b|afib|a-fib|migot|arytm').hasMatch(n);
}

class TriggerRow {
  final TriggerDef def;
  final int nWith, afWith, nWithout, afWithout;
  const TriggerRow(this.def, this.nWith, this.afWith, this.nWithout, this.afWithout);
  double get pWith => nWith == 0 ? 0 : afWith / nWith;
  double get pWithout => nWithout == 0 ? 0 : afWithout / nWithout;
  /// Ile razy częściej napad w dni z czynnikiem (∞ → 9).
  double get ratio => pWithout == 0 ? (pWith > 0 ? 9 : 1) : pWith / pWithout;
  bool get flagged => nWith >= 3 && afWith >= 2 && ratio >= 2;
}

class TriggerResult {
  final int days, afDays;
  final List<TriggerRow> rows;
  final Map<String, List<String>> beforeEpisodes; // dzień z napadem → czynniki obecne
  final Set<String> sources; // źródła z danymi
  const TriggerResult(this.days, this.afDays, this.rows, this.beforeEpisodes, this.sources);
}

/// [monitored] – dzień → (sekundy nagrania, sekundy AF) z zapisów Polar EKG.
/// [kreska] – napady zapisane w Kresce (start) i zakres dni, w których zdarzenie jest prowadzone.
TriggerResult afTriggers({
  required Map<DateTime, (double, double)> monitored,
  List<AfEpisode> episodes = const [],
  List<DateTime> kreskaStarts = const [],
  DateTime? kreskaSince,
  DateTime? kreskaUntil,
  required FactorData factors,
  double minMonitoredSec = 4 * 3600,
}) {
  final observed = <String>{};
  final af = <String>{};
  for (final e in monitored.entries) {
    final d = isoDay(e.key);
    if (e.value.$1 >= minMonitoredSec || e.value.$2 > 0) observed.add(d);
    if (e.value.$2 > 0) af.add(d);
  }
  for (final e in episodes) {
    af.add(isoDay(e.start));
    observed.add(isoDay(e.start));
  }
  if (kreskaSince != null) {
    final until = kreskaUntil ?? DateTime.now();
    for (var d = isoDay(kreskaSince); d.compareTo(isoDay(until)) <= 0; d = shiftIso(d, 1)) {
      observed.add(d);
    }
  }
  for (final t in kreskaStarts) {
    af.add(isoDay(t));
    observed.add(isoDay(t));
  }

  final rows = <TriggerRow>[];
  final sources = {for (final e in factors.entries) if (e.value.isNotEmpty) e.key};
  for (final def in triggerDefs) {
    final src = factors[def.source];
    if (src == null || src.isEmpty) continue;
    var nw = 0, aw = 0, no = 0, ao = 0;
    for (final d in observed) {
      final r = src[shiftIso(d, def.offset)];
      if (r == null) continue;
      final isAf = af.contains(d);
      if (def.test(r)) {
        nw++;
        if (isAf) aw++;
      } else {
        no++;
        if (isAf) ao++;
      }
    }
    if (nw + no >= 5 && nw >= 2) rows.add(TriggerRow(def, nw, aw, no, ao));
  }
  rows.sort((a, b) {
    final c = b.ratio.compareTo(a.ratio);
    return c != 0 ? c : b.nWith.compareTo(a.nWith);
  });

  final before = <String, List<String>>{};
  for (final d in (af.toList()..sort((a, b) => b.compareTo(a))).take(10)) {
    before[d] = [
      for (final def in triggerDefs)
        if (factors[def.source]?[shiftIso(d, def.offset)] case final r? when def.test(r)) def.label
    ];
  }
  return TriggerResult(observed.length, af.where(observed.contains).length, rows, before, sources);
}

/// Poranne HRV jako „czynnik dnia”: low = 1, gdy pomiar poniżej własnej normy.
Map<String, Map<String, num>> hrvFactors(List<HrvMeasurement> history) {
  final out = <String, Map<String, num>>{};
  for (final m in history) {
    if (!m.reliable) continue;
    final st = hrvBaseline(history, m).status;
    if (st == HrvStatus.unknown) continue;
    out[isoDay(m.time)] = {'low': st == HrvStatus.low ? 1 : 0};
  }
  return out;
}

// ---------- pliki z wymiany ----------

const exchangeDirName = 'wymiana';

Future<Directory> exchangeDir(Directory appDir) async {
  final d = Directory('${appDir.path}/$exchangeDirName');
  await d.create(recursive: true);
  return d;
}

/// Wczytuje wszystkie pobrane pliki: czynniki dnia i zdarzenie AF z Kreski.
Future<({FactorData factors, List<DateTime> kreskaStarts, DateTime? kreskaSince, DateTime? kreskaUntil})> loadExchange(Directory appDir) async {
  final dir = Directory('${appDir.path}/$exchangeDirName');
  final factors = <String, Map<String, Map<String, num>>>{};
  final starts = <DateTime>[];
  DateTime? since, until;
  if (await dir.exists()) {
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final text = await f.readAsString();
      final p = parseFactors(text);
      if (p != null) {
        factors[p.$1] = p.$2;
        continue;
      }
      final k = parseKreskaTracker(text);
      if (k != null && isAfTrackerName(k.name)) {
        starts.addAll(k.sessions.map((s) => s.$1));
        if (k.since != null && (since == null || k.since!.isBefore(since))) since = k.since;
        if (k.until != null) until = k.until;
      }
    }
  }
  return (factors: factors, kreskaStarts: starts, kreskaSince: since, kreskaUntil: until);
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'af_episodes.dart';

/// Grupa leku – decyduje o tym, czego pilnujemy w EKG.
enum MedClass {
  ic('Antyarytmiczny klasy IC (flekainid, propafenon)'),
  iii('Antyarytmiczny klasy III (amiodaron, sotalol, dronedaron)'),
  betaBlocker('Beta-bloker (np. metoprolol, bisoprolol)'),
  calcium('Bloker kanału wapniowego (werapamil, diltiazem)'),
  digoxin('Digoksyna'),
  anticoagulant('Przeciwkrzepliwy'),
  other('Inny');

  final String label;
  const MedClass(this.label);

  /// Leki poszerzające QRS (klasa IC) – ostrzeżenie przy wzroście QRS ≥ 25% względem normy.
  bool get widensQrs => this == MedClass.ic;

  /// Leki wydłużające QT (klasa III, częściowo IC).
  bool get prolongsQt => this == MedClass.iii || this == MedClass.ic;
}

class MedDef {
  final String name;
  final MedClass cls;
  final String dose; // np. „150 mg”
  final bool onDemand; // „tabletka w kieszeni” – przyjmowana przy napadzie
  const MedDef(this.name, this.cls, {this.dose = '', this.onDemand = false});

  Map<String, dynamic> toJson() => {'name': name, 'cls': cls.name, 'dose': dose, if (onDemand) 'od': true};
  factory MedDef.fromJson(Map<String, dynamic> j) => MedDef(
        j['name'] as String,
        MedClass.values.asNameMap()[j['cls']] ?? MedClass.other,
        dose: j['dose'] as String? ?? '',
        onDemand: j['od'] as bool? ?? false,
      );
}

/// Czynniki, które u wielu osób sprzyjają napadom AF (zaznaczane raz dziennie lub z godziną).
const journalTriggers = [
  'Alkohol',
  'Dużo kawy / energetyk',
  'Krótki sen (< 6 h)',
  'Stres',
  'Intensywny wysiłek',
  'Obfity posiłek',
  'Mało płynów',
  'Infekcja / gorączka',
];

/// Wpis: czynnik ([kind] 'trigger'), przyjęty lek ('med') albo notatka ('note').
class JournalEntry {
  final DateTime time;
  final String kind, name, note;
  const JournalEntry(this.time, this.kind, this.name, {this.note = ''});

  Map<String, dynamic> toJson() => {'t': time.toIso8601String(), 'k': kind, 'n': name, if (note.isNotEmpty) 'note': note};
  factory JournalEntry.fromJson(Map<String, dynamic> j) =>
      JournalEntry(DateTime.parse(j['t'] as String), j['k'] as String, j['n'] as String, note: j['note'] as String? ?? '');
}

/// Dziennik: `<katalog aplikacji>/journal.json` (też w kopii zapasowej).
class Journal {
  static const fileName = 'journal.json';
  final List<MedDef> meds;
  final List<JournalEntry> entries;
  Journal([List<MedDef>? meds, List<JournalEntry>? entries])
      : meds = meds ?? [],
        entries = entries ?? [];

  static Future<Journal> load(Directory appDir) async {
    final f = File('${appDir.path}/$fileName');
    if (!f.existsSync()) return Journal();
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return Journal(
        [for (final m in j['meds'] as List? ?? const []) MedDef.fromJson(m as Map<String, dynamic>)],
        [for (final e in j['entries'] as List? ?? const []) JournalEntry.fromJson(e as Map<String, dynamic>)]
          ..sort((a, b) => a.time.compareTo(b.time)),
      );
    } catch (_) {
      return Journal();
    }
  }

  Future<void> save(Directory appDir) async {
    entries.sort((a, b) => a.time.compareTo(b.time));
    await File('${appDir.path}/$fileName').writeAsString(jsonEncode({
      'meds': [for (final m in meds) m.toJson()],
      'entries': [for (final e in entries) e.toJson()],
    }));
  }

  MedDef? medNamed(String name) => meds.where((m) => m.name == name).firstOrNull;

  /// Czynnik zaznaczony danego dnia.
  bool hasTrigger(DateTime day, String name) => entries.any((e) =>
      e.kind == 'trigger' && e.name == name && e.time.year == day.year && e.time.month == day.month && e.time.day == day.day);
}

/// Monitorowanie z jednego zapisu (z summary.json): przedział czasu, napady, pobudzenia S na godzinę.
class MonitoredSpan {
  final DateTime start;
  final double seconds;
  final double? sPerH;
  final List<AfEpisode> episodes;
  final double? qrsMs, qtcMs;
  const MonitoredSpan(this.start, this.seconds, {this.sPerH, this.episodes = const [], this.qrsMs, this.qtcMs});
  DateTime get end => start.add(Duration(milliseconds: (seconds * 1000).round()));

  /// Z podsumowania zapisu (summary.json).
  factory MonitoredSpan.fromSummary(Map<String, dynamic> r) => MonitoredSpan(
        DateTime.parse(r['started'] as String),
        ((r['analyzed_s'] ?? r['duration_s'] ?? 0) as num).toDouble(),
        sPerH: (r['s_per_h'] as num?)?.toDouble(),
        qrsMs: (r['qrs_ms'] as num?)?.toDouble(),
        qtcMs: (r['qtc_ms'] as num?)?.toDouble(),
        episodes: [for (final e in r['af_episodes'] as List? ?? const []) AfEpisode.fromJson(e as Map<String, dynamic>)],
      );
}

/// Porównanie: monitorowanie do 24 h po czynniku vs pozostały czas.
class TriggerEffect {
  final String trigger;
  final int days; // ile dni z tym czynnikiem
  final double hoursWith, hoursWithout;
  final int afWith, afWithout; // napady (początki) w czasie po czynniku / bez
  final double? sWith, sWithout; // średnio S/h

  TriggerEffect(this.trigger, this.days, this.hoursWith, this.hoursWithout, this.afWith, this.afWithout, this.sWith,
      this.sWithout);

  double? get afRateWith => hoursWith < 1 ? null : afWith / hoursWith * 24;
  double? get afRateWithout => hoursWithout < 1 ? null : afWithout / hoursWithout * 24;

  /// Wystarczająco danych do porównania.
  bool get enough => days >= 2 && hoursWith >= 10 && hoursWithout >= 10;

  /// Wyraźnie więcej napadów lub pobudzeń S po czynniku (orientacyjnie: ≥ 2× i różnica bezwzględna).
  bool get suspicious {
    if (!enough) return false;
    final a = afRateWith ?? 0, b = afRateWithout ?? 0;
    final afUp = afWith >= 2 && a >= 2 * b + 0.2;
    final sUp = sWith != null && sWithout != null && sWith! >= 2 * sWithout! && sWith! - sWithout! >= 3;
    return afUp || sUp;
  }
}

/// Wpływ czynników: dla każdego czynnika czas monitorowania w ciągu 24 h po wpisie (dzienny czynnik bez godziny
/// – od jego chwili zapisu) i liczba napadów AF oraz pobudzenia S/h w tym czasie, w porównaniu z resztą.
List<TriggerEffect> triggerEffects(Journal j, List<MonitoredSpan> spans) {
  final out = <TriggerEffect>[];
  for (final t in journalTriggers) {
    final windows = [
      for (final e in j.entries)
        if (e.kind == 'trigger' && e.name == t) (e.time, e.time.add(const Duration(hours: 24)))
    ];
    if (windows.isEmpty) continue;
    final days = {for (final w in windows) DateTime(w.$1.year, w.$1.month, w.$1.day)}.length;
    bool inWin(DateTime x) => windows.any((w) => !x.isBefore(w.$1) && x.isBefore(w.$2));
    var hWith = 0.0, hWithout = 0.0, sW = 0.0, sWo = 0.0, sWh = 0.0, sWoh = 0.0;
    var afWith = 0, afWithout = 0;
    for (final s in spans) {
      // Część zapisu w oknach czynnika (krok 5 min – wystarczająco dokładnie).
      var inside = 0.0;
      const step = 300.0;
      for (var x = 0.0; x < s.seconds; x += step) {
        if (inWin(s.start.add(Duration(seconds: x.round())))) inside += min(step, s.seconds - x);
      }
      final h1 = inside / 3600, h0 = (s.seconds - inside) / 3600;
      hWith += h1;
      hWithout += h0;
      if (s.sPerH != null) {
        sW += s.sPerH! * h1;
        sWh += h1;
        sWo += s.sPerH! * h0;
        sWoh += h0;
      }
      for (final e in s.episodes) {
        if (e.fromStart) continue;
        inWin(e.start) ? afWith++ : afWithout++;
      }
    }
    out.add(TriggerEffect(t, days, hWith, hWithout, afWith, afWithout, sWh > 0 ? sW / sWh : null,
        sWoh > 0 ? sWo / sWoh : null));
  }
  return out;
}

/// Przyjęcie leku w czasie napadu: ile minut od dawki do końca napadu.
class DoseOutcome {
  final JournalEntry dose;
  final AfEpisode episode;
  const DoseOutcome(this.dose, this.episode);

  /// Minuty od dawki do końca napadu; null, gdy napad trwał jeszcze na końcu zapisu.
  int? get minutesToEnd => episode.toEnd ? null : max(0, episode.end.difference(dose.time).inMinutes);
}

/// Dawki przyjęte w trakcie napadu (od 6 h przed końcem do końca) – czas do ustąpienia.
List<DoseOutcome> doseOutcomes(Journal j, List<AfEpisode> episodes) => [
      for (final d in j.entries)
        if (d.kind == 'med')
          for (final e in episodes)
            if (!d.time.isBefore(e.start.subtract(const Duration(minutes: 10))) && d.time.isBefore(e.end))
              DoseOutcome(d, e),
    ];

/// Ocena przewodzenia przy lekach: QRS względem własnej normy (mediana zapisów sprzed pierwszej dawki leku
/// poszerzającego QRS, a gdy ich brak – 3 najwcześniejszych zapisów) i QTc.
class ConductionCheck {
  final double? qrsBase, qrsLast, qtcLast;
  final DateTime? lastAt;
  final List<String> warnings;
  const ConductionCheck(this.qrsBase, this.qrsLast, this.qtcLast, this.lastAt, this.warnings);

  double? get qrsChangePct => qrsBase == null || qrsLast == null ? null : 100 * (qrsLast! / qrsBase! - 1);
}

ConductionCheck conductionCheck(Journal j, List<MonitoredSpan> spans) {
  final withQrs = [for (final s in spans) if (s.qrsMs != null && s.seconds >= 60) s]
    ..sort((a, b) => a.start.compareTo(b.start));
  if (withQrs.isEmpty) return const ConductionCheck(null, null, null, null, []);
  final ic = j.meds.where((m) => m.cls.widensQrs).map((m) => m.name).toSet();
  final qt = j.meds.where((m) => m.cls.prolongsQt).map((m) => m.name).toSet();
  final firstIc = j.entries.where((e) => e.kind == 'med' && ic.contains(e.name)).map((e) => e.time).firstOrNull;
  var base = [for (final s in withQrs) if (firstIc == null || s.start.isBefore(firstIc)) s.qrsMs!];
  if (base.length < 3) base = [for (final s in withQrs.take(3)) s.qrsMs!];
  base.sort();
  final qrsBase = base[base.length ~/ 2];
  final last = withQrs.last;
  final warnings = <String>[];
  final pct = 100 * (last.qrsMs! / qrsBase - 1);
  if (ic.isNotEmpty && pct >= 25) {
    warnings.add('QRS ${last.qrsMs!.round()} ms – szerszy o ${pct.round()}% niż Twoja norma '
        '(${qrsBase.round()} ms). Przy flekainidzie/propafenonie to sygnał do konsultacji z lekarzem.');
  } else if (last.qrsMs! >= 120 && qrsBase < 110) {
    warnings.add('QRS ${last.qrsMs!.round()} ms (norma < 120 ms) – szerszy niż zwykle u Ciebie.');
  }
  final qtc = last.qtcMs;
  if (qtc != null && qtc >= 500) {
    warnings.add('QTc ${qtc.round()} ms (≥ 500 ms) – skonsultuj z lekarzem, zwłaszcza przy lekach wydłużających QT.');
  } else if (qtc != null && qt.isNotEmpty && qtc >= 480) {
    warnings.add('QTc ${qtc.round()} ms – na granicy przy leku wydłużającym QT.');
  }
  return ConductionCheck(qrsBase, last.qrsMs, qtc, last.start, warnings);
}

import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/af_episodes.dart';
import 'package:polar_ecg/analysis/journal.dart';
import 'package:polar_ecg/analysis/sv_trend.dart';

AfEpisode ep(DateTime s, int min, {bool toEnd = false}) => AfEpisode(
    recording: 'r', start: s, end: s.add(Duration(minutes: min)), startSample: 0, endSample: 0,
    hrMean: 120, hrMax: 140, contextSec: 300, toEnd: toEnd);

void main() {
  final d0 = DateTime(2026, 11, 1, 8);
  // 10 dni po 20 h zapisu; napady tylko w dni po alkoholu (dni 2, 5, 8 – wpis wieczorem dzień wcześniej).
  final spans = [
    for (var d = 0; d < 10; d++)
      MonitoredSpan(d0.add(Duration(days: d)), 20 * 3600.0,
          sPerH: [2, 5, 8].contains(d) ? 30 : 5,
          qrsMs: d < 5 ? 90 : 118,
          qtcMs: 440,
          episodes: [2, 5, 8].contains(d) ? [ep(d0.add(Duration(days: d, hours: 3)), 40)] : []),
  ];
  final j = Journal([const MedDef('Flekainid', MedClass.ic, dose: '100 mg')], [
    for (final d in [2, 5, 8]) JournalEntry(d0.add(Duration(days: d - 1, hours: 13)), 'trigger', 'Alkohol'),
    JournalEntry(d0.add(const Duration(days: 0, hours: 12)), 'trigger', 'Stres'),
    JournalEntry(d0.add(const Duration(days: 5)), 'med', 'Flekainid'),
    JournalEntry(d0.add(const Duration(days: 8, hours: 3, minutes: 10)), 'med', 'Flekainid'),
  ]);

  test('czynniki: alkohol podejrzany, stres – za mało danych', () {
    final ef = triggerEffects(j, spans);
    final alc = ef.firstWhere((e) => e.trigger == 'Alkohol');
    expect(alc.days, 3);
    expect(alc.afWith, 3);
    expect(alc.afWithout, 0);
    expect(alc.suspicious, isTrue);
    expect(ef.firstWhere((e) => e.trigger == 'Stres').enough, isFalse);
  });

  test('lek w czasie napadu: minuty do ustąpienia', () {
    final out = doseOutcomes(j, [for (final s in spans) ...s.episodes]);
    expect(out, hasLength(1));
    expect(out.first.minutesToEnd, 30);
  });

  test('QRS: +31% przy flekainidzie -> ostrzeżenie', () {
    final c = conductionCheck(j, spans);
    expect(c.qrsBase, 90);
    expect(c.qrsLast, 118);
    expect(c.warnings, isNotEmpty);
    final noMed = conductionCheck(Journal(), spans);
    expect(noMed.warnings, isEmpty); // 118 ms < 120 – bez leku nie ostrzegamy
  });

  test('trend S/h: wzrost względem normy', () {
    final base = DateTime(2026, 11, 1);
    final recs = [for (var d = 0; d < 8; d++) (base.add(Duration(days: d)), 3.0 + d % 2, 8.0)];
    expect(svTrend(recs).elevated, isFalse);
    expect(svTrend([...recs, (base.add(const Duration(days: 9)), 14.0, 6.0)]).elevated, isTrue);
    expect(svTrend(recs.take(3).toList()).norm, isNull);
  });
}

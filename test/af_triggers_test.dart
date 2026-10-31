import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/af_triggers.dart';

void main() {
  test('czynniki dnia: odczyt pliku', () {
    final p = parseFactors('{"format":"czynniki-dnia","version":1,"source":"rytm-snu","days":[{"date":"2026-10-01","sleep_min":300,"score":55}]}')!;
    expect(p.$1, 'rytm-snu');
    expect(p.$2['2026-10-01']!['sleep_min'], 300);
    expect(parseFactors('{"format":"inny"}'), isNull);
  });

  test('zdarzenie AFIB z Kreski', () {
    final k = parseKreskaTracker('{"format":"wymiana-zdarzen","version":1,"source":"kreska","kind":"tracker","counter":"AFIB",'
        '"exported_at":1790000000000,"windows":[{"start":1780000000000,"end":1790000000000}],'
        '"events":[{"id":"t1-0","type":"session","start":1785000000000,"end":1785003600000}]}')!;
    expect(k.sessions.length, 1);
    expect(isAfTrackerName(k.name), isTrue);
    expect(isAfTrackerName('Posiedzenia'), isFalse);
    expect(isAfTrackerName('Migotanie'), isTrue);
  });

  test('krótki sen częściej przed napadem', () {
    final monitored = <DateTime, (double, double)>{};
    final sleep = <String, Map<String, num>>{};
    final meals = <String, Map<String, num>>{};
    for (var i = 0; i < 20; i++) {
      final d = DateTime(2026, 10, 1 + i);
      final short = i % 4 == 0; // 5 dni z krótkim snem
      final af = short ? i != 12 : i == 3; // 4 z 5 krótkich nocy z napadem, 1 z 15 pozostałych
      monitored[d] = (8 * 3600.0, af ? 600.0 : 0.0);
      sleep[isoDay(d)] = {'sleep_min': short ? 300 : 450, 'score': 80};
      meals[isoDay(d.subtract(const Duration(days: 1)))] = {'alcohol': i == 7 ? 1 : 0};
    }
    final r = afTriggers(monitored: monitored, factors: {srcSleep: sleep, srcMeals: meals});
    expect(r.days, 20);
    expect(r.afDays, 5);
    final short = r.rows.firstWhere((x) => x.def.id == 'short_sleep');
    expect((short.nWith, short.afWith, short.nWithout, short.afWithout), (5, 4, 15, 1));
    expect(short.flagged, isTrue);
    expect(r.rows.first.def.id, 'short_sleep');
    expect(r.rows.any((x) => x.def.id == 'alcohol_prev'), isFalse); // tylko 1 dzień z alkoholem
    expect(r.beforeEpisodes.values.where((l) => l.contains('Krótki sen (< 6 h)')).length, 4);
  });
}

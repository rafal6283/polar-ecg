import 'package:flutter_test/flutter_test.dart';
import 'package:koofr_backup_ui/koofr_backup_ui.dart';
import 'package:polar_ecg/analysis/af_triggers.dart';
import 'package:polar_ecg/recording/koofr_backup.dart';
import 'package:polar_ecg/report/pdf_report.dart';

/// Kontrakt wymiany (WYMIANA.md w repozytorium Rytmu Snu) z perspektywy Polar EKG.
void main() {
  final sources = [for (final s in polarExchangeSources) s.$1];

  test('każdy pobierany plik wczytuje się bez wyjątku', () {
    final pulled = przykladyDlaZrodel(sources);
    expect(pulled, containsAll(['czynniki-sen', 'czynniki-posilki', 'czynniki-ruch', 'czynniki-leki', 'kreska-z-afib']));
    expect(pulled, isNot(contains('kreska-ff'))); // licznik FF nie dotyczy Polar EKG
    for (final n in pulled) {
      final text = wymianaPrzyklady[n]!;
      if (n.startsWith('czynniki-')) {
        expect(parseFactors(text), isNotNull, reason: n);
      } else {
        expect(parseKreskaTracker(text), isNotNull, reason: n);
      }
    }
  });

  test('pliki, z których Polar EKG korzysta, są wśród pobieranych', () {
    for (final p in kontraktWymiany.where((p) => p.odbiorcy.contains('polar-ekg'))) {
      expect(sources.any((s) => zrodloPasuje(s, p.przyklad)), isTrue, reason: p.nazwa);
    }
  });

  test('źródła czynników zgadzają się z tymi, których szuka analiza napadów', () {
    final (sleep, days) = parseFactors(wymianaPrzyklady['czynniki-sen']!)!;
    expect(sleep, srcSleep);
    expect(days['2025-11-19']!['sleep_min'], 412);
    expect(parseFactors(wymianaPrzyklady['czynniki-posilki']!)!.$1, srcMeals);
    expect(parseFactors(wymianaPrzyklady['czynniki-ruch']!)!.$1, srcMove);
    expect(parseFactors(wymianaPrzyklady['czynniki-leki']!)!.$1, srcMeds);
    expect(parseFactors(wymianaPrzyklady['czynniki-forma']!)!.$1, srcTrain);
    // kawa po 14:00 z pory ostatniej kawy (Dziennik talerza)
    final meals = parseFactors(wymianaPrzyklady['czynniki-posilki']!)!.$2['2025-11-19']!;
    expect(triggerDefs.firstWhere((d) => d.id == 'late_coffee').test(meals), isTrue);
    final t = parseKreskaTracker(wymianaPrzyklady['kreska-z-afib']!)!;
    expect(isAfTrackerName(t.name), isTrue);
    expect(t.sessions, hasLength(1));
  });

  test('wspólny raport: wiersz dnia z danymi z innych aplikacji', () {
    final f = <String, Map<String, Map<String, num>>>{};
    for (final n in ['czynniki-sen', 'czynniki-posilki', 'czynniki-ruch', 'czynniki-leki', 'czynniki-forma']) {
      final p = parseFactors(wymianaPrzyklady[n]!)!;
      f[p.$1] = p.$2;
    }
    final rows = otherAppsRows(f, DateTime(2025, 11, 18), DateTime(2025, 11, 20, 8));
    expect(rows, hasLength(1)); // dni bez danych pominięte
    expect(rows.single, ['19.11', '6 h 52', '78', '4,2/h', '2,1/h', '2/2', '1', '2', '8450', '32 min']);
    expect(rows.single, hasLength(otherAppsHeader.length));
  });
}

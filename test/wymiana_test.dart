import 'package:flutter_test/flutter_test.dart';
import 'package:koofr_backup_ui/koofr_backup_ui.dart';
import 'package:polar_ecg/analysis/af_triggers.dart';
import 'package:polar_ecg/recording/koofr_backup.dart';

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
}

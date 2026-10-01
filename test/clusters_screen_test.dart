import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/analysis_result.dart';
import 'package:polar_ecg/analysis/analyzer.dart';
import 'package:polar_ecg/ui/viewer/clusters_screen.dart';

import 'synthetic_ecg.dart';

void main() {
  testWidgets('ekran grup: grupa komorowa -> „Prawidłowe” zwraca poprawki V->N', (tester) async {
    final s = SyntheticEcg(seed: 2)
      ..sinus(30)
      ..withPvcs(60);
    final x = s.render();
    final out = analyzeEcg(x, s.timeline(x.length));
    Map<int, int>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            result = await Navigator.of(ctx).push<Map<int, int>>(
              MaterialPageRoute(builder: (_) => ClustersScreen(analysis: out.result, signal: out.filtered)),
            );
          },
          child: const Text('otwórz'),
        ),
      ),
    ));
    await tester.tap(find.text('otwórz'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // przejście do ekranu
    expect(find.text('Grupy morfologii'), findsOneWidget);
    // Grupowanie w osobnym izolacie – czekamy w czasie rzeczywistym.
    for (var k = 0; k < 300 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; k++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'grupowanie nie skończyło się');
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('komorowa'), findsWidgets);
    await tester.tap(find.text('Prawidłowe').first);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Zastosuj'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // animacja pojawienia się przycisku
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump(const Duration(seconds: 1));
    expect(result, isNotNull);
    expect(result!.values.every((l) => l == BeatType.normal), isTrue);
    expect(result!.length, greaterThanOrEqualTo(5));
  });
}

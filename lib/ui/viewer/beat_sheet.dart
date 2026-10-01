import 'package:flutter/material.dart';

import '../../analysis/analysis_result.dart';
import '../../analysis/analyzer.dart';
import 'ecg_strip_view.dart';
import 'format.dart';

/// Panel weryfikacji pojedynczego pobudzenia. Zwraca wybraną etykietę
/// (BeatType lub [correctionDelete]), -1 = cofnij poprawkę, null = bez zmian.
Future<int?> showBeatSheet(BuildContext context, AnalysisResult a, int k, {int? currentCorrection}) {
  final fs = a.sampleRate;
  final r = a.rPeaks;
  final t = Theme.of(context).textTheme;
  final scheme = Theme.of(context).colorScheme;
  int? rrMs(int i) => (i > 0 && i < r.length && a.timeline.segmentIndexOf(r[i]) == a.timeline.segmentIndexOf(r[i - 1]))
      ? ((r[i] - r[i - 1]) * 1000 / fs).round()
      : null;
  final label = a.labels[k];
  const names = ['Prawidłowe (N)', 'Nadkomorowe (S)', 'Komorowe (V)', 'Nieczytelne (Q)'];

  Widget choice(BuildContext ctx, String text, int value, Color color) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: value == label ? color.withValues(alpha: 0.35) : null,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: () => Navigator.pop(ctx, value),
            child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          ),
        ),
      );

  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${names[label]}${a.inAf[k] == 1 ? ' · w migotaniu' : ''}', style: t.titleLarge),
        Text('${fmtClock(a.timeline.timeOf(r[k]))}  ·  pobudzenie ${k + 1} z ${r.length}', style: t.labelMedium),
        const SizedBox(height: 10),
        Wrap(spacing: 16, runSpacing: 4, children: [
          Text('RR przed: ${rrMs(k) ?? '–'} ms'),
          Text('RR po: ${rrMs(k + 1) ?? '–'} ms'),
          if (rrMs(k) != null && rrMs(k - 1) != null)
            Text('przedwczesność: ${(100 * rrMs(k)! / rrMs(k - 1)!).round()}% poprzedniego'),
        ]),
        if (a.probs != null) ...[
          const SizedBox(height: 8),
          Text('Model: N ${(100 * a.prob(k, 0)!).round()}% · S ${(100 * a.prob(k, 1)!).round()}% · '
              'V ${(100 * a.prob(k, 2)!).round()}%'),
        ],
        if (currentCorrection != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Poprawione ręcznie', style: t.labelMedium?.copyWith(color: scheme.primary)),
          ),
        const SizedBox(height: 14),
        Text('Oznacz jako:', style: t.labelLarge),
        const SizedBox(height: 6),
        Row(children: [
          choice(ctx, 'N', BeatType.normal, beatColor(BeatType.normal, scheme)),
          choice(ctx, 'S', BeatType.supraventricular, beatColor(BeatType.supraventricular, scheme)),
          choice(ctx, 'V', BeatType.ventricular, beatColor(BeatType.ventricular, scheme)),
          choice(ctx, 'Artefakt', BeatType.unknown, scheme.outline),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: const Text('To nie jest uderzenie'),
              onPressed: () => Navigator.pop(ctx, correctionDelete),
            ),
          ),
          if (currentCorrection != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.undo),
                label: const Text('Cofnij poprawkę'),
                onPressed: () => Navigator.pop(ctx, -1),
              ),
            ),
          ],
        ]),
      ]),
    ),
  );
}

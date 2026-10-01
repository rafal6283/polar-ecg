import 'package:flutter/material.dart';

import '../analysis/reference_ranges.dart';

/// Legenda: objaśnienia parametrów przebiegu i pojęć używanych w aplikacji.
class LegendScreen extends StatelessWidget {
  const LegendScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Legenda')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Parametry przebiegu', style: t.titleMedium),
          const SizedBox(height: 4),
          Text('W nawiasach – zakres referencyjny dla spoczynkowego EKG dorosłych.', style: t.bodySmall),
          const SizedBox(height: 8),
          for (final p in waveformParams) _Entry(
            title: '${p.label}${p.unit.isEmpty ? '' : ' [${p.unit}]'}${p.rated ? '   (${p.rangeText})' : ''}',
            body: p.description,
          ),
          const SizedBox(height: 16),
          Text('Pojęcia', style: t.titleMedium),
          const SizedBox(height: 8),
          for (final (title, body) in glossary) _Entry(title: title, body: body),
          const SizedBox(height: 16),
          Text(
            'Analiza automatyczna z jednego odprowadzenia, do użytku własnego – nie zastępuje badania '
            'i oceny lekarza.',
            style: t.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  final String title, body;

  const _Entry({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: t.titleSmall),
        const SizedBox(height: 2),
        Text(body, style: t.bodyMedium),
      ]),
    );
  }
}

/// Krótkie objaśnienie jednego parametru (po stuknięciu w wiersz tabeli).
void showParamInfo(BuildContext context, ParamSpec p) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(p.label, style: Theme.of(ctx).textTheme.titleLarge),
        if (p.rated) Text('Zakres referencyjny: ${p.rangeText} ${p.unit}', style: Theme.of(ctx).textTheme.labelMedium),
        const SizedBox(height: 12),
        Text(p.description),
      ]),
    ),
  );
}

import 'package:flutter/material.dart';

import '../analysis/af_personal.dart';
import '../analysis/analyzer.dart';
import '../recording/recorder.dart';
import '../settings/app_settings.dart';
import 'theme/app_theme.dart';

/// Ustawienia: progi wykrywania AF dopasowane do ręcznych oznaczeń napadów (potwierdzone / „to nie AF”).
class AfPersonalSection extends StatefulWidget {
  final AppSettings settings;
  const AfPersonalSection({super.key, required this.settings});

  @override
  State<AfPersonalSection> createState() => _AfPersonalSectionState();
}

class _AfPersonalSectionState extends State<AfPersonalSection> {
  bool _busy = false;
  String? _progress;
  AfFit? _last;

  Future<void> _fit() async {
    setState(() {
      _busy = true;
      _progress = 'Zbieranie oznaczeń…';
    });
    try {
      final root = await Recorder.recordingsRoot();
      final fit = await fitFromRecordings(root, reanalyze: (p) async {
        if (mounted) setState(() => _progress = 'Analiza zapisu ${p.split('/').last}…');
        await analyzeInBackground(p, widget.settings.analysis);
      });
      if (fit.accepted) {
        await widget.settings.update((s) {
          s.afPersonalCosen = fit.cosen;
          s.afPersonalPCorr = fit.pCorr;
          s.afPersonalOn = true;
        });
      }
      _last = fit;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nie udało się: $e')));
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _progress = null;
      });
    }
  }

  Future<void> _reset() => widget.settings.update((s) {
        s.afPersonalCosen = null;
        s.afPersonalPCorr = null;
      });

  String _pct(double v) => '${(v * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    const d = AnalysisSettings();
    final has = s.afPersonalCosen != null && s.afPersonalPCorr != null;
    final f = _last;
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
        leading: const Icon(Icons.favorite_border),
        title: const Text('Wykrywanie AF dopasowane do Ciebie'),
        subtitle: Text(has
            ? 'Dopasowane progi: nieregularność ${s.afPersonalCosen!.toStringAsFixed(1)} '
                '(domyślnie ${d.afCosen.toStringAsFixed(1)}), załamek P ${s.afPersonalPCorr!.toStringAsFixed(2)} '
                '(domyślnie ${d.afPCorr.toStringAsFixed(2)}).'
            : 'Progi domyślne. Oznaczaj w zapisach napady („Potwierdź AF”, „To nie AF”, „Dodaj AF”) – '
                'przy kilku oznaczeniach obu rodzajów aplikacja dobierze progi pod Ciebie.'),
      ),
      if (has)
        SwitchListTile(
          title: const Text('Używaj dopasowanych progów'),
          subtitle: const Text('Wyłączone – progi domyślne (sprawdzone na bazach MIT-BIH/afdb/ltafdb).'),
          value: s.afPersonalOn,
          onChanged: (v) => s.update((x) => x.afPersonalOn = v),
        ),
      if (f != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (f.accepted ? AppColors.of(context).ok : AppColors.of(context).warning).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f.accepted ? 'Progi dopasowane' : 'Progi bez zmian', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                'Zapisy z oznaczeniami: ${f.recordings} · napady: ${f.marksAf} · odrzucone: ${f.marksNo}\n'
                'Okna analizy: ${f.posWindows} z AF, ${f.negWindows} bez AF\n'
                'Zgodność z oznaczeniami: domyślne ${_pct(f.defaultScore)}'
                '${f.accepted ? ' → dopasowane ${_pct(f.bestScore)}' : ''}',
                style: muted,
              ),
              if (f.reason != null) ...[const SizedBox(height: 4), Text(f.reason!, style: muted)],
            ]),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _fit,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.tune),
            label: Text(_busy ? (_progress ?? 'Dopasowywanie…') : 'Dopasuj teraz'),
          ),
          if (has && !_busy) TextButton(onPressed: _reset, child: const Text('Przywróć domyślne')),
        ]),
      ),
      ListTile(
        dense: true,
        subtitle: Text('Nowe progi działają w analizie na żywo i w nowych analizach; starsze zapisy – „Analizuj ponownie”. '
            'Ręczne oznaczenia zawsze mają pierwszeństwo przed automatem.', style: muted),
      ),
    ]);
  }
}

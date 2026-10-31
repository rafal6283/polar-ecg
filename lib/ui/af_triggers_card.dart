import 'package:flutter/material.dart';

import '../analysis/af_triggers.dart';
import '../analysis/hrv_session.dart';
import '../recording/recorder.dart';
import 'af_diary_card.dart' show diaryFromSummaries;
import 'theme/app_theme.dart';

/// Co poprzedza napady AF: sen (Rytm Snu), posiłki (Dziennik talerza), ruch (Doba), poranne HRV.
class AfTriggersCard extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final List<HrvMeasurement> hrv;
  const AfTriggersCard({super.key, required this.rows, required this.hrv});

  @override
  State<AfTriggersCard> createState() => _AfTriggersCardState();
}

class _AfTriggersCardState extends State<AfTriggersCard> {
  TriggerResult? _r;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AfTriggersCard old) {
    super.didUpdateWidget(old);
    if (old.rows != widget.rows || old.hrv != widget.hrv) _load();
  }

  Future<void> _load() async {
    final appDir = (await Recorder.recordingsRoot()).parent;
    final ex = await loadExchange(appDir);
    final d = diaryFromSummaries(widget.rows);
    final factors = <String, Map<String, Map<String, num>>>{...ex.factors, srcHrv: hrvFactors(widget.hrv)};
    final r = afTriggers(
      monitored: d.days,
      episodes: d.episodes,
      kreskaStarts: ex.kreskaStarts,
      kreskaSince: ex.kreskaSince,
      kreskaUntil: ex.kreskaUntil,
      factors: factors,
    );
    if (mounted) setState(() => _r = r);
  }

  String _pct(double v) => '${(v * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final t = Theme.of(context).textTheme;
    final colors = AppColors.of(context);
    final muted = t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    if (r == null) return const SizedBox.shrink();
    final external = r.sources.difference({srcHrv});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('Co poprzedza napady'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (external.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                    'Włącz wymianę danych przez Koofr w Rytmie Snu (sen), Dzienniku talerza (posiłki) i Dobie (ruch) – '
                    'wtedy zobaczysz, czy napady częściej zdarzają się np. po krótkiej nocy albo alkoholu. '
                    'Zdarzenie AFIB z Kreski uzupełnia dni bez zapisu EKG.',
                    style: muted),
              ),
            Text('Dni z obserwacją: ${r.days} · z napadem: ${r.afDays}', style: t.titleSmall),
            Text(
              [
                'Źródła: zapisy EKG',
                if (r.sources.contains(srcSleep)) 'Rytm Snu',
                if (r.sources.contains(srcMeals)) 'Dziennik talerza',
                if (r.sources.contains(srcMove)) 'Doba',
                if (r.sources.contains(srcHrv)) 'poranne HRV',
              ].join(', '),
              style: muted,
            ),
            const SizedBox(height: 8),
            if (r.afDays < 3)
              Text('Potrzeba co najmniej 3 dni z napadem, żeby porównywać. Do tej pory: ${r.afDays}.', style: muted)
            else if (r.rows.isEmpty)
              Text('Za mało dni z danymi z innych aplikacji (potrzeba co najmniej 5).', style: muted)
            else
              for (final row in r.rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(row.def.label, style: TextStyle(fontWeight: row.flagged ? FontWeight.w700 : null)),
                        Text(
                          'napad w ${row.afWith} z ${row.nWith} dni (${_pct(row.pWith)}) · bez tego: ${row.afWithout} z ${row.nWithout} (${_pct(row.pWithout)})',
                          style: muted,
                        ),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    StatusPill(
                      icon: row.flagged ? Icons.priority_high : Icons.compare_arrows,
                      text: row.ratio >= 9 ? 'tylko z tym' : '×${row.ratio.toStringAsFixed(1).replaceAll('.', ',')}',
                      color: row.flagged ? colors.danger : (row.ratio >= 1.5 ? colors.warning : colors.ok),
                    ),
                  ]),
                ),
            if (r.beforeEpisodes.values.any((l) => l.isNotEmpty)) ...[
              const Divider(height: 20),
              Text('Przed ostatnimi napadami', style: t.titleSmall),
              for (final e in r.beforeEpisodes.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${e.key}: ${e.value.isEmpty ? 'nic z listy' : e.value.join(', ')}', style: muted),
                ),
            ],
            const SizedBox(height: 8),
            Text(
                'Porównanie dni, nie dowód przyczyny – przy kilku napadach to tylko trop do obserwacji. '
                'Pogrubione: napad co najmniej 2 razy częściej, przy 3+ dniach z czynnikiem i 2+ napadach. '
                'Wnioski warto omówić z kardiologiem.',
                style: muted),
          ]),
        ),
      ),
    ]);
  }
}

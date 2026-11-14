import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../analysis/analysis_result.dart';
import '../analysis/analyzer.dart';
import '../analysis/journal.dart';
import '../recording/recorder.dart';
import 'theme/app_theme.dart';
import 'viewer/format.dart';

/// Dziennik: czynniki sprzyjające napadom (raz dziennie), przyjęte leki, a z zapisów – co wpływa na napady,
/// jak szybko napad ustępował po leku i czy QRS/QTc nie zmieniają się przy lekach antyarytmicznych.
class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key});

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  Journal _j = Journal();
  List<MonitoredSpan> _spans = [];
  Directory? _appDir;
  bool _loading = true;
  int _dayOffset = 0; // 0 = dziś, 1 = wczoraj

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final root = await Recorder.recordingsRoot();
    final spans = <MonitoredSpan>[];
    for (final d in root.listSync().whereType<Directory>()) {
      final f = File('${d.path}/$summaryFile');
      if (!f.existsSync()) continue;
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        if (j['version'] == AnalysisResult.version) spans.add(MonitoredSpan.fromSummary(j));
      } catch (_) {}
    }
    spans.sort((a, b) => a.start.compareTo(b.start));
    final j = await Journal.load(root.parent);
    if (!mounted) return;
    setState(() {
      _appDir = root.parent;
      _j = j;
      _spans = spans;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await _j.save(_appDir!);
    if (mounted) setState(() {});
  }

  DateTime get _day {
    final n = DateTime.now().subtract(Duration(days: _dayOffset));
    return DateTime(n.year, n.month, n.day);
  }

  Future<void> _toggleTrigger(String t) async {
    final d = _day;
    if (_j.hasTrigger(d, t)) {
      _j.entries.removeWhere((e) =>
          e.kind == 'trigger' && e.name == t && e.time.year == d.year && e.time.month == d.month && e.time.day == d.day);
    } else {
      // Wczoraj bez godziny – przyjmujemy wieczór (czynniki zwykle wieczorne), dziś – teraz.
      final at = _dayOffset == 0 ? DateTime.now() : d.add(const Duration(hours: 20));
      _j.entries.add(JournalEntry(at, 'trigger', t));
    }
    await _save();
  }

  Future<void> _takeMed(MedDef m, {DateTime? at}) async {
    final e = JournalEntry(at ?? DateTime.now(), 'med', m.name, note: m.dose);
    _j.entries.add(e);
    await _save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Zapisano: ${m.name} ${m.dose} o ${fmtClock(e.time).substring(0, 5)}'),
      action: SnackBarAction(
        label: 'COFNIJ',
        onPressed: () async {
          _j.entries.remove(e);
          await _save();
        },
      ),
    ));
  }

  Future<void> _takeMedAt(MedDef m) async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.now(), helpText: 'Godzina przyjęcia');
    if (t == null) return;
    final now = DateTime.now();
    var at = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    if (at.isAfter(now)) at = at.subtract(const Duration(days: 1));
    await _takeMed(m, at: at);
  }

  Future<void> _editMed([MedDef? old]) async {
    final name = TextEditingController(text: old?.name), dose = TextEditingController(text: old?.dose);
    var cls = old?.cls ?? MedClass.ic;
    var onDemand = old?.onDemand ?? false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(old == null ? 'Dodaj lek' : 'Edytuj lek'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nazwa (np. Flekainid)')),
              TextField(controller: dose, decoration: const InputDecoration(labelText: 'Dawka (np. 100 mg)')),
              const SizedBox(height: 12),
              DropdownButtonFormField<MedClass>(
                initialValue: cls,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Grupa'),
                items: [for (final c in MedClass.values) DropdownMenuItem(value: c, child: Text(c.label))],
                onChanged: (v) => setSt(() => cls = v ?? cls),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Doraźnie przy napadzie'),
                subtitle: const Text('„Tabletka w kieszeni”'),
                value: onDemand,
                onChanged: (v) => setSt(() => onDemand = v),
              ),
            ]),
          ),
          actions: [
            if (old != null)
              TextButton(
                onPressed: () {
                  _j.meds.remove(old);
                  Navigator.pop(ctx, true);
                },
                child: const Text('Usuń'),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Zapisz')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final n = name.text.trim();
    if (n.isNotEmpty) {
      final def = MedDef(n, cls, dose: dose.text.trim(), onDemand: onDemand);
      final i = old == null ? -1 : _j.meds.indexOf(old);
      if (i >= 0) {
        _j.meds[i] = def;
      } else if (old == null) {
        _j.meds.add(def);
      }
    }
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final colors = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final effects = triggerEffects(_j, _spans);
    final doses = doseOutcomes(_j, [for (final s in _spans) ...s.episodes]);
    final cond = conductionCheck(_j, _spans);
    final recent = _j.entries.reversed.take(40).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Dziennik')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        SectionLabel('Czynniki',
            trailing: SegmentedButton<int>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [ButtonSegment(value: 0, label: Text('Dziś')), ButtonSegment(value: 1, label: Text('Wczoraj'))],
              selected: {_dayOffset},
              onSelectionChanged: (s) => setState(() => _dayOffset = s.first),
            )),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final tr in journalTriggers)
            FilterChip(label: Text(tr), selected: _j.hasTrigger(_day, tr), onSelected: (_) => _toggleTrigger(tr)),
        ]),
        const SizedBox(height: 4),
        Text('Zaznaczaj codziennie – po kilku tygodniach zobaczysz, po czym napady i pobudzenia S pojawiają się częściej.',
            style: t.bodySmall),
        SectionLabel('Leki',
            trailing: TextButton.icon(onPressed: _editMed, icon: const Icon(Icons.add), label: const Text('Dodaj'))),
        if (_j.meds.isEmpty)
          Text('Dodaj swoje leki – jednym stuknięciem zapiszesz przyjęcie, a aplikacja policzy czas do ustąpienia '
              'napadu i przypilnuje QRS/QTc przy lekach antyarytmicznych.', style: t.bodySmall)
        else
          for (final m in _j.meds)
            Card(
              child: ListTile(
                leading: Icon(m.onDemand ? Icons.medical_services_outlined : Icons.medication_outlined,
                    color: m.cls.widensQrs || m.cls.prolongsQt ? colors.warning : scheme.primary),
                title: Text('${m.name} ${m.dose}'.trim()),
                subtitle: Text(m.onDemand ? 'doraźnie · ${m.cls.label}' : m.cls.label),
                onTap: () => _takeMed(m),
                onLongPress: () => _editMed(m),
                trailing: IconButton(
                    icon: const Icon(Icons.schedule), tooltip: 'Przyjęty o innej godzinie', onPressed: () => _takeMedAt(m)),
              ),
            ),
        if (_j.meds.isNotEmpty)
          Text('Stuknij lek, aby zapisać przyjęcie teraz; przytrzymaj, aby edytować.', style: t.bodySmall),
        if (cond.qrsLast != null) ...[
          const SectionLabel('Przewodzenie (QRS, QTc)'),
          MetricGrid(children: [
            MetricTile('QRS – norma', cond.qrsBase?.round().toString() ?? '–', unit: 'ms', icon: Icons.straighten),
            MetricTile('QRS – ostatni', cond.qrsLast?.round().toString() ?? '–',
                unit: 'ms',
                sub: cond.qrsChangePct == null
                    ? null
                    : '${cond.qrsChangePct! >= 0 ? '+' : ''}${cond.qrsChangePct!.round()}% · ${fmtDate(cond.lastAt!)}',
                color: cond.warnings.isNotEmpty ? colors.danger : null,
                icon: Icons.straighten),
            MetricTile('QTc – ostatni', cond.qtcLast?.round().toString() ?? '–',
                unit: 'ms', color: (cond.qtcLast ?? 0) >= 480 ? colors.danger : null, icon: Icons.timer_outlined),
          ]),
          for (final w in cond.warnings)
            Card(
              color: colors.danger.withValues(alpha: 0.12),
              child: ListTile(leading: Icon(Icons.warning_amber_rounded, color: colors.danger), title: Text(w)),
            ),
        ],
        if (doses.isNotEmpty) ...[
          const SectionLabel('Leki przyjęte w czasie napadu'),
          Card(
            child: Column(children: [
              for (final d in doses.reversed.take(10))
                ListTile(
                  dense: true,
                  leading: Icon(Icons.medication, color: colors.af),
                  title: Text('${d.dose.name} ${d.dose.note} – ${fmtDate(d.dose.time)} ${fmtClock(d.dose.time).substring(0, 5)}'),
                  subtitle: Text(d.minutesToEnd == null
                      ? 'napad trwał jeszcze na końcu zapisu'
                      : 'napad ustąpił po ${d.minutesToEnd} min (tętno w AF ${d.episode.hrMean.round()}/min)'),
                ),
            ]),
          ),
        ],
        const SectionLabel('Co wpływa na Twoje napady'),
        if (effects.isEmpty)
          Text('Brak zaznaczonych czynników.', style: t.bodySmall)
        else
          Card(
            child: Column(children: [
              for (final e in effects)
                ListTile(
                  dense: true,
                  leading: Icon(e.suspicious ? Icons.warning_amber_rounded : Icons.circle_outlined,
                      color: e.suspicious ? colors.warning : scheme.outline, size: e.suspicious ? 22 : 14),
                  title: Text('${e.trigger} (dni: ${e.days})'),
                  subtitle: Text(!e.enough
                      ? 'za mało zapisów (potrzeba ≥ 2 dni i po 10 h zapisu z czynnikiem i bez) – '
                          '${e.hoursWith.toStringAsFixed(0)} h po czynniku'
                      : 'napady: ${e.afRateWith!.toStringAsFixed(1)}/dobę po czynniku vs '
                          '${e.afRateWithout!.toStringAsFixed(1)}/dobę bez'
                          '${e.sWith != null && e.sWithout != null ? '; S: ${e.sWith!.toStringAsFixed(1)} vs ${e.sWithout!.toStringAsFixed(1)}/h' : ''}'),
                ),
            ]),
          ),
        Text('Porównanie czasu zapisu do 24 h po czynniku z pozostałym czasem. To obserwacja, nie dowód przyczyny – '
            'warto pokazać lekarzowi.', style: t.bodySmall),
        if (recent.isNotEmpty) ...[
          const SectionLabel('Historia'),
          Card(
            child: Column(children: [
              for (final e in recent)
                Dismissible(
                  key: ObjectKey(e),
                  direction: DismissDirection.endToStart,
                  background: Container(
                      color: colors.danger,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 16),
                      child: const Icon(Icons.delete, color: Colors.white)),
                  onDismissed: (_) async {
                    _j.entries.remove(e);
                    await _save();
                  },
                  child: ListTile(
                    dense: true,
                    leading: Icon(e.kind == 'med' ? Icons.medication_outlined : Icons.label_outline,
                        color: e.kind == 'med' ? scheme.primary : scheme.outline),
                    title: Text('${e.name} ${e.note}'.trim()),
                    trailing: Text('${fmtDate(e.time)} ${fmtClock(e.time).substring(0, 5)}', style: t.labelSmall),
                  ),
                ),
            ]),
          ),
          Text('Przesuń wpis w lewo, aby go usunąć.', style: t.bodySmall),
        ],
      ]),
    );
  }
}

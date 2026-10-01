import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../alarms/alarm_service.dart';
import '../analysis/analyzer.dart';
import '../analysis/personal_profile.dart';
import '../settings/app_settings.dart';

class SettingsScreen extends StatelessWidget {
  final AppSettings settings;
  final AlarmService? alarms;

  const SettingsScreen({super.key, required this.settings, this.alarms});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ustawienia')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final s = settings;
          Future<void> set(void Function(AppSettings) f) => s.update(f);
          return ListView(
            children: [
              const _Header('Osoba'),
              ListTile(
                title: const Text('Imię i nazwisko'),
                subtitle: Text(s.name.isEmpty ? 'nie podano (raport PDF, EDF)' : s.name),
                trailing: const Icon(Icons.edit),
                onTap: () async {
                  final v = await _textDialog(context, 'Imię i nazwisko', s.name);
                  if (v != null) await set((x) => x.name = v);
                },
              ),
              ListTile(
                title: const Text('Rok urodzenia'),
                subtitle: Text(s.birthYear == null ? 'nie podano' : '${s.birthYear} (wiek ${s.age})'),
                trailing: const Icon(Icons.edit),
                onTap: () async {
                  final v = await _textDialog(context, 'Rok urodzenia', s.birthYear?.toString() ?? '', number: true);
                  if (v != null) await set((x) => x.birthYear = int.tryParse(v));
                },
              ),
              ListTile(
                title: const Text('Płeć'),
                subtitle: const Text('Wpływa na zakres QTc (M ≤ 450 ms, K ≤ 460 ms)'),
                trailing: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'M', label: Text('M')),
                    ButtonSegment(value: 'K', label: Text('K')),
                    ButtonSegment(value: '', label: Text('–')),
                  ],
                  selected: {s.sex},
                  onSelectionChanged: (v) => set((x) => x.sex = v.first),
                ),
              ),

              const _Header('Nagrywanie'),
              SwitchListTile(
                title: const Text('Akcelerometr opaski'),
                subtitle: const Text('Aktywność i pozycja ciała, lepsze wykrywanie artefaktów ruchowych. '
                    'Zmiana obowiązuje od następnego połączenia.'),
                value: s.accEnabled,
                onChanged: (v) => set((x) => x.accEnabled = v),
              ),

              const _Header('Analiza'),
              _SliderTile('Pauza od', s.pauseSeconds, 1.5, 5, 0.5, 's', (v) => set((x) => x.pauseSeconds = v), digits: 1),
              _SliderTile('Bradykardia poniżej', s.bradyBpm, 30, 60, 5, '/min', (v) => set((x) => x.bradyBpm = v)),
              _SliderTile('Tachykardia powyżej', s.tachyBpm, 100, 180, 10, '/min', (v) => set((x) => x.tachyBpm = v)),
              _SliderTile('Migotanie – min. czas epizodu', s.afMinSeconds, 30, 300, 30, 's',
                  (v) => set((x) => x.afMinSeconds = v)),
              SwitchListTile(
                title: const Text('Personalizacja'),
                subtitle: const Text('Uczy się Twoich wzorców i ręcznych poprawek (profil osobisty).'),
                value: s.usePersonal,
                onChanged: (v) => set((x) => x.usePersonal = v),
              ),
              ListTile(
                leading: const Icon(Icons.person_remove_outlined),
                title: const Text('Wyczyść profil osobisty'),
                subtitle: const Text('Usuwa zapamiętane wzorce i przykłady z poprawek.'),
                onTap: () => _clearProfile(context),
              ),
              const ListTile(
                dense: true,
                subtitle: Text('Zmiany progów analizy obowiązują dla nowych analiz – w zapisie użyj „Analizuj ponownie”.'),
              ),

              const _Header('Alarmy w czasie rzeczywistym'),
              SwitchListTile(
                title: const Text('Włącz alarmy'),
                subtitle: const Text('Powiadomienie, gdy podczas noszenia opaski wystąpi wybrane zdarzenie.'),
                value: s.alarmsEnabled,
                onChanged: (v) => set((x) => x.alarmsEnabled = v),
              ),
              if (s.alarmsEnabled) ...[
                _SliderTile('Tętno powyżej', s.alarmHrHigh, 100, 220, 5, '/min', (v) => set((x) => x.alarmHrHigh = v)),
                _SliderTile('Tętno poniżej', s.alarmHrLow, 30, 60, 5, '/min', (v) => set((x) => x.alarmHrLow = v)),
                CheckboxListTile(
                  title: const Text('Pauza w rytmie'),
                  value: s.alarmPause,
                  onChanged: (v) => set((x) => x.alarmPause = v ?? true),
                ),
                CheckboxListTile(
                  title: const Text('Podejrzenie migotania przedsionków'),
                  value: s.alarmAf,
                  onChanged: (v) => set((x) => x.alarmAf = v ?? true),
                ),
                CheckboxListTile(
                  title: const Text('Salwa pobudzeń komorowych'),
                  value: s.alarmVt,
                  onChanged: (v) => set((x) => x.alarmVt = v ?? true),
                ),
                SwitchListTile(title: const Text('Dźwięk'), value: s.alarmSound, onChanged: (v) => set((x) => x.alarmSound = v)),
                SwitchListTile(
                    title: const Text('Wibracja'), value: s.alarmVibrate, onChanged: (v) => set((x) => x.alarmVibrate = v)),
                _SliderTile('Ten sam alarm nie częściej niż co', s.alarmCooldownMin, 1, 30, 1, 'min',
                    (v) => set((x) => x.alarmCooldownMin = v)),
                if (alarms != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Testuj alarm'),
                      onPressed: () async {
                        await alarms!.init();
                        await alarms!.test();
                      },
                    ),
                  ),
              ],

              const _Header('Informacje'),
              ListTile(
                title: const Text('Klasyfikator pobudzeń'),
                subtitle: Text(beatModel == null
                    ? 'reguły (model niedostępny)'
                    : 'sieć neuronowa, uczona na ${beatModel!.meta['trainBeats']?.round()} pobudzeniach (MIT-BIH DS1); '
                        'test na DS2: V – czułość 85%, trafność 87%; migotanie – czułość 97%, swoistość 95%'),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Future<void> _clearProfile(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wyczyścić profil osobisty?'),
        content: const Text('Wzorce i przykłady z ręcznych poprawek zostaną usunięte. Same poprawki w zapisach zostają.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Wyczyść')),
        ],
      ),
    );
    if (ok != true) return;
    final f = PersonalProfile.fileIn(await getApplicationDocumentsDirectory());
    if (await f.exists()) await f.delete();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profil osobisty wyczyszczony')));
    }
  }

  static Future<String?> _textDialog(BuildContext context, String title, String initial, {bool number = false}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: number ? TextInputType.number : TextInputType.name,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Zapisz')),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

class _SliderTile extends StatelessWidget {
  final String label, unit;
  final double value, min, max, step;
  final int digits;
  final ValueChanged<double> onChanged;

  const _SliderTile(this.label, this.value, this.min, this.max, this.step, this.unit, this.onChanged, {this.digits = 0});

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text('$label: ${value.toStringAsFixed(digits).replaceAll('.', ',')} $unit'),
        subtitle: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) / step).round(),
          onChanged: onChanged,
        ),
      );
}

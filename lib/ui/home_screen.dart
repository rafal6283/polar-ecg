import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../analysis/analysis_result.dart';
import '../analysis/live_analyzer.dart';
import '../analysis/reference_ranges.dart';
import '../settings/app_settings.dart';
import '../app_controller.dart';
import '../ble/polar_h10.dart';
import 'ecg_chart.dart';
import 'hrv_screen.dart';
import 'rhythm_check_screen.dart';
import 'legend_screen.dart';
import 'settings_screen.dart';
import 'theme/app_theme.dart';
import 'trends_screen.dart';
import 'recordings_screen.dart';
import '../recording/markers.dart';
import 'viewer/format.dart';

/// Ekran główny: dolna nawigacja – Monitor (na żywo), Zapisy, Trendy, Ustawienia.
class HomeScreen extends StatefulWidget {
  final AppController controller;

  const HomeScreen({super.key, required this.controller});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  int _visit = 0; // nowy klucz przy każdym wejściu – listy zapisów/trendów odświeżają się

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      body: switch (_tab) {
        1 => RecordingsScreen(key: ValueKey('rec$_visit')),
        2 => TrendsScreen(key: ValueKey('tr$_visit')),
        3 => SettingsScreen(settings: c.settings, alarms: c.alarms),
        _ => MonitorPage(controller: c),
      },
      bottomNavigationBar: ListenableBuilder(
        listenable: c,
        builder: (context, _) => NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() {
            _tab = i;
            _visit++;
          }),
          destinations: [
            NavigationDestination(
              icon: Badge(isLabelVisible: c.isRecording, child: const Icon(Icons.monitor_heart_outlined)),
              selectedIcon: Badge(isLabelVisible: c.isRecording, child: const Icon(Icons.monitor_heart)),
              label: 'Monitor',
            ),
            const NavigationDestination(
                icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Zapisy'),
            const NavigationDestination(
                icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Trendy'),
            const NavigationDestination(
                icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune), label: 'Ustawienia'),
          ],
        ),
      ),
    );
  }
}

/// Monitor: wyszukiwanie opaski albo podgląd na żywo.
class MonitorPage extends StatelessWidget {
  final AppController controller;

  const MonitorPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final connected = controller.device != null && controller.link != LinkState.connecting;
        return Scaffold(
          appBar: AppBar(
            title: const _AppTitle(),
            actions: [
              IconButton(
                icon: const Icon(Icons.help_outline),
                tooltip: 'Legenda',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LegendScreen())),
              ),
              if (connected)
                IconButton(
                  icon: const Icon(Icons.bluetooth_disabled),
                  tooltip: 'Rozłącz',
                  onPressed: controller.disconnect,
                ),
            ],
          ),
          body: connected ? _LiveView(controller: controller) : _ScanView(controller: controller),
        );
      },
    );
  }
}

/// Logo (serce z falą EKG) + nazwa.
class _AppTitle extends StatelessWidget {
  const _AppTitle();

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.of(context).ecgAccent;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(9)),
        child: const Icon(Icons.monitor_heart, color: Colors.white, size: 19),
      ),
      const SizedBox(width: 10),
      const Text('Polar EKG'),
    ]);
  }
}

class _ScanView extends StatelessWidget {
  final AppController controller;

  const _ScanView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    if (controller.link == LinkState.connecting) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox.square(dimension: 48, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 20),
          Text('Łączenie z opaską…', style: t.titleMedium),
          const SizedBox(height: 4),
          Text('Uruchamiam EKG 130 Hz, tętno i akcelerometr', style: t.bodySmall),
        ]),
      );
    }
    return StreamBuilder<List<ScanResult>>(
      stream: PolarH10.scanResults,
      initialData: const [],
      builder: (context, snap) {
        final results = snap.data ?? const [];
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (controller.error != null)
              Card(
                color: scheme.errorContainer,
                child: ListTile(
                  leading: Icon(Icons.error_outline, color: scheme.onErrorContainer),
                  title: Text(controller.error!, style: TextStyle(color: scheme.onErrorContainer)),
                ),
              ),
            const SizedBox(height: 16),
            Center(
              child: Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(color: scheme.primaryContainer, shape: BoxShape.circle),
                child: Icon(Icons.monitor_heart_outlined, size: 56, color: scheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(height: 20),
            Text('Połącz opaskę Polar H10', textAlign: TextAlign.center, style: t.headlineSmall),
            const SizedBox(height: 6),
            Text('Zapis EKG, analiza rytmu na żywo i alarmy', textAlign: TextAlign.center, style: t.bodyMedium),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(children: const [
                  _Step(1, 'Zwilż elektrody', 'Woda lub żel – lepszy sygnał od pierwszej minuty.'),
                  _Step(2, 'Załóż opaskę', 'Pod mostkiem, logo na środku; H10 włącza się po kontakcie ze skórą.'),
                  _Step(3, 'Wyszukaj i połącz', 'Bluetooth musi być włączony.'),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            StreamBuilder<bool>(
              stream: PolarH10.isScanning,
              initialData: false,
              builder: (context, snap) {
                final scanning = snap.data ?? false;
                return FilledButton.icon(
                  icon: scanning
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.bluetooth_searching),
                  label: Text(scanning ? 'Szukam… (dotknij, aby przerwać)' : 'Szukaj opaski'),
                  onPressed: scanning ? PolarH10.stopScan : _scan(context),
                );
              },
            ),
            if (results.isNotEmpty) ...[
              const SectionLabel('Znalezione urządzenia'),
              for (final r in results)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: scheme.primaryContainer,
                        child: Icon(Icons.favorite, color: AppColors.of(context).ecgAccent),
                      ),
                      title: Text(r.device.advName.isNotEmpty ? r.device.advName : r.device.remoteId.str,
                          style: t.titleSmall),
                      subtitle: Text('Sygnał ${_signal(r.rssi)} · ${r.rssi} dBm'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => controller.connect(r.device),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  static String _signal(int rssi) => rssi > -65 ? 'bardzo dobry' : (rssi > -80 ? 'dobry' : 'słaby');

  VoidCallback _scan(BuildContext context) => () async {
        try {
          // iOS: stan adaptera bywa na początku „unknown” – czekamy chwilę na właściwy; włączyć Bluetooth
          // z aplikacji można tylko na Androidzie.
          final state = await FlutterBluePlus.adapterState
              .where((s) => s != BluetoothAdapterState.unknown)
              .first
              .timeout(const Duration(seconds: 3), onTimeout: () => BluetoothAdapterState.unknown);
          if (state != BluetoothAdapterState.on) {
            if (Platform.isAndroid) {
              await FlutterBluePlus.turnOn();
            } else {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(state == BluetoothAdapterState.unauthorized
                        ? 'Brak zgody na Bluetooth – Ustawienia → Polar EKG → Bluetooth'
                        : 'Włącz Bluetooth (Centrum sterowania lub Ustawienia)')));
              }
              return;
            }
          }
          await PolarH10.startScan();
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Błąd skanowania: $e')));
          }
        }
      };
}

class _Step extends StatelessWidget {
  final int n;
  final String title, body;
  const _Step(this.n, this.title, this.body);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: scheme.secondaryContainer,
        child: Text('$n', style: TextStyle(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700)),
      ),
      title: Text(title, style: Theme.of(context).textTheme.titleSmall),
      subtitle: Text(body),
    );
  }
}

class _LiveView extends StatelessWidget {
  final AppController controller;

  const _LiveView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final rec = c.recorder;
    final colors = AppColors.of(context);
    final h = MediaQuery.sizeOf(context).height;
    final showAlarm = c.alarms.lastAlarm != null && DateTime.now().difference(c.alarms.lastAlarmTime!).inMinutes < 5;
    return Column(
      children: [
        if (c.link == LinkState.reconnecting)
          _Banner(icon: Icons.sync, text: 'Utracono połączenie – ponawiam…', color: colors.warning),
        if (c.skinContact == false)
          _Banner(icon: Icons.touch_app_outlined, text: 'Brak kontaktu elektrod ze skórą – zwilż i popraw opaskę', color: colors.danger)
        else if (c.live?.contactWarning ?? false)
          _Banner(
              icon: Icons.water_drop_outlined,
              text: 'Sygnał zakłócony od ${DateTime.now().difference(c.live!.poorSince!).inMinutes} min – zwilż elektrody, '
                  'zapnij pasek ciaśniej. Rytmu nie da się teraz ocenić.',
              color: colors.warning),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            children: [
              _HeroCard(controller: c),
              const SizedBox(height: 10),
              Card(
                child: SizedBox(
                  height: (h * 0.26).clamp(170.0, 280.0),
                  child: Stack(children: [
                    Positioned.fill(child: EcgChart(buffer: c.ecg)),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                            color: colors.paper.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(8)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.circle, size: 8, color: colors.ecgAccent),
                          const SizedBox(width: 5),
                          Text('NA ŻYWO',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.trace, letterSpacing: 1)),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
              if (showAlarm) ...[
                const SizedBox(height: 10),
                Card(
                  color: colors.danger,
                  child: ListTile(
                    leading: const Icon(Icons.notifications_active, color: Colors.white),
                    title: Text(c.alarms.lastAlarm!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    subtitle: Text(fmtClock(c.alarms.lastAlarmTime!), style: const TextStyle(color: Colors.white70)),
                  ),
                ),
              ],
              _LivePanel(live: c.live, recording: rec != null),
            ],
          ),
        ),
        _RecordBar(controller: c, onSymptom: () => _markSymptom(context, c)),
      ],
    );
  }

  /// Znacznik objawu: wybór z listy + opcjonalna notatka; zapis z czasem opaski.
  Future<void> _markSymptom(BuildContext context, AppController c) async {
    final noteCtrl = TextEditingController();
    String? chosen;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Co odczuwasz?', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Znacznik trafi do zapisu i raportu PDF z opisem rytmu w tej chwili.',
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in symptoms)
                ChoiceChip(label: Text(s), selected: chosen == s, onSelected: (_) => setSt(() => chosen = s)),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(labelText: 'Notatka (opcjonalnie)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: chosen == null ? null : () => Navigator.pop(ctx, true),
                child: const Text('Zapisz znacznik'),
              ),
            ),
          ]),
        ),
      ),
    );
    if (ok == true && chosen != null) {
      await c.addMarker(chosen!, noteCtrl.text.trim());
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Zapisano: $chosen')));
      }
    }
  }
}

String _fmtElapsed(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _Banner({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Icon(icon, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

/// Główna karta: duże tętno, RR/RMSSD, stan rytmu i plakietki urządzenia.
class _HeroCard extends StatelessWidget {
  final AppController controller;
  const _HeroCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final l = c.live;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final colors = AppColors.of(context);
    final (rhythm, rColor, rIcon) = l == null || l.beats == 0
        ? ('Analiza rytmu za ok. 15 s…', scheme.onSurfaceVariant, Icons.hourglass_empty)
        : l.qualityPct < 60
            ? ('Słaby sygnał – popraw opaskę', colors.warning, Icons.signal_cellular_alt_1_bar)
            : l.afNow
                ? ('Rytm niemiarowy – podejrzenie AF', colors.danger, Icons.warning_amber_rounded)
                : ('Rytm miarowy', colors.ok, Icons.check_circle);
    final bat = c.battery;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            StatusPill(
                icon: Icons.bluetooth_connected,
                text: (c.device?.name ?? '').isEmpty ? 'Polar H10' : c.device!.name,
                color: scheme.primary),
            if (bat != null)
              StatusPill(
                icon: bat > 50 ? Icons.battery_full : (bat > 20 ? Icons.battery_4_bar : Icons.battery_alert),
                text: '$bat%',
                color: bat > 20 ? colors.ok : colors.danger,
              ),
            if (l != null && l.beats > 0)
              StatusPill(
                icon: Icons.graphic_eq,
                text: 'sygnał ${l.qualityPct.round()}%',
                color: l.qualityPct >= 80 ? colors.ok : (l.qualityPct >= 60 ? colors.warning : colors.danger),
              ),
          ]),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Icon(Icons.favorite, color: colors.ecgAccent, size: 34),
            const SizedBox(width: 8),
            Text(c.heartRate?.toString() ?? '––', style: t.displayMedium?.copyWith(fontWeight: FontWeight.w700, height: 1)),
            const SizedBox(width: 6),
            Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('/min', style: t.titleSmall)),
            const Spacer(),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              _MiniStat('RR', c.lastRr?.round().toString() ?? '–', 'ms'),
              const SizedBox(height: 4),
              _MiniStat('RMSSD', c.rmssd?.round().toString() ?? '–', 'ms'),
            ]),
          ]),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: rColor.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(rIcon, color: rColor, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(rhythm, style: t.titleSmall?.copyWith(color: rColor))),
            ]),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.monitor_heart_outlined),
                label: const Text('Sprawdź rytm'),
                style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => RhythmCheckScreen(controller: controller))),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.self_improvement),
                label: const Text('Pomiar HRV'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(64, 44)),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => HrvMeasureScreen(controller: controller))),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label, value, unit;
  const _MiniStat(this.label, this.value, this.unit);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
      Text(label, style: t.labelSmall),
      const SizedBox(width: 6),
      Text(value, style: t.titleMedium),
      const SizedBox(width: 2),
      Text(unit, style: t.labelSmall),
    ]);
  }
}

/// Pasek nagrywania przyklejony do dołu.
class _RecordBar extends StatelessWidget {
  final AppController controller;
  final VoidCallback onSymptom;
  const _RecordBar({required this.controller, required this.onSymptom});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final rec = c.recorder;
    final colors = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).cardTheme.color,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: rec == null
              ? SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.fiber_manual_record),
                    label: const Text('Rozpocznij nagrywanie'),
                    style: FilledButton.styleFrom(backgroundColor: colors.ecgAccent, foregroundColor: Colors.white),
                    onPressed: c.startRecording,
                  ),
                )
              : Row(children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: colors.ecgAccent, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('NAGRYWANIE', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.ecgAccent, letterSpacing: 1)),
                    Text(_fmtElapsed(rec.elapsed), style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const Spacer(),
                  OutlinedButton.icon(
                    icon: Icon(Icons.flag, color: colors.symptom),
                    label: const Text('Objaw'),
                    onPressed: onSymptom,
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                    style: FilledButton.styleFrom(backgroundColor: scheme.inverseSurface, foregroundColor: scheme.onInverseSurface),
                    onPressed: c.stopRecording,
                  ),
                ]),
        ),
      ),
    );
  }
}

/// Wyniki analizy na żywo: statystyki sesji, morfologia, ostatnie zdarzenia.
class _LivePanel extends StatelessWidget {
  final LiveAnalyzer? live;
  final bool recording;

  const _LivePanel({required this.live, required this.recording});

  @override
  Widget build(BuildContext context) {
    final l = live;
    final t = Theme.of(context).textTheme;
    final colors = AppColors.of(context);
    if (l == null || l.beats == 0) return const SizedBox.shrink();

    String ago(DateTime? d) {
      if (d == null) return '';
      final s = DateTime.now().difference(d).inSeconds;
      return s < 60 ? 'ostatnie ${s}s temu' : 'ostatnie ${s ~/ 60} min temu';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(recording ? 'Nagranie · ${_fmtElapsed(l.elapsed)}' : 'Sesja · ${_fmtElapsed(l.elapsed)}'),
      MetricGrid(children: [
        MetricTile('Tętno śr.', l.hrMean?.round().toString() ?? '–', unit: '/min', icon: Icons.favorite_border),
        MetricTile('Min / maks', '${l.hrMin?.round() ?? '–'}/${l.hrMax?.round() ?? '–'}', unit: '/min', icon: Icons.swap_vert),
        MetricTile('Pobudzenia V', '${l.ve}',
            sub: l.lastV == null ? 'komorowe' : ago(l.lastV), color: l.ve > 0 ? colors.beatV : null, icon: Icons.bolt),
        MetricTile('Pobudzenia S', '${l.sv}',
            sub: l.lastS == null ? 'nadkomorowe' : ago(l.lastS), color: l.sv > 0 ? colors.beatS : null, icon: Icons.bolt),
        MetricTile('SDNN', l.sdnn?.round().toString() ?? '–', unit: 'ms', icon: Icons.ssid_chart),
        MetricTile('RMSSD (1 min)', l.rmssd?.round().toString() ?? '–', unit: 'ms', icon: Icons.ssid_chart),
        MetricTile('Uderzenia', '${l.beats}', sub: '${l.unknown} nieczytelnych', icon: Icons.tag),
        if (l.activityMg != null)
          MetricTile('Aktywność', l.activityLabel ?? '–',
              sub: '${l.activityMg!.round()} mg · ${l.posture ?? '–'}', icon: Icons.directions_walk),
      ]),
      const SectionLabel('Przebieg (uśredniony)'),
      MetricGrid(children: [
        MetricTile('QRS', l.qrsMs?.round().toString() ?? '–', unit: 'ms', color: _rangeColor(context, 'qrs_ms', l.qrsMs)),
        MetricTile('QTc', l.qtcMs?.round().toString() ?? '–', unit: 'ms', color: _rangeColor(context, 'qtc_ms', l.qtcMs)),
        MetricTile('PQ', l.prMs?.round().toString() ?? '–', unit: 'ms', color: _rangeColor(context, 'pr_ms', l.prMs)),
        MetricTile('T dodatni', l.tPosPct?.round().toString() ?? '–', unit: '%',
            color: _rangeColor(context, 't_pos_pct', l.tPosPct)),
      ]),
      if (l.events.isNotEmpty) ...[
        const SectionLabel('Ostatnie zdarzenia'),
        Card(
          child: Column(children: [
            for (final (i, e) in l.events.reversed.take(5).indexed) ...[
              if (i > 0) const Divider(indent: 16, endIndent: 16),
              ListTile(
                dense: true,
                leading: Icon(Icons.circle, size: 12, color: _severityColor(context, e.severity)),
                title: Text(e.label, style: t.bodyMedium),
                trailing: Text(fmtClock(e.time), style: t.labelSmall),
              ),
            ],
          ]),
        ),
      ],
    ]);
  }
}

Color _severityColor(BuildContext context, Severity s) {
  final c = AppColors.of(context);
  return switch (s) {
    Severity.high => c.danger,
    Severity.medium => c.warning,
    Severity.low => Theme.of(context).colorScheme.outline,
  };
}

/// Kolor alarmowy, gdy wartość poza zakresem referencyjnym.
Color? _rangeColor(BuildContext context, String key, double? v) {
  final spec = paramsFor(AppSettings.instance.sex).where((p) => p.key == key).firstOrNull;
  return spec?.within(v) == false ? AppColors.of(context).danger : null;
}

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../analysis/analysis_result.dart';
import '../analysis/live_analyzer.dart';
import '../analysis/reference_ranges.dart';
import '../settings/app_settings.dart';
import '../app_controller.dart';
import '../ble/polar_h10.dart';
import 'ecg_chart.dart';
import 'legend_screen.dart';
import 'settings_screen.dart';
import 'trends_screen.dart';
import 'recordings_screen.dart';
import '../recording/markers.dart';
import 'viewer/format.dart';

class HomeScreen extends StatelessWidget {
  final AppController controller;

  const HomeScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final connected = controller.device != null && controller.link != LinkState.connecting;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Polar EKG'),
            actions: [
              IconButton(
                icon: const Icon(Icons.show_chart),
                tooltip: 'Trendy',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TrendsScreen())),
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Ustawienia',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => SettingsScreen(settings: controller.settings, alarms: controller.alarms)),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.help_outline),
                tooltip: 'Legenda',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LegendScreen())),
              ),
              IconButton(
                icon: const Icon(Icons.folder_open),
                tooltip: 'Zapisy',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RecordingsScreen()),
                ),
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

class _ScanView extends StatelessWidget {
  final AppController controller;

  const _ScanView({required this.controller});

  @override
  Widget build(BuildContext context) {
    if (controller.link == LinkState.connecting) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Łączenie z opaską…'),
        ]),
      );
    }
    return Column(
      children: [
        if (controller.error != null)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.all(12),
            child: Text(controller.error!),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: StreamBuilder<bool>(
            stream: PolarH10.isScanning,
            initialData: false,
            builder: (context, snap) {
              final scanning = snap.data ?? false;
              return FilledButton.icon(
                icon: scanning
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bluetooth_searching),
                label: Text(scanning ? 'Szukam…' : 'Szukaj opaski'),
                onPressed: scanning ? PolarH10.stopScan : _scan(context),
              );
            },
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Załóż i zwilż opaskę – H10 włącza się dopiero po kontakcie ze skórą.',
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: StreamBuilder<List<ScanResult>>(
            stream: PolarH10.scanResults,
            initialData: const [],
            builder: (context, snap) {
              final results = snap.data ?? const [];
              return ListView(
                children: [
                  for (final r in results)
                    ListTile(
                      leading: const Icon(Icons.monitor_heart),
                      title: Text(r.device.advName.isNotEmpty ? r.device.advName : r.device.remoteId.str),
                      subtitle: Text('Sygnał: ${r.rssi} dBm'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => controller.connect(r.device),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  VoidCallback _scan(BuildContext context) => () async {
        try {
          if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
            await FlutterBluePlus.turnOn();
          }
          await PolarH10.startScan();
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Błąd skanowania: $e')));
          }
        }
      };
}

class _LiveView extends StatelessWidget {
  final AppController controller;

  const _LiveView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final rec = c.recorder;
    return Column(
      children: [
        if (c.link == LinkState.reconnecting)
          Container(
            width: double.infinity,
            color: Colors.orange.shade700,
            padding: const EdgeInsets.all(8),
            child: const Text('Utracono połączenie – ponawiam…', style: TextStyle(color: Colors.white)),
          ),
        if (c.skinContact == false)
          Container(
            width: double.infinity,
            color: Colors.red.shade700,
            padding: const EdgeInsets.all(8),
            child: const Text('Brak kontaktu elektrod ze skórą', style: TextStyle(color: Colors.white)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _Stat(label: 'Tętno', value: c.heartRate?.toString() ?? '–', unit: 'bpm', big: true),
              _Stat(label: 'RR', value: c.lastRr?.round().toString() ?? '–', unit: 'ms'),
              _Stat(label: 'RMSSD', value: c.rmssd?.round().toString() ?? '–', unit: 'ms'),
              _Stat(label: 'Bateria', value: c.battery?.toString() ?? '–', unit: '%'),
            ],
          ),
        ),
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: EcgChart(buffer: c.ecg),
            ),
          ),
        ),
        if (c.alarms.lastAlarm != null && DateTime.now().difference(c.alarms.lastAlarmTime!).inMinutes < 5)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: const Color(0xFFD32F2F), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.notifications_active, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${fmtClock(c.alarms.lastAlarmTime!)}  ${c.alarms.lastAlarm}',
                    style: const TextStyle(color: Colors.white)),
              ),
            ]),
          ),
        Expanded(flex: 6, child: _LivePanel(live: c.live, recording: rec != null)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(
            children: [
              if (rec != null) ...[
                OutlinedButton.icon(
                  icon: const Icon(Icons.flag, color: Color(0xFF7B1FA2)),
                  label: const Text('Objaw'),
                  onPressed: () => _markSymptom(context, c),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: rec == null
                    ? FilledButton.icon(
                        icon: const Icon(Icons.fiber_manual_record),
                        label: const Text('Nagrywaj'),
                        style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
                        onPressed: c.startRecording,
                      )
                    : FilledButton.icon(
                        icon: const Icon(Icons.stop),
                        label: Text('Zatrzymaj  ${_fmt(rec.elapsed)}'),
                        onPressed: c.stopRecording,
                      ),
              ),
            ],
          ),
        ),
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
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in symptoms)
                ChoiceChip(label: Text(s), selected: chosen == s, onSelected: (_) => setSt(() => chosen = s)),
            ]),
            const SizedBox(height: 8),
            TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: 'Notatka (opcjonalnie)')),
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

  static String _fmt(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }
}

/// Wyniki analizy na żywo: rytm, statystyki sesji, ostatnie zdarzenia.
class _LivePanel extends StatelessWidget {
  final LiveAnalyzer? live;
  final bool recording;

  const _LivePanel({required this.live, required this.recording});

  @override
  Widget build(BuildContext context) {
    final l = live;
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    if (l == null || l.beats == 0) {
      return Center(
        child: Text('Analiza rytmu pojawi się po ok. 15 s…', style: t.bodySmall),
      );
    }

    final (rhythmText, rhythmColor, rhythmIcon) = l.qualityPct < 60
        ? ('Słaba jakość sygnału – popraw opaskę', Colors.grey.shade600, Icons.signal_cellular_connected_no_internet_0_bar)
        : l.afNow
            ? ('Rytm niemiarowy – podejrzenie migotania', const Color(0xFFD32F2F), Icons.warning_amber)
            : ('Rytm miarowy', const Color(0xFF2E7D32), Icons.favorite);

    String ago(DateTime? d) {
      if (d == null) return '';
      final s = DateTime.now().difference(d).inSeconds;
      return s < 60 ? ' · ${s}s temu' : ' · ${s ~/ 60} min temu';
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      children: [
        Row(children: [
          Icon(rhythmIcon, color: rhythmColor, size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text(rhythmText, style: t.titleSmall?.copyWith(color: rhythmColor))),
          Text('sygnał ${l.qualityPct.round()}%', style: t.labelSmall),
        ]),
        const SizedBox(height: 8),
        Text(recording ? 'Od początku nagrania (${_LiveView._fmt(l.elapsed)})' : 'Od połączenia (${_LiveView._fmt(l.elapsed)})',
            style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _Tile('Uderzenia', '${l.beats}'),
          _Tile('Tętno śr.', l.hrMean?.round().toString() ?? '–', unit: '/min'),
          _Tile('Min / maks', '${l.hrMin?.round() ?? '–'} / ${l.hrMax?.round() ?? '–'}', unit: '/min'),
          _Tile('SDNN', l.sdnn?.round().toString() ?? '–', unit: 'ms'),
          _Tile('Pobudzenia V', '${l.ve}', sub: l.lastV == null ? null : 'ostatnie${ago(l.lastV)}', color: l.ve > 0 ? const Color(0xFFD32F2F) : null),
          _Tile('Pobudzenia S', '${l.sv}', sub: l.lastS == null ? null : 'ostatnie${ago(l.lastS)}', color: l.sv > 0 ? const Color(0xFF1976D2) : null),
          _Tile('Nieczytelne', '${l.unknown}'),
          if (l.activityMg != null) _Tile('Aktywność', l.activityLabel ?? '–', sub: '${l.activityMg!.round()} mg'),
          if (l.activityMg != null) _Tile('Pozycja', l.posture ?? '–'),
          _Tile('RMSSD (1 min)', l.rmssd?.round().toString() ?? '–', unit: 'ms'),
          _Tile('QRS', l.qrsMs?.round().toString() ?? '–', unit: 'ms', color: _rangeColor('qrs_ms', l.qrsMs)),
          _Tile('QTc', l.qtcMs?.round().toString() ?? '–', unit: 'ms', color: _rangeColor('qtc_ms', l.qtcMs)),
          _Tile('PQ', l.prMs?.round().toString() ?? '–', unit: 'ms', color: _rangeColor('pr_ms', l.prMs)),
          _Tile('T dodatni', l.tPosPct?.round().toString() ?? '–', unit: '%', color: _rangeColor('t_pos_pct', l.tPosPct)),
        ]),
        if (l.events.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Ostatnie zdarzenia', style: t.labelMedium),
          for (final e in l.events.reversed.take(5))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Icon(Icons.circle,
                    size: 10,
                    color: switch (e.severity) {
                      Severity.high => const Color(0xFFD32F2F),
                      Severity.medium => const Color(0xFFF57C00),
                      Severity.low => scheme.outline,
                    }),
                const SizedBox(width: 6),
                Text(fmtClock(e.time), style: t.labelSmall),
                const SizedBox(width: 8),
                Expanded(child: Text(e.label, style: t.bodySmall)),
              ]),
            ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Czerwony, gdy wartość poza zakresem referencyjnym.
Color? _rangeColor(String key, double? v) {
  final spec = paramsFor(AppSettings.instance.sex).where((p) => p.key == key).firstOrNull;
  return spec?.within(v) == false ? const Color(0xFFD32F2F) : null;
}

class _Tile extends StatelessWidget {
  final String label, value;
  final String? unit, sub;
  final Color? color;

  const _Tile(this.label, this.value, {this.unit, this.sub, this.color});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final width = (MediaQuery.sizeOf(context).width - 24 - 8) / 2;
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.labelSmall),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(value, style: t.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w600)),
          if (unit != null) ...[const SizedBox(width: 3), Text(unit!, style: t.labelSmall)],
        ]),
        if (sub != null) Text(sub!, style: t.labelSmall?.copyWith(fontSize: 10)),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value, unit;
  final bool big;

  const _Stat({required this.label, required this.value, required this.unit, this.big = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: t.labelSmall),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value, style: big ? t.headlineMedium : t.titleLarge),
            const SizedBox(width: 3),
            Text(unit, style: t.labelSmall),
          ],
        ),
      ],
    );
  }
}

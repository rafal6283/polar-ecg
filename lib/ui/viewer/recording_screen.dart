import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../analysis/analysis_result.dart';
import '../../analysis/analyzer.dart';
import '../../analysis/ecg_recording.dart';
import '../../export/exporters.dart';
import '../../recording/markers.dart';
import '../../report/pdf_report.dart';
import 'dart:io';
import 'package:share_plus/share_plus.dart';
import '../../settings/app_settings.dart';
import 'beat_sheet.dart';
import 'ecg_strip_view.dart';
import 'format.dart';
import 'tachogram.dart';
import 'viewport.dart';
import 'waveform_card.dart';
import '../legend_screen.dart';

/// Przegląd i analiza jednego zapisu.
class RecordingScreen extends StatefulWidget {
  final String path;
  final String title;

  const RecordingScreen({super.key, required this.path, required this.title});

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  AnalysisResult? _analysis;
  Float32List? _signal;
  EcgViewport? _viewport;
  String? _error;
  bool _busy = false;
  Map<int, int> _corrections = {};
  bool _dirty = false; // poprawki nieuwzględnione jeszcze w analizie
  List<SymptomMarker> _markers = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var a = force ? null : await loadAnalysis(widget.path);
      a ??= await analyzeInBackground(widget.path, AppSettings.instance.analysis);
      final sig = await loadFiltered(widget.path);
      final corr = await loadCorrections(widget.path);
      final markers = await loadMarkers(widget.path, a.timeline);
      final keepView = _viewport != null && _viewport!.totalSamples == sig.length;
      final oldStart = _viewport?.start, oldSpan = _viewport?.span;
      _viewport?.dispose();
      setState(() {
        _analysis = a;
        _signal = sig;
        _corrections = corr;
        _markers = markers;
        _dirty = !_sameMap(corr, a!.corrected);
        _viewport = EcgViewport(totalSamples: sig.length, sampleRate: a.sampleRate);
        if (keepView) _viewport!.set(oldStart!, oldSpan);
      });
    } catch (e, st) {
      debugPrint('Błąd analizy ${widget.path}: $e\n$st');
      if (mounted) setState(() => _error = 'Błąd analizy: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static bool _sameMap(Map<int, int> a, Map<int, int> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  Future<void> _setCorrection(int sample, int? label) async {
    setState(() {
      _corrections = {..._corrections};
      if (label == null) {
        _corrections.remove(sample);
      } else {
        _corrections[sample] = label;
      }
      _dirty = !_sameMap(_corrections, _analysis!.corrected);
    });
    await saveCorrections(widget.path, _corrections);
  }

  Future<void> _onBeatTap(int k) async {
    final a = _analysis!;
    final sample = a.rPeaks[k];
    final choice = await showBeatSheet(context, a, k, currentCorrection: _corrections[sample]);
    if (choice == null) return;
    // Poprawka zgodna z wynikiem analizy niczego nie zmienia – usuwamy ją.
    final same = choice == a.labels[k] && !a.corrected.containsKey(sample);
    await _setCorrection(sample, choice < 0 || same ? null : choice);
  }

  Future<void> _onLongPress(int sample) async {
    final sig = _signal!;
    // Dodanie przeoczonego uderzenia: szczyt sygnału w ±80 ms od miejsca przytrzymania.
    final w = (0.08 * _analysis!.sampleRate).round();
    var best = sample;
    for (var i = sample - w; i <= sample + w; i++) {
      if (i >= 0 && i < sig.length && sig[i].abs() > sig[best.clamp(0, sig.length - 1)].abs()) best = i;
    }
    final ok = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Dodać uderzenie w tym miejscu?'),
        children: [
          for (final (t, v) in [('Prawidłowe (N)', 0), ('Nadkomorowe (S)', 1), ('Komorowe (V)', 2)])
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, v), child: Text(t)),
        ],
      ),
    );
    if (ok != null) await _setCorrection(best, ok);
  }

  Future<void> _export(String kind) async {
    final a = _analysis!;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Przygotowuję plik…'), duration: Duration(seconds: 2)));
    try {
      final dir = Directory('${widget.path}/export');
      await dir.create(recursive: true);
      final stamp = a.timeline.started.toIso8601String().substring(0, 16).replaceAll(RegExp('[-:T]'), '');
      final s = AppSettings.instance;
      late File f;
      switch (kind) {
        case 'pdf':
          final bytes = await buildPdfReport(
            a: a,
            signal: _signal!,
            markers: _markers,
            person: ReportPerson(name: s.name, age: s.age, sex: s.sex),
          );
          f = File('${dir.path}/raport_ekg_$stamp.pdf');
          await f.writeAsBytes(bytes);
        case 'edf':
          final rec = await EcgRecording.load(Directory(widget.path));
          f = await exportEdf(
              out: File('${dir.path}/ekg_$stamp.edf'), rec: rec, a: a, markers: _markers, patientName: s.name, sex: s.sex);
        case 'csv':
          final rec = await EcgRecording.load(Directory(widget.path));
          f = await exportEcgCsv(out: File('${dir.path}/ekg_$stamp.csv'), rec: rec, a: a);
        default:
          f = await exportRrCsv(out: File('${dir.path}/rr_$stamp.csv'), a: a);
      }
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: 'EKG ${widget.title}'));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Błąd eksportu: $e')));
    }
  }

  void _goTo(int sample, {int? endSample}) {
    final vp = _viewport!;
    final len = endSample == null ? 0 : endSample - sample;
    final span = (len + 4 * vp.sampleRate).clamp(10.0 * vp.sampleRate, vp.maxSpan).toDouble();
    if (len + 4 * vp.sampleRate <= span) {
      vp.centerOn(sample + len / 2, span: span);
    } else {
      vp.set(sample - 2.0 * vp.sampleRate, span);
    }
    _tabs.animateTo(0);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _viewport?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = _analysis;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Legenda',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LegendScreen())),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Udostępnij / eksportuj',
            enabled: a != null && !_busy,
            onSelected: _export,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pdf', child: Text('Raport PDF dla lekarza')),
              PopupMenuItem(value: 'edf', child: Text('EDF+ (EDFbrowser, programy holterowskie)')),
              PopupMenuItem(value: 'csv', child: Text('CSV – sygnał EKG')),
              PopupMenuItem(value: 'rr', child: Text('CSV – odstępy RR (np. Kubios HRV)')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Analizuj ponownie',
            onPressed: _busy ? null : () => _load(force: true),
          ),
        ],
        bottom: TabBar(controller: _tabs, tabs: [
          const Tab(text: 'Przebieg'),
          Tab(text: a == null ? 'Zdarzenia' : 'Zdarzenia (${a.events.length})'),
          const Tab(text: 'Raport'),
        ]),
      ),
      body: _busy
          ? const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Analiza zapisu…'),
              ]),
            )
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
              : a == null
                  ? const SizedBox()
                  : TabBarView(
                      controller: _tabs,
                      physics: const NeverScrollableScrollPhysics(), // przesuw palcem należy do wykresu
                      children: [
                        Column(children: [
                          if (_dirty)
                            MaterialBanner(
                              content: Text('Poprawki ręczne: ${_corrections.length}. Przelicz, aby uwzględnić je w zdarzeniach, '
                                  'statystykach i profilu osobistym.'),
                              actions: [TextButton(onPressed: () => _load(force: true), child: const Text('PRZELICZ'))],
                            ),
                          Expanded(
                            child: _WaveTab(
                              analysis: a,
                              signal: _signal!,
                              viewport: _viewport!,
                              corrections: _corrections,
                              markers: {for (final m in _markers) if (m.sample >= 0) m.sample: m.symptom},
                              onBeatTap: _onBeatTap,
                              onLongPress: _onLongPress,
                            ),
                          ),
                        ]),
                        _EventsTab(
                          analysis: a,
                          markers: _markers,
                          onSelect: (e) => _goTo(e.startSample, endSample: e.endSample),
                          onMarker: (m) => _goTo(m.sample),
                        ),
                        _ReportTab(analysis: a),
                      ],
                    ),
    );
  }
}

// ---------------- Przebieg ----------------

class _WaveTab extends StatelessWidget {
  final AnalysisResult analysis;
  final Float32List signal;
  final EcgViewport viewport;
  final Map<int, int> corrections;
  final Map<int, String> markers;
  final void Function(int) onBeatTap;
  final void Function(int) onLongPress;

  const _WaveTab({
    required this.analysis,
    required this.signal,
    required this.viewport,
    required this.corrections,
    required this.markers,
    required this.onBeatTap,
    required this.onLongPress,
  });

  int? _findBeat(int from, int dir) {
    for (var k = from; k >= 0 && k < analysis.rPeaks.length; k += dir) {
      final l = analysis.labels[k];
      if (l == BeatType.ventricular || l == BeatType.supraventricular) return k;
    }
    return null;
  }

  int? _findEvent(double center, int dir) {
    final ev = analysis.events;
    if (dir > 0) {
      for (final e in ev) {
        if (e.startSample > center + 1) return e.startSample;
      }
    } else {
      for (final e in ev.reversed) {
        if (e.startSample < center - 1) return e.startSample;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final vp = viewport;
    final fs = analysis.sampleRate;
    return Column(
      children: [
        SizedBox(height: 90, child: Tachogram(analysis: analysis, viewport: vp)),
        const SizedBox(height: 4),
        Expanded(
          child: EcgStripView(
            signal: signal,
            analysis: analysis,
            viewport: vp,
            corrections: corrections,
            markers: markers,
            onBeatTap: onBeatTap,
            onLongPressEmpty: onLongPress,
          ),
        ),
        ListenableBuilder(
          listenable: vp,
          builder: (context, _) {
            final c = vp.center;
            final beatHere = analysis.beatIndexAtOrAfter(c);
            final prevBeat = _findBeat(beatHere - 1, -1);
            final nextBeat = _findBeat(analysis.beatIndexAtOrAfter(c + 1), 1);
            final prevEv = _findEvent(c, -1);
            final nextEv = _findEvent(c, 1);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    tooltip: 'Poprzednie zdarzenie',
                    onPressed: prevEv == null ? null : () => vp.centerOn(prevEv),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    tooltip: 'Poprzednie pobudzenie S/V',
                    onPressed: prevBeat == null ? null : () => vp.centerOn(analysis.rPeaks[prevBeat]),
                  ),
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(fmtClock(analysis.timeline.timeOf(c)), style: Theme.of(context).textTheme.titleMedium),
                    Text('${(vp.span / fs).toStringAsFixed(0)} s na ekranie',
                        style: Theme.of(context).textTheme.labelSmall),
                  ]),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    tooltip: 'Następne pobudzenie S/V',
                    onPressed: nextBeat == null ? null : () => vp.centerOn(analysis.rPeaks[nextBeat]),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    tooltip: 'Następne zdarzenie',
                    onPressed: nextEv == null ? null : () => vp.centerOn(nextEv),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

// ---------------- Zdarzenia ----------------

class _EventsTab extends StatelessWidget {
  final AnalysisResult analysis;
  final List<SymptomMarker> markers;
  final void Function(EcgEvent) onSelect;
  final void Function(SymptomMarker) onMarker;

  const _EventsTab({required this.analysis, required this.markers, required this.onSelect, required this.onMarker});

  @override
  Widget build(BuildContext context) {
    final ev = analysis.events;
    if (ev.isEmpty && markers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Nie wykryto zaburzeń rytmu.\nPojedyncze pobudzenia S/V znajdziesz strzałkami w zakładce Przebieg.',
              textAlign: TextAlign.center),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      children: [
        if (markers.isNotEmpty) ...[
          const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Zgłoszone objawy')),
          for (final m in markers)
            ListTile(
              leading: const Icon(Icons.flag, color: Color(0xFF7B1FA2)),
              title: Text(m.label),
              subtitle: Text('${fmtClock(m.time)} · ${_rhythmAt(m.sample)}'),
              trailing: const Icon(Icons.chevron_right),
              enabled: m.sample >= 0,
              onTap: () => onMarker(m),
            ),
          const Divider(),
        ],
        if (ev.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text('Wykryte zdarzenia')),
        for (final e in ev)
          ListTile(
            leading: Icon(Icons.circle,
                color: switch (e.severity) {
                  Severity.high => const Color(0xFFD32F2F),
                  Severity.medium => const Color(0xFFF57C00),
                  Severity.low => scheme.outline,
                },
                size: 14),
            title: Text(e.type.label),
            subtitle: Text([fmtClock(analysis.timeline.timeOf(e.startSample)), if (e.detail.isNotEmpty) e.detail].join(' · ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onSelect(e),
          ),
      ],
    );
  }

  /// Krótki opis rytmu w chwili objawu (±10 s) – czy objaw miał odpowiednik w EKG.
  String _rhythmAt(int sample) {
    if (sample < 0) return 'poza zapisem EKG';
    final fs = analysis.sampleRate;
    final a = analysis.beatIndexAtOrAfter(sample - 10 * fs), b = analysis.beatIndexAtOrAfter(sample + 10 * fs);
    if (b - a < 2) return 'brak czytelnych uderzeń';
    var v = 0, s = 0, af = false;
    for (var k = a; k < b; k++) {
      if (analysis.labels[k] == BeatType.ventricular) v++;
      if (analysis.labels[k] == BeatType.supraventricular) s++;
      if (analysis.inAf[k] == 1) af = true;
    }
    final hr = (60 * fs * (b - a - 1) / (analysis.rPeaks[b - 1] - analysis.rPeaks[a])).round();
    final parts = ['$hr/min', if (af) 'migotanie', if (v > 0) 'V: $v', if (s > 0) 'S: $s'];
    return parts.join(', ');
  }
}
// ---------------- Raport ----------------

class _ReportTab extends StatelessWidget {
  final AnalysisResult analysis;

  const _ReportTab({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final s = analysis.stats;
    final tl = analysis.timeline;
    final t = Theme.of(context).textTheme;
    String at(String key) {
      final v = s[key];
      return v == null ? '' : ' (${fmtClock(tl.timeOf(v))})';
    }

    final byType = <EventType, int>{};
    for (final e in analysis.events) {
      byType.update(e.type, (v) => v + 1, ifAbsent: () => 1);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('${fmtDate(tl.started)}, ${fmtClock(tl.started)}', style: t.titleMedium),
        Text('Czas zapisu ${fmtDuration(Duration(seconds: (s['duration_s'] ?? 0).round()))}, '
            'analizowane ${fmtDuration(Duration(seconds: (s['analyzed_s'] ?? 0).round()))}'),
        const SizedBox(height: 16),
        Text('Parametry przebiegu', style: t.titleSmall),
        const SizedBox(height: 6),
        WaveformCard(analysis: analysis),
        _Section('Tętno', [
          ('Średnie', fmtNum(s['hr_mean'], unit: '/min')),
          ('Minimalne (śr. minutowa)', '${fmtNum(s['hr_min'], unit: '/min')}${at('hr_min_at')}'),
          ('Maksymalne (śr. minutowa)', '${fmtNum(s['hr_max'], unit: '/min')}${at('hr_max_at')}'),
          ('Najdłuższa pauza', fmtNum(s['longest_pause_s'], digits: 1, unit: 's')),
        ]),
        _Section('Pobudzenia', [
          ('Wszystkie', fmtNum(s['beats'])),
          ('Komorowe (V)', '${fmtNum(s['v'])}  ·  ${fmtNum(s['v_per_h'], digits: 1)}/h'),
          ('Nadkomorowe (S)', '${fmtNum(s['s'])}  ·  ${fmtNum(s['s_per_h'], digits: 1)}/h'),
          ('Nieczytelne (Q)', fmtNum(s['q'])),
        ]),
        _Section('Rytm', [
          ('Obciążenie AF', fmtNum(s['af_burden_pct'], digits: 1, unit: '%')),
          for (final e in byType.entries) (e.key.label, '${e.value}×'),
        ]),
        _Section('Zmienność rytmu (HRV)', [
          ('Średni NN', fmtNum(s['mean_nn_ms'], unit: 'ms')),
          ('SDNN', fmtNum(s['sdnn_ms'], digits: 1, unit: 'ms')),
          ('RMSSD', fmtNum(s['rmssd_ms'], digits: 1, unit: 'ms')),
          ('pNN50', fmtNum(s['pnn50_pct'], digits: 1, unit: '%')),
          ('SD1 / SD2', '${fmtNum(s['sd1_ms'], digits: 1)} / ${fmtNum(s['sd2_ms'], digits: 1)} ms'),
        ]),
        const SizedBox(height: 8),
        Text('Wykres Poincaré', style: t.titleSmall),
        const SizedBox(height: 8),
        PoincarePlot(analysis: analysis),
        const SizedBox(height: 16),
        Text(
          'Analiza automatyczna z jednego odprowadzenia, do użytku własnego. '
          'Nie jest diagnozą – niepokojące zdarzenia skonsultuj z lekarzem i pokaż mu zapis.',
          style: t.bodySmall,
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;

  const _Section(this.title, this.rows);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: t.titleSmall),
            const SizedBox(height: 6),
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(child: Text(k)),
                  Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

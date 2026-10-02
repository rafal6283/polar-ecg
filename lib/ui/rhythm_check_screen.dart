import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../analysis/analysis_result.dart';
import '../analysis/analyzer.dart';
import '../analysis/rhythm_check.dart';
import '../app_controller.dart';
import '../recording/markers.dart';
import '../report/pdf_report.dart';
import '../settings/app_settings.dart';
import 'ecg_chart.dart';
import 'report_fonts.dart';
import 'theme/app_theme.dart';
import 'viewer/format.dart';
import 'viewer/recording_screen.dart';

enum _Phase { intro, measure, analyzing, done, failed }

/// Szybkie sprawdzenie rytmu (np. przy kołataniu serca): 1–2 min zapisu, od razu ocena i raport PDF dla lekarza.
/// Zapis trafia też na listę Zapisy (z objawem jako znacznikiem).
class RhythmCheckScreen extends StatefulWidget {
  final AppController controller;
  const RhythmCheckScreen({super.key, required this.controller});

  @override
  State<RhythmCheckScreen> createState() => _RhythmCheckScreenState();
}

class _RhythmCheckScreenState extends State<RhythmCheckScreen> {
  int _seconds = 60;
  String? _symptom;
  _Phase _phase = _Phase.intro;
  int _elapsed = 0;
  Timer? _timer;
  String? _dir;
  AnalysisResult? _result;
  RhythmVerdict? _verdict;
  String? _error;

  AppController get c => widget.controller;
  bool get _connected => c.device != null && c.link == LinkState.connected;

  @override
  void dispose() {
    _timer?.cancel();
    // Wyjście w trakcie – kończymy zapis, żeby nie nagrywał dalej w tle.
    if (_phase == _Phase.measure && c.isRecording) c.stopRecording();
    super.dispose();
  }

  Future<void> _start() async {
    await c.startRecording();
    final rec = c.recorder;
    if (rec == null) {
      setState(() {
        _phase = _Phase.failed;
        _error = 'Nie udało się rozpocząć zapisu.';
      });
      return;
    }
    _dir = rec.dir.path;
    await c.addMarker(_symptom ?? 'Sprawdzenie rytmu', 'sprawdzenie rytmu');
    setState(() {
      _phase = _Phase.measure;
      _elapsed = 0;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed++);
      if (_elapsed >= _seconds) _finish();
    });
  }

  Future<void> _finish() async {
    _timer?.cancel();
    setState(() => _phase = _Phase.analyzing);
    await c.stopRecording();
    try {
      final a = await analyzeInBackground(_dir!, AppSettings.instance.analysis);
      if (!mounted) return;
      setState(() {
        _result = a;
        _verdict = rhythmVerdict(a);
        _phase = _Phase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = 'Błąd analizy: $e';
      });
    }
  }

  Future<void> _cancel() async {
    _timer?.cancel();
    await c.stopRecording();
    if (mounted) setState(() => _phase = _Phase.intro);
  }

  Future<void> _sharePdf() async {
    final a = _result!, path = _dir!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final s = AppSettings.instance;
      final bytes = await buildPdfReport(
        a: a,
        signal: await loadFiltered(path),
        markers: await loadMarkers(path, a.timeline),
        person: ReportPerson(name: s.name, age: s.age, sex: s.sex),
        fontData: await loadReportFonts(),
      );
      final t = a.timeline.started;
      final stamp = t.toIso8601String().substring(0, 16).replaceAll(RegExp('[-:T]'), '');
      final f = File('${(await getTemporaryDirectory()).path}/sprawdzenie_rytmu_$stamp.pdf');
      await f.writeAsBytes(bytes);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(f.path)],
        subject: 'Sprawdzenie rytmu ${fmtDate(t)} ${fmtClock(t).substring(0, 5)}',
        text: '${_verdict!.title}: ${_verdict!.detail}',
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Nie udało się przygotować PDF: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _phase != _Phase.analyzing,
      child: Scaffold(
        appBar: AppBar(title: const Text('Sprawdź rytm')),
        body: ListenableBuilder(
          listenable: c,
          builder: (context, _) => switch (_phase) {
            _Phase.intro => _intro(context),
            _Phase.measure => _running(context),
            _Phase.analyzing => const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Analizuję zapis…'),
                ]),
              ),
            _Phase.done => _done(context),
            _Phase.failed => _failed(context),
          },
        ),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final busy = c.isRecording;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.monitor_heart_outlined, color: AppColors.of(context).ecgAccent),
              const SizedBox(width: 8),
              Text('Szybkie sprawdzenie rytmu', style: t.titleMedium),
            ]),
            const SizedBox(height: 8),
            const Text('Usiądź spokojnie, nie mów i nie ruszaj się. Po zakończeniu zobaczysz ocenę rytmu, '
                'a zapis z objawem trafi do listy zapisów – możesz go od razu wysłać lekarzowi jako PDF.'),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 60, label: Text('1 min')),
                ButtonSegment(value: 120, label: Text('2 min')),
              ],
              selected: {_seconds},
              onSelectionChanged: (s) => setState(() => _seconds = s.first),
            ),
            const SizedBox(height: 4),
            Text('Do oceny migotania potrzeba co najmniej 30 s czytelnego zapisu – 2 min daje pewniejszy wynik.',
                style: t.bodySmall),
          ]),
        ),
      ),
      const SectionLabel('Co odczuwasz? (opcjonalnie)'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in symptoms)
          ChoiceChip(
              label: Text(s), selected: _symptom == s, onSelected: (v) => setState(() => _symptom = v ? s : null)),
      ]),
      const SizedBox(height: 20),
      if (busy)
        const Text('Trwa nagrywanie – rytm jest oceniany na bieżąco. Użyj przycisku „Objaw” na ekranie Monitor.')
      else if (!_connected)
        const Text('Połącz opaskę Polar H10 na ekranie Monitor.')
      else if (c.skinContact == false)
        const Text('Brak kontaktu elektrod ze skórą – zwilż elektrody i popraw opaskę.'),
      const SizedBox(height: 8),
      FilledButton.icon(
        icon: const Icon(Icons.play_arrow),
        label: const Text('Rozpocznij'),
        style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
        onPressed: _connected && !busy ? _start : null,
      ),
    ]);
  }

  Widget _running(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final colors = AppColors.of(context);
    final l = c.live;
    final left = _seconds - _elapsed;
    final q = l?.qualityPct;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Center(
        child: SizedBox.square(
          dimension: 150,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                  value: _elapsed / _seconds, strokeWidth: 8, color: colors.ecgAccent),
            ),
            Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}', style: t.displaySmall),
              Text('${c.heartRate ?? '–'} /min', style: t.titleSmall),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      Card(child: SizedBox(height: 180, child: EcgChart(buffer: c.ecg))),
      const SizedBox(height: 8),
      if (c.skinContact == false || (q != null && l!.beats > 5 && q < 60))
        Text('Zakłócony sygnał – nie ruszaj się, sprawdź kontakt elektrod.',
            style: t.bodyMedium?.copyWith(color: colors.warning))
      else
        Text('Oddychaj spokojnie, nie ruszaj się.', style: t.bodyMedium),
      const SizedBox(height: 16),
      OutlinedButton(onPressed: _cancel, child: const Text('Przerwij')),
    ]);
  }

  Widget _done(BuildContext context) {
    final v = _verdict!;
    final t = Theme.of(context).textTheme;
    final colors = AppColors.of(context);
    final (color, icon) = switch (v.verdict) {
      CheckVerdict.regular => (colors.ok, Icons.check_circle),
      CheckVerdict.unreadable => (colors.warning, Icons.signal_cellular_alt_1_bar),
      CheckVerdict.af => (colors.danger, Icons.warning_amber_rounded),
      _ => (colors.warning, Icons.info_outline),
    };
    final a = _result!;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        color: color.withValues(alpha: 0.12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(width: 10),
              Expanded(child: Text(v.title, style: t.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 8),
            Text(v.detail, style: t.bodyMedium),
          ]),
        ),
      ),
      MetricGrid(children: [
        MetricTile('Tętno', v.hr?.round().toString() ?? '–', unit: '/min', icon: Icons.favorite_border),
        MetricTile('Pobudzenia V', '${v.v}', color: v.v > 0 ? colors.beatV : null, icon: Icons.bolt),
        MetricTile('Pobudzenia S', '${v.s}', color: v.s > 0 ? colors.beatS : null, icon: Icons.bolt),
        MetricTile('Czytelność', '${v.readablePct.round()}', unit: '%', icon: Icons.graphic_eq),
      ]),
      const SizedBox(height: 12),
      FilledButton.icon(
        icon: const Icon(Icons.picture_as_pdf_outlined),
        label: const Text('Wyślij PDF (np. lekarzowi)'),
        style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
        onPressed: _sharePdf,
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.show_chart),
        label: const Text('Pokaż zapis EKG'),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => RecordingScreen(
              path: _dir!,
              title: 'Sprawdzenie ${fmtDate(a.timeline.started)} ${fmtClock(a.timeline.started).substring(0, 5)}'),
        )),
      ),
      const SizedBox(height: 8),
      TextButton(onPressed: () => setState(() => _phase = _Phase.intro), child: const Text('Sprawdź ponownie')),
      const SizedBox(height: 12),
      Text(
        'Ocena automatyczna z jednego odprowadzenia – nie zastępuje lekarza. Przy bólu w klatce piersiowej, '
        'duszności, omdleniu lub bardzo szybkim tętnie dzwoń pod 112.',
        style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ]);
  }

  Widget _failed(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error ?? 'Nie udało się wykonać sprawdzenia.'),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => setState(() => _phase = _Phase.intro), child: const Text('Wróć')),
        ]),
      );
}

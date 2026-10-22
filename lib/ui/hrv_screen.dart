import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../analysis/hrv_session.dart';
import '../app_controller.dart';
import '../recording/recorder.dart';
import 'theme/app_theme.dart';
import 'viewer/format.dart';

enum _Phase { intro, settle, measure, done, failed }

/// Prowadzony pomiar HRV w spoczynku (najlepiej rano, na leżąco, zaraz po przebudzeniu):
/// 1 min wyciszenia + 2/3/5 min pomiaru z odstępów RR opaski; wynik porównany z własną normą.
class HrvMeasureScreen extends StatefulWidget {
  final AppController controller;
  const HrvMeasureScreen({super.key, required this.controller});

  @override
  State<HrvMeasureScreen> createState() => _HrvMeasureScreenState();
}

class _HrvMeasureScreenState extends State<HrvMeasureScreen> {
  static const settleSec = 60;
  int _minutes = 2;
  _Phase _phase = _Phase.intro;
  int _elapsed = 0; // sekundy w bieżącej fazie
  final List<double> _rr = [];
  final List<double> _act = [];
  int _movingSec = 0;
  StreamSubscription<List<double>>? _sub;
  Timer? _timer;
  HrvMeasurement? _result;
  List<HrvMeasurement> _history = [];
  Directory? _appDir;

  @override
  void initState() {
    super.initState();
    Recorder.recordingsRoot().then((r) async {
      _appDir = r.parent;
      final h = await HrvHistory.load(r.parent);
      if (mounted) setState(() => _history = h);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  bool get _connected => widget.controller.device != null && widget.controller.link == LinkState.connected;

  void _start() {
    _rr.clear();
    _act.clear();
    _movingSec = 0;
    _sub?.cancel();
    _sub = widget.controller.rrStream.listen((rr) {
      if (_phase == _Phase.measure) _rr.addAll(rr);
    });
    setState(() {
      _phase = _Phase.settle;
      _elapsed = 0;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final act = widget.controller.live?.activityMg;
    setState(() {
      _elapsed++;
      if (_phase == _Phase.measure && act != null) {
        _act.add(act);
        if (act > 60) _movingSec++;
      }
      if (_phase == _Phase.settle && _elapsed >= settleSec) {
        _phase = _Phase.measure;
        _elapsed = 0;
      } else if (_phase == _Phase.measure && _elapsed >= _minutes * 60) {
        _finish();
      }
    });
  }

  Future<void> _finish() async {
    _timer?.cancel();
    _sub?.cancel();
    final act = _act.isEmpty ? null : _act.reduce((a, b) => a + b) / _act.length;
    final m = computeHrv(List.of(_rr), time: DateTime.now(), seconds: _minutes * 60, activityMg: act);
    if (m == null) {
      setState(() => _phase = _Phase.failed);
      return;
    }
    final dir = _appDir ?? (await Recorder.recordingsRoot()).parent;
    await HrvHistory.add(dir, m);
    final h = await HrvHistory.load(dir);
    if (!mounted) return;
    setState(() {
      _result = m;
      _history = h;
      _phase = _Phase.done;
    });
  }

  void _cancel() {
    _timer?.cancel();
    _sub?.cancel();
    setState(() {
      _phase = _Phase.intro;
      _elapsed = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pomiar HRV')),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => switch (_phase) {
          _Phase.intro => _intro(context),
          _Phase.settle || _Phase.measure => _running(context),
          _Phase.done => _done(context),
          _Phase.failed => _failed(context),
        },
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Poranny pomiar zmienności rytmu', style: t.titleMedium),
            const SizedBox(height: 8),
            const Text('Najlepiej codziennie o tej samej porze: zaraz po przebudzeniu, przed kawą i wstaniem z łóżka. '
                'Leż spokojnie na plecach, oddychaj naturalnie, nie rozmawiaj.'),
            const SizedBox(height: 12),
            for (final (i, s) in [
              'Załóż zwilżoną opaskę i połącz ją na ekranie Monitor.',
              '1 minuta wyciszenia – tętno się stabilizuje.',
              'Właściwy pomiar $_minutes min – aplikacja zbiera odstępy RR z opaski.',
              'Wynik: RMSSD i ocena względem Twojej normy z ostatnich 30 dni.',
            ].indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CircleAvatar(radius: 11, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                  const SizedBox(width: 10),
                  Expanded(child: Text(s)),
                ]),
              ),
          ]),
        ),
      ),
      const SectionLabel('Czas pomiaru'),
      SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 2, label: Text('2 min')),
          ButtonSegment(value: 3, label: Text('3 min')),
          ButtonSegment(value: 5, label: Text('5 min')),
        ],
        selected: {_minutes},
        onSelectionChanged: (v) => setState(() => _minutes = v.first),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        icon: const Icon(Icons.play_arrow),
        label: Text(_connected ? 'Rozpocznij pomiar' : 'Najpierw połącz opaskę'),
        onPressed: _connected ? _start : null,
      ),
      if (_history.isNotEmpty) ...[
        const SectionLabel('Ostatnie pomiary'),
        _HistoryCard(history: _history),
      ],
    ]);
  }

  Widget _running(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final colors = AppColors.of(context);
    final settling = _phase == _Phase.settle;
    final total = settling ? settleSec : _minutes * 60;
    final left = max(0, total - _elapsed);
    final act = widget.controller.live?.activityMg;
    final moving = act != null && act > 60;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        const Spacer(),
        Text(settling ? 'Wyciszenie' : 'Pomiar', style: t.headlineSmall),
        const SizedBox(height: 4),
        Text(settling ? 'Leż spokojnie, oddychaj naturalnie' : 'Nie ruszaj się – zbieram odstępy RR',
            style: t.bodyMedium),
        const SizedBox(height: 28),
        SizedBox.square(
          dimension: 220,
          child: Stack(fit: StackFit.expand, children: [
            CircularProgressIndicator(
              value: _elapsed / total,
              strokeWidth: 10,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              color: settling ? Theme.of(context).colorScheme.secondary : colors.ecgAccent,
            ),
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}', style: t.displayMedium),
                Text('${widget.controller.heartRate ?? '–'} /min', style: t.titleMedium),
                if (!settling) Text('${_rr.length} odstępów RR', style: t.labelSmall),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 24),
        if (moving)
          StatusPill(icon: Icons.directions_walk, text: 'Wykryto ruch – leż nieruchomo', color: colors.warning)
        else if (widget.controller.skinContact == false)
          StatusPill(icon: Icons.touch_app, text: 'Brak kontaktu elektrod', color: colors.danger)
        else
          StatusPill(icon: Icons.check_circle, text: 'Sygnał w porządku', color: colors.ok),
        const Spacer(),
        OutlinedButton(onPressed: _cancel, child: const Text('Przerwij')),
      ]),
    );
  }

  Widget _done(BuildContext context) {
    final m = _result!;
    final t = Theme.of(context).textTheme;
    final colors = AppColors.of(context);
    final b = hrvBaseline(_history, m);
    final color = switch (b.status) {
      HrvStatus.low => colors.warning,
      HrvStatus.high => colors.info,
      HrvStatus.normal => colors.ok,
      HrvStatus.unknown => Theme.of(context).colorScheme.outline,
    };
    final movedPct = _act.isEmpty ? 0 : 100 * _movingSec / _act.length;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('RMSSD', style: t.labelMedium),
            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Text(m.rmssd.toStringAsFixed(0), style: t.displayMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 6),
              Text('ms', style: t.titleMedium),
              const Spacer(),
              Text('ln RMSSD ${m.lnRmssd.toStringAsFixed(2)}', style: t.labelMedium),
            ]),
            const SizedBox(height: 10),
            StatusPill(icon: Icons.insights, text: b.status.label, color: color),
            if (b.loMs != null) ...[
              const SizedBox(height: 6),
              Text('Twoja norma (30 dni): ${b.loMs!.round()}–${b.hiMs!.round()} ms', style: t.bodySmall),
            ],
            const SizedBox(height: 8),
            Text(switch (b.status) {
              HrvStatus.low => 'Niższa zmienność niż zwykle – możliwe zmęczenie, stres, słaby sen, początek infekcji '
                  'lub alkohol poprzedniego dnia. Rozważ lżejszy dzień.',
              HrvStatus.high => 'Wyższa zmienność niż zwykle – zwykle dobra regeneracja. Pojedynczy wysoki wynik bywa też '
                  'skutkiem bardzo dużego zmęczenia – oceniaj razem z samopoczuciem.',
              HrvStatus.normal => 'Wynik w Twoim typowym zakresie.',
              HrvStatus.unknown => 'Ocena pojawi się po co najmniej 5 pomiarach w ciągu 30 dni.',
            }, style: t.bodyMedium),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      MetricGrid(children: [
        MetricTile('Tętno', m.hr.toStringAsFixed(0), unit: '/min', icon: Icons.favorite_border),
        MetricTile('SDNN', m.sdnn.toStringAsFixed(0), unit: 'ms', icon: Icons.ssid_chart),
        MetricTile('pNN50', m.pnn50.toStringAsFixed(1), unit: '%', icon: Icons.ssid_chart),
        MetricTile('Odstępy RR', '${m.beats}', sub: 'odrzucone ${m.correctedPct.toStringAsFixed(1)}%', icon: Icons.tag),
      ]),
      if (!m.reliable || movedPct > 20) ...[
        const SizedBox(height: 10),
        Card(
          color: colors.warning.withValues(alpha: 0.12),
          child: ListTile(
            leading: Icon(Icons.warning_amber_rounded, color: colors.warning),
            title: const Text('Wynik mniej wiarygodny'),
            subtitle: Text([
              if (m.correctedPct > 5) 'odrzucono ${m.correctedPct.toStringAsFixed(0)}% odstępów (artefakty lub pobudzenia dodatkowe)',
              if (m.beats < 60) 'za mało uderzeń',
              if (movedPct > 20) 'ruch przez ${movedPct.round()}% pomiaru',
            ].join('; ')),
          ),
        ),
      ],
      const SectionLabel('Ostatnie pomiary'),
      _HistoryCard(history: _history),
      const SizedBox(height: 16),
      FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Gotowe')),
    ]);
  }

  Widget _failed(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline, size: 48, color: AppColors.of(context).danger),
            const SizedBox(height: 12),
            const Text('Za mało poprawnych odstępów RR. Sprawdź kontakt elektrod (zwilż opaskę) i spróbuj ponownie.',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => setState(() => _phase = _Phase.intro), child: const Text('Spróbuj ponownie')),
          ]),
        ),
      );
}

/// Ostatnie pomiary: wykres słupkowy RMSSD (14 ostatnich) i lista.
class _HistoryCard extends StatelessWidget {
  final List<HrvMeasurement> history;
  const _HistoryCard({required this.history});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final colors = AppColors.of(context);
    final last = history.length > 14 ? history.sublist(history.length - 14) : history;
    final maxV = last.map((h) => h.rmssd).reduce(max);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          SizedBox(
            height: 90,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (final h in last)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                      Text(h.rmssd.round().toString(), style: t.labelSmall?.copyWith(fontSize: 9)),
                      const SizedBox(height: 2),
                      Container(
                        height: max(4.0, 64 * h.rmssd / maxV),
                        decoration: BoxDecoration(
                          color: switch (hrvBaseline(history, h).status) {
                            HrvStatus.low => colors.warning,
                            HrvStatus.high => colors.info,
                            HrvStatus.normal => colors.ok,
                            HrvStatus.unknown => Theme.of(context).colorScheme.outline,
                          }.withValues(alpha: h.reliable ? 0.85 : 0.35),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ]),
                  ),
                ),
            ]),
          ),
          const Divider(height: 20),
          for (final h in history.reversed.take(7))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(child: Text('${fmtDate(h.time)}  ${fmtClock(h.time).substring(0, 5)}', style: t.bodySmall)),
                Text('${h.rmssd.round()} ms', style: t.titleSmall),
                const SizedBox(width: 12),
                SizedBox(width: 56, child: Text('${h.hr.round()} /min', style: t.bodySmall, textAlign: TextAlign.end)),
              ]),
            ),
        ]),
      ),
    );
  }
}

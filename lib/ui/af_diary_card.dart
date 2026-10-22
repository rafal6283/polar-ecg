import 'dart:math';

import 'package:flutter/material.dart';

import '../analysis/af_episodes.dart';
import '../recording/recorder.dart';
import 'theme/app_theme.dart';
import 'viewer/format.dart';
import 'viewer/recording_screen.dart';

/// Napady AF z podsumowań zapisów (summary.json → 'af_episodes').
AfDiary diaryFromSummaries(List<Map<String, dynamic>> rows, {DateTime? since}) => AfDiary.build([
      for (final r in rows)
        if (since == null || DateTime.parse(r['started'] as String).isAfter(since))
          (
            started: DateTime.parse(r['started'] as String),
            seconds: ((r['analyzed_s'] ?? r['duration_s'] ?? 0) as num).toDouble(),
            episodes: [
              for (final e in (r['af_episodes'] as List? ?? const [])) AfEpisode.fromJson(e as Map<String, dynamic>)
            ],
          ),
    ]);

String _hm(double sec) {
  final m = (sec / 60).round();
  if (m < 60) return sec < 60 ? '${sec.round()} s' : '$m min';
  return '${m ~/ 60} h ${m % 60} min';
}

/// Dziennik napadów migotania przedsionków: obciążenie, najdłuższy napad, tętno w AF, pora i okoliczności.
class AfDiaryCard extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  const AfDiaryCard({super.key, required this.rows});

  @override
  State<AfDiaryCard> createState() => _AfDiaryCardState();
}

class _AfDiaryCardState extends State<AfDiaryCard> {
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final colors = AppColors.of(context);
    final d = diaryFromSummaries(widget.rows,
        since: _days == 0 ? null : DateTime.now().subtract(Duration(days: _days)));
    final longest = d.longest;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel('Napady migotania przedsionków',
          trailing: SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: 7, label: Text('7 d')),
              ButtonSegment(value: 30, label: Text('30 d')),
              ButtonSegment(value: 0, label: Text('wsz.')),
            ],
            selected: {_days},
            onSelectionChanged: (s) => setState(() => _days = s.first),
          )),
      MetricGrid(children: [
        MetricTile('Monitorowano', _hm(d.monitoredSec), icon: Icons.schedule),
        MetricTile('Napady', '${d.episodes.length}',
            color: d.episodes.isEmpty ? null : colors.af, icon: Icons.monitor_heart_outlined),
        MetricTile('Czas w AF', _hm(d.afSec),
            sub: d.burdenPct == null ? null : 'obciążenie ${d.burdenPct!.toStringAsFixed(d.burdenPct! < 10 ? 1 : 0)}%',
            icon: Icons.timelapse),
        MetricTile('Najdłuższy', longest == null ? '–' : _hm(longest.duration.inMilliseconds / 1000),
            sub: longest == null ? null : fmtDate(longest.start), icon: Icons.straighten),
        MetricTile('Tętno w AF', d.hrInAf?.round().toString() ?? '–',
            unit: '/min', sub: d.hrMaxInAf == null ? null : 'maks. ${d.hrMaxInAf!.round()}/min', icon: Icons.favorite_border),
      ]),
      if (d.episodes.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Pora rozpoczęcia napadów', style: t.titleSmall),
        const SizedBox(height: 6),
        SizedBox(
          height: 90,
          child: CustomPaint(
            painter: _HoursPainter(d.onsetHours, colors.af, Theme.of(context).colorScheme,
                t.labelSmall ?? const TextStyle(fontSize: 10)),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Okoliczności: w spoczynku/nocy ${d.countPattern('rest')}, przy wysiłku lub szybkim rytmie '
          '${d.countPattern('exertion')}, nieustalone ${d.countPattern('unknown')}; '
          'poprzedzone pobudzeniami S: ${d.withSBefore}.',
          style: t.bodySmall,
        ),
        Text(
          'Opis okoliczności (tętno, ruch, pobudzenia dodatkowe w 5 min przed napadem) pomaga lekarzowi '
          'dobrać leczenie – to nie jest rozpoznanie.',
          style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(children: [
            for (final (i, e) in d.episodes.reversed.take(30).indexed) ...[
              if (i > 0) const Divider(indent: 16, endIndent: 16),
              ListTile(
                dense: true,
                leading: e.confirmed
                    ? Icon(Icons.verified, size: 18, color: colors.af)
                    : Icon(Icons.circle, size: 12, color: colors.af),
                title: Text('${fmtDate(e.start)}  ${fmtClock(e.start).substring(0, 5)} · '
                    '${_hm(e.duration.inMilliseconds / 1000)} · ${e.hrMean.round()}/min'),
                subtitle: Text(e.circumstances.join(', ')),
                trailing: e.recording.isEmpty ? null : const Icon(Icons.chevron_right),
                onTap: e.recording.isEmpty ? null : () => _open(context, e),
              ),
            ],
          ]),
        ),
      ] else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            d.monitoredSec > 0 ? 'Brak napadów AF w zapisach z tego okresu.' : 'Brak zapisów z tego okresu.',
            style: t.bodySmall,
          ),
        ),
    ]);
  }

  Future<void> _open(BuildContext context, AfEpisode e) async {
    final root = await Recorder.recordingsRoot();
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RecordingScreen(
        path: '${root.path}/${e.recording}',
        title: '${fmtDate(e.start)} ${fmtClock(e.start).substring(0, 5)}',
        initialSample: e.startSample,
        initialEndSample: e.endSample,
      ),
    ));
  }
}

/// Histogram 24 godzin (jedna seria – bez legendy; oś: 0, 6, 12, 18, 24).
class _HoursPainter extends CustomPainter {
  final List<int> counts;
  final Color color;
  final ColorScheme scheme;
  final TextStyle style;
  _HoursPainter(this.counts, this.color, this.scheme, this.style);

  @override
  void paint(Canvas canvas, Size size) {
    const bottom = 16.0;
    final h = size.height - bottom;
    final mx = max(1, counts.reduce(max));
    final slot = size.width / 24;
    canvas.drawLine(Offset(0, h), Offset(size.width, h), Paint()..color = scheme.outlineVariant..strokeWidth = 1);
    for (var k = 0; k < 24; k++) {
      if (counts[k] == 0) continue;
      final bh = max(3.0, counts[k] / mx * (h - 12));
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(k * slot + 1, h - bh, slot - 2, bh),
        topLeft: const Radius.circular(3),
        topRight: const Radius.circular(3),
      );
      canvas.drawRRect(rect, Paint()..color = color);
      _text(canvas, '${counts[k]}', Offset(k * slot + slot / 2, h - bh - 12), center: true);
    }
    for (final hr in [0, 6, 12, 18]) {
      _text(canvas, '$hr:00', Offset(hr * slot, h + 2));
    }
  }

  void _text(Canvas c, String s, Offset o, {bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style.copyWith(color: scheme.onSurfaceVariant, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center ? o - Offset(tp.width / 2, 0) : o);
  }

  @override
  bool shouldRepaint(covariant _HoursPainter old) => old.counts != counts || old.color != color;
}

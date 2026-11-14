import 'package:flutter/material.dart';

import '../analysis/sv_trend.dart';
import 'theme/app_theme.dart';
import 'viewer/format.dart';

/// Karta w Trendach: ostatni zapis – pobudzenia S/h względem Twojej normy.
class SvTrendCard extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const SvTrendCard({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final tr = svTrend([
      for (final r in rows)
        if (r['s_per_h'] != null)
          (
            DateTime.parse(r['started'] as String),
            (r['s_per_h'] as num).toDouble(),
            ((r['analyzed_s'] ?? 0) as num).toDouble() / 3600,
          ),
    ]);
    if (tr.last == null) return const SizedBox.shrink();
    final colors = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return Card(
      color: tr.elevated ? colors.warning.withValues(alpha: 0.12) : null,
      child: ListTile(
        leading: Icon(tr.elevated ? Icons.trending_up : Icons.bolt, color: tr.elevated ? colors.warning : colors.beatS),
        title: Text(tr.elevated
            ? 'Więcej pobudzeń nadkomorowych niż zwykle'
            : 'Pobudzenia nadkomorowe (S): ${tr.last!.toStringAsFixed(1)}/h'),
        subtitle: Text([
          'ostatni zapis ${fmtDate(tr.lastAt!)}: ${tr.last!.toStringAsFixed(1)}/h',
          if (tr.norm != null) 'Twoja norma (30 dni): ${tr.norm!.toStringAsFixed(1)}/h'
          else 'norma po 5 zapisach ≥ 1 h (jest ${tr.samples})',
          if (tr.elevated) 'częste S bywają zapowiedzią napadu – obserwuj objawy, zadbaj o sen i nawodnienie',
        ].join(' · '), style: t.bodySmall),
      ),
    );
  }
}

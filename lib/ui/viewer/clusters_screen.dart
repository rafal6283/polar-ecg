
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../analysis/analysis_result.dart';
import '../../analysis/beat_clusters.dart';

/// Przegląd grup morfologii (jak w programach holterowskich): pobudzenia o podobnym kształcie QRS
/// są zebrane w grupy; całej grupie można jednym ruchem nadać etykietę. Zmiany wracają do ekranu
/// zapisu jako poprawki ręczne (uczą też profil osobisty).
List<BeatCluster> _cluster((AnalysisResult, Float32List) x) => clusterBeats(x.$1, x.$2);

class ClustersScreen extends StatefulWidget {
  final AnalysisResult analysis;
  final Float32List signal;

  const ClustersScreen({super.key, required this.analysis, required this.signal});

  @override
  State<ClustersScreen> createState() => _ClustersScreenState();
}

class _ClustersScreenState extends State<ClustersScreen> {
  List<BeatCluster>? _groups;
  final Map<int, int> _changes = {}; // próbka R -> etykieta
  final Map<int, int> _groupChoice = {}; // indeks grupy -> wybrana etykieta

  @override
  void initState() {
    super.initState();
    compute(_cluster, (widget.analysis, widget.signal)).then((g) {
      if (mounted) setState(() => _groups = g);
    });
  }

  void _choose(int gi, BeatCluster g, int label) {
    setState(() {
      // Cofnięcie poprzedniego wyboru dla tej grupy.
      for (final i in g.members) {
        _changes.remove(widget.analysis.rPeaks[i]);
      }
      if (_groupChoice[gi] == label) {
        _groupChoice.remove(gi);
        return;
      }
      _groupChoice[gi] = label;
      _changes.addAll(clusterCorrections(widget.analysis, g, label));
    });
  }

  @override
  Widget build(BuildContext context) {
    final g = _groups;
    return Scaffold(
      appBar: AppBar(title: const Text('Grupy morfologii')),
      floatingActionButton: _changes.isEmpty
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.check),
              label: Text('Zastosuj (${_changes.length})'),
              onPressed: () => Navigator.pop(context, Map<int, int>.from(_changes)),
            ),
      body: g == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              children: [
                Text(
                  'Pobudzenia o podobnym kształcie QRS zebrane w grupy. Grupy komorowe i mieszane są na górze. '
                  'Wybór „Prawidłowe” zmienia tylko pobudzenia oznaczone jako V (S zostają – to cecha rytmu).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final (gi, c) in g.indexed)
                  _ClusterCard(
                    cluster: c,
                    analysis: widget.analysis,
                    signal: widget.signal,
                    choice: _groupChoice[gi],
                    onChoose: (l) => _choose(gi, c, l),
                  ),
              ],
            ),
    );
  }
}

class _ClusterCard extends StatelessWidget {
  final BeatCluster cluster;
  final AnalysisResult analysis;
  final Float32List signal;
  final int? choice;
  final ValueChanged<int> onChoose;

  const _ClusterCard({
    required this.cluster,
    required this.analysis,
    required this.signal,
    required this.choice,
    required this.onChoose,
  });

  static const _names = ['N', 'S', 'V', 'Q'];

  @override
  Widget build(BuildContext context) {
    final c = cluster;
    final t = Theme.of(context).textTheme;
    final dom = c.dominantLabel;
    final review = dom == BeatType.ventricular || c.mixed;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('${c.size} pobudzeń', style: t.titleSmall),
              const SizedBox(width: 8),
              if (review)
                Chip(
                  label: Text(c.mixed ? 'mieszana' : 'komorowa'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: const Color(0x22F57C00),
                ),
              const Spacer(),
              Text([for (var l = 0; l < 4; l++) if (c.labelCounts[l] > 0) '${_names[l]} ${c.labelCounts[l]}'].join(' · ')),
            ]),
            const SizedBox(height: 6),
            SizedBox(
              height: 110,
              width: double.infinity,
              child: CustomPaint(painter: _ClusterPainter(c, analysis, signal, Theme.of(context).colorScheme)),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: [
              for (final (label, text) in [
                (BeatType.normal, 'Prawidłowe'),
                (BeatType.ventricular, 'Komorowe (V)'),
                (BeatType.unknown, 'Artefakt'),
              ])
                ChoiceChip(label: Text(text), selected: choice == label, onSelected: (_) => onChoose(label)),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Środek grupy (gruba linia) na tle do 12 przykładowych pobudzeń.
class _ClusterPainter extends CustomPainter {
  final BeatCluster c;
  final AnalysisResult a;
  final Float32List sig;
  final ColorScheme scheme;

  _ClusterPainter(this.c, this.a, this.sig, this.scheme);

  @override
  void paint(Canvas canvas, Size size) {
    final len = c.centroid.length;
    final ex = c.examples(12);
    var lo = double.infinity, hi = -double.infinity;
    void range(double v) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }

    for (final v in c.centroid) {
      range(v);
    }
    for (final i in ex) {
      final r = a.rPeaks[i];
      for (var k = 0; k < len; k++) {
        final s = r - c.pre + k;
        if (s >= 0 && s < sig.length) range(sig[s]);
      }
    }
    if (hi <= lo) return;
    double x(int k) => k / (len - 1) * size.width;
    double y(double v) => size.height - (v - lo) / (hi - lo) * size.height;
    final thin = Paint()
      ..color = scheme.outline.withValues(alpha: 0.35)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final i in ex) {
      final r = a.rPeaks[i];
      final p = Path();
      for (var k = 0; k < len; k++) {
        final s = (r - c.pre + k).clamp(0, sig.length - 1);
        k == 0 ? p.moveTo(x(k), y(sig[s])) : p.lineTo(x(k), y(sig[s]));
      }
      canvas.drawPath(p, thin);
    }
    final bold = Paint()
      ..color = c.dominantLabel == BeatType.ventricular ? const Color(0xFFC62828) : scheme.onSurface
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    final p = Path();
    for (var k = 0; k < len; k++) {
      k == 0 ? p.moveTo(x(k), y(c.centroid[k])) : p.lineTo(x(k), y(c.centroid[k]));
    }
    canvas.drawPath(p, bold);
  }

  @override
  bool shouldRepaint(covariant _ClusterPainter old) => old.c != c;
}

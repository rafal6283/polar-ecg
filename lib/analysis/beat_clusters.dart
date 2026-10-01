import 'dart:math';
import 'dart:typed_data';

import 'analysis_result.dart';

/// Grupa pobudzeń o podobnym kształcie QRS (jak „klasy morfologii” w programach holterowskich).
class BeatCluster {
  final List<int> members; // indeksy pobudzeń (AnalysisResult.rPeaks)
  final Float32List centroid; // średni kształt [µV], R w indeksie [pre]
  final int pre;
  final List<int> labelCounts; // N, S, V, Q

  BeatCluster(this.members, this.centroid, this.pre, this.labelCounts);

  int get size => members.length;

  int get dominantLabel {
    var best = 0;
    for (var l = 1; l < 4; l++) {
      if (labelCounts[l] > labelCounts[best]) best = l;
    }
    return best;
  }

  /// Etykiety w grupie są mieszane (≥ 10% pobudzeń inaczej niż większość) – warto przejrzeć.
  bool get mixed => size - labelCounts[dominantLabel] >= max(1, 0.1 * size);

  /// Przykłady rozłożone równomiernie w czasie.
  List<int> examples(int k) => members.length <= k
      ? members
      : [for (var j = 0; j < k; j++) members[j * members.length ~/ k]];
}

/// Grupowanie zachłanne: pobudzenie trafia do grupy o najwyższej korelacji kształtu QRS
/// (≥ minCorr, amplituda 0.7–1.4× środka grupy), inaczej zakłada nową grupę (najwyżej maxClusters;
/// potem – do najbliższej). Środek grupy to średnia bieżąca. Wynik posortowany wg liczności;
/// grupy V i mieszane wyżej, bo to je warto przejrzeć.
List<BeatCluster> clusterBeats(AnalysisResult a, Float32List filtered,
    {double minCorr = 0.92, int maxClusters = 40}) {
  final fs = a.sampleRate;
  final pre = (0.09 * fs).round(), post = (0.125 * fs).round();
  final len = pre + post + 1;
  final sums = <Float64List>[];
  final cents = <Float64List>[];
  final members = <List<int>>[];
  final centP2p = <double>[];
  final w = Float64List(len);
  for (var i = 0; i < a.rPeaks.length; i++) {
    final r = a.rPeaks[i];
    if (r - pre < 0 || r + post >= filtered.length) continue;
    for (var k = 0; k < len; k++) {
      w[k] = filtered[r - pre + k];
    }
    final wp = _p2p(w);
    if (wp <= 0) continue;
    var best = -1, bestC = -2.0;
    for (var c = 0; c < cents.length; c++) {
      final ar = wp / max(1e-9, centP2p[c]);
      if (ar < 0.7 || ar > 1.4) continue;
      final corr = _pearson(w, cents[c]);
      if (corr > bestC) {
        bestC = corr;
        best = c;
      }
    }
    if (best < 0 || bestC < minCorr) {
      if (cents.length < maxClusters) {
        sums.add(Float64List(len));
        cents.add(Float64List(len));
        members.add([]);
        centP2p.add(0);
        best = cents.length - 1;
      } else if (best < 0) {
        // Wszystkie grupy zajęte i żadna nie pasuje amplitudą – najbliższa wg korelacji.
        for (var c = 0; c < cents.length; c++) {
          final corr = _pearson(w, cents[c]);
          if (corr > bestC) {
            bestC = corr;
            best = c;
          }
        }
      }
    }
    members[best].add(i);
    final m = members[best].length;
    for (var k = 0; k < len; k++) {
      sums[best][k] += w[k];
      cents[best][k] = sums[best][k] / m;
    }
    centP2p[best] = _p2p(cents[best]);
  }
  final out = <BeatCluster>[];
  for (var c = 0; c < cents.length; c++) {
    final counts = List<int>.filled(4, 0);
    for (final i in members[c]) {
      counts[a.labels[i]]++;
    }
    out.add(BeatCluster(members[c], Float32List.fromList(cents[c]), pre, counts));
  }
  int rank(BeatCluster c) => (c.dominantLabel == BeatType.ventricular || c.mixed) ? 0 : 1;
  out.sort((x, y) {
    final r = rank(x).compareTo(rank(y));
    return r != 0 ? r : y.size.compareTo(x.size);
  });
  return out;
}

double _p2p(Float64List v) {
  var mn = double.infinity, mx = -double.infinity;
  for (final x in v) {
    mn = min(mn, x);
    mx = max(mx, x);
  }
  return mx - mn;
}

double _pearson(Float64List a, Float64List b) {
  final n = a.length;
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < n; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= n;
  mb /= n;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < n; i++) {
    final x = a[i] - ma, y = b[i] - mb;
    num += x * y;
    da += x * x;
    db += y * y;
  }
  return da <= 0 || db <= 0 ? 0 : num / sqrt(da * db);
}

/// Zmiana etykiet całej grupy: poprawki tylko dla pobudzeń, których etykieta się zmienia.
/// [toLabel]: BeatType.ventricular – wszystkie V; BeatType.unknown – artefakt (Q);
/// BeatType.normal – „nie komorowe”: V → N, pozostałe bez zmian (S zostaje S, bo to cecha rytmu).
Map<int, int> clusterCorrections(AnalysisResult a, BeatCluster c, int toLabel) {
  final out = <int, int>{};
  for (final i in c.members) {
    final l = a.labels[i];
    final target = toLabel == BeatType.normal ? (l == BeatType.ventricular ? BeatType.normal : l) : toLabel;
    if (target != l) out[a.rPeaks[i]] = target;
  }
  return out;
}

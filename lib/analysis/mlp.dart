import 'dart:math';
import 'dart:typed_data';

/// Mały perceptron wielowarstwowy (ReLU, softmax) – bez zależności, działa na telefonie.
class Mlp {
  final Float64List mean, std; // standaryzacja wejść
  final List<Float64List> weights; // warstwa l: [out × in] wierszami
  final List<Float64List> biases;
  final List<int> sizes; // [in, h1, ..., out]
  final Map<String, double> meta; // np. progi decyzyjne

  Mlp(this.sizes, this.mean, this.std, this.weights, this.biases, {this.meta = const {}});

  factory Mlp.random(List<int> sizes, Float64List mean, Float64List std, {int seed = 1}) {
    final rnd = Random(seed);
    final w = <Float64List>[], b = <Float64List>[];
    for (var l = 0; l < sizes.length - 1; l++) {
      final fanIn = sizes[l], fanOut = sizes[l + 1];
      final scale = sqrt(2 / fanIn); // He
      w.add(Float64List.fromList(List.generate(fanIn * fanOut, (_) => _gauss(rnd) * scale)));
      b.add(Float64List(fanOut));
    }
    return Mlp(sizes, mean, std, w, b);
  }

  int get inputs => sizes.first;
  int get outputs => sizes.last;

  /// Prawdopodobieństwa klas.
  Float64List predict(List<double> x) {
    var a = Float64List(inputs);
    for (var i = 0; i < inputs; i++) {
      a[i] = (x[i] - mean[i]) / std[i];
    }
    for (var l = 0; l < weights.length; l++) {
      final nIn = sizes[l], nOut = sizes[l + 1];
      final z = Float64List(nOut);
      final w = weights[l];
      for (var o = 0; o < nOut; o++) {
        var s = biases[l][o];
        final row = o * nIn;
        for (var i = 0; i < nIn; i++) {
          s += w[row + i] * a[i];
        }
        z[o] = l < weights.length - 1 ? max(0.0, s) : s;
      }
      a = z;
    }
    return _softmax(a);
  }

  Map<String, dynamic> toJson() => {
        'sizes': sizes,
        'mean': mean,
        'std': std,
        'weights': [for (final w in weights) w.map((v) => double.parse(v.toStringAsPrecision(6))).toList()],
        'biases': [for (final b in biases) b.map((v) => double.parse(v.toStringAsPrecision(6))).toList()],
        'meta': meta,
      };

  factory Mlp.fromJson(Map<String, dynamic> j) {
    Float64List f(dynamic v) => Float64List.fromList([for (final x in v as List) (x as num).toDouble()]);
    return Mlp(
      (j['sizes'] as List).cast<int>(),
      f(j['mean']),
      f(j['std']),
      [for (final w in j['weights'] as List) f(w)],
      [for (final b in j['biases'] as List) f(b)],
      meta: {for (final e in (j['meta'] as Map? ?? {}).entries) e.key as String: (e.value as num).toDouble()},
    );
  }

  static Float64List _softmax(Float64List z) {
    final m = z.reduce(max);
    final e = Float64List.fromList([for (final v in z) exp(v - m)]);
    final s = e.reduce((a, b) => a + b);
    for (var i = 0; i < e.length; i++) {
      e[i] /= s;
    }
    return e;
  }

  static double _gauss(Random r) => sqrt(-2 * log(max(1e-12, r.nextDouble()))) * cos(2 * pi * r.nextDouble());
}

/// Uczenie metodą Adam z wagami klas (entropia krzyżowa).
class MlpTrainer {
  final Mlp net;
  final double lr;
  final double l2;
  final double inputNoise; // odchylenie szumu dodawanego do standaryzowanych wejść (augmentacja)
  late final List<Float64List> _mw, _vw, _mb, _vb;
  int _t = 0;

  MlpTrainer(this.net, {this.lr = 1e-3, this.l2 = 1e-4, this.inputNoise = 0}) {
    _mw = [for (final w in net.weights) Float64List(w.length)];
    _vw = [for (final w in net.weights) Float64List(w.length)];
    _mb = [for (final b in net.biases) Float64List(b.length)];
    _vb = [for (final b in net.biases) Float64List(b.length)];
  }

  /// Jedna epoka; zwraca średnią stratę.
  double epoch(List<List<double>> xs, List<int> ys, List<double> classWeight, Random rnd, {int batch = 128}) {
    final order = List.generate(xs.length, (i) => i)..shuffle(rnd);
    final L = net.weights.length;
    var lossSum = 0.0;
    for (var b0 = 0; b0 < order.length; b0 += batch) {
      final gw = [for (final w in net.weights) Float64List(w.length)];
      final gb = [for (final b in net.biases) Float64List(b.length)];
      final end = min(order.length, b0 + batch);
      var wsum = 0.0;
      for (var k = b0; k < end; k++) {
        final idx = order[k];
        final cw = classWeight[ys[idx]];
        wsum += cw;
        // Forward z zapamiętaniem aktywacji.
        final acts = <Float64List>[];
        var a = Float64List(net.inputs);
        for (var i = 0; i < net.inputs; i++) {
          a[i] = (xs[idx][i] - net.mean[i]) / net.std[i] + (inputNoise > 0 ? inputNoise * Mlp._gauss(rnd) : 0);
        }
        acts.add(a);
        for (var l = 0; l < L; l++) {
          final nIn = net.sizes[l], nOut = net.sizes[l + 1];
          final z = Float64List(nOut);
          for (var o = 0; o < nOut; o++) {
            var s = net.biases[l][o];
            for (var i = 0; i < nIn; i++) {
              s += net.weights[l][o * nIn + i] * a[i];
            }
            z[o] = l < L - 1 ? max(0.0, s) : s;
          }
          a = z;
          acts.add(a);
        }
        final p = Mlp._softmax(acts.last);
        lossSum += -cw * log(max(1e-12, p[ys[idx]]));
        // Backward.
        var delta = Float64List.fromList(p);
        delta[ys[idx]] -= 1;
        for (var o = 0; o < delta.length; o++) {
          delta[o] *= cw;
        }
        for (var l = L - 1; l >= 0; l--) {
          final nIn = net.sizes[l], nOut = net.sizes[l + 1];
          final aIn = acts[l];
          final prev = Float64List(nIn);
          for (var o = 0; o < nOut; o++) {
            final d = delta[o];
            if (d == 0) continue;
            gb[l][o] += d;
            final row = o * nIn;
            for (var i = 0; i < nIn; i++) {
              gw[l][row + i] += d * aIn[i];
              prev[i] += d * net.weights[l][row + i];
            }
          }
          if (l > 0) {
            for (var i = 0; i < nIn; i++) {
              if (acts[l][i] <= 0) prev[i] = 0; // ReLU
            }
          }
          delta = prev;
        }
      }
      _step(gw, gb, wsum);
    }
    return lossSum / xs.length;
  }

  void _step(List<Float64List> gw, List<Float64List> gb, double norm) {
    const b1 = 0.9, b2 = 0.999, eps = 1e-8;
    _t++;
    final c1 = 1 - pow(b1, _t), c2 = 1 - pow(b2, _t);
    void upd(Float64List p, Float64List g, Float64List m, Float64List v, bool decay) {
      for (var i = 0; i < p.length; i++) {
        final gi = g[i] / norm + (decay ? l2 * p[i] : 0);
        m[i] = b1 * m[i] + (1 - b1) * gi;
        v[i] = b2 * v[i] + (1 - b2) * gi * gi;
        p[i] -= lr * (m[i] / c1) / (sqrt(v[i] / c2) + eps);
      }
    }

    for (var l = 0; l < net.weights.length; l++) {
      upd(net.weights[l], gw[l], _mw[l], _vw[l], true);
      upd(net.biases[l], gb[l], _mb[l], _vb[l], false);
    }
  }
}

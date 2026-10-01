import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../recording/binary_format.dart';

/// Ciągły fragment zapisu (bez przerw w transmisji).
class Segment {
  final int start; // indeks pierwszej próbki w połączonym sygnale
  final int length;
  final int t0Ns; // czas pierwszej próbki wg zegara opaski

  const Segment(this.start, this.length, this.t0Ns);

  int get end => start + length;

  List<int> toJson() => [start, length, t0Ns];

  factory Segment.fromJson(List<dynamic> j) => Segment(j[0] as int, j[1] as int, j[2] as int);
}

/// Mapowanie indeksu próbki na czas zegarowy.
class Timeline {
  final DateTime started;
  final int sampleRate;
  final List<Segment> segments;

  Timeline(this.started, this.sampleRate, this.segments);

  int get totalSamples => segments.isEmpty ? 0 : segments.last.end;

  int segmentIndexOf(int sample) {
    var lo = 0, hi = segments.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (segments[mid].start <= sample) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Czas próbki liczony od początku zapisu (uwzględnia przerwy).
  Duration offsetOf(num sample) {
    if (segments.isEmpty) return Duration.zero;
    final s = segments[segmentIndexOf(sample.floor())];
    final ns = s.t0Ns - segments.first.t0Ns + ((sample - s.start) * 1e9 / sampleRate).round();
    return Duration(microseconds: ns ~/ 1000);
  }

  DateTime timeOf(num sample) => started.add(offsetOf(sample));

  /// Najbliższa próbka dla zadanego czasu od początku zapisu.
  int sampleAt(Duration offset) {
    if (segments.isEmpty) return 0;
    final ns = offset.inMicroseconds * 1000 + segments.first.t0Ns;
    for (var i = segments.length - 1; i >= 0; i--) {
      final s = segments[i];
      if (ns >= s.t0Ns) {
        final k = ((ns - s.t0Ns) * sampleRate / 1e9).round();
        return s.start + k.clamp(0, s.length - 1);
      }
    }
    return 0;
  }

  Duration get totalDuration =>
      segments.isEmpty ? Duration.zero : offsetOf(segments.last.end - 1) + Duration(microseconds: 1000000 ~/ sampleRate);
}

/// Surowy zapis wczytany z ecg.bin (lub starszego ecg.csv) + aktywność z acc.bin.
class EcgRecording {
  final Directory dir;
  final Timeline timeline;
  final Float32List uv;

  /// Aktywność [mg] w oknach 2 s EKG (odch. std. modułu przyspieszenia); -1 = brak danych.
  final Float32List? activity;

  EcgRecording(this.dir, this.timeline, this.uv, [this.activity]);

  int get sampleRate => timeline.sampleRate;

  static Future<EcgRecording> load(Directory dir) async {
    final meta = jsonDecode(await File('${dir.path}/meta.json').readAsString()) as Map<String, dynamic>;
    final fs = (meta['sample_rate_hz'] as num?)?.toInt() ?? 130;
    final started = DateTime.parse(meta['started'] as String);
    final stepNs = 1e9 / fs;

    final builder = _FloatBuilder();
    final segments = <Segment>[];
    var segStart = 0, segT0 = 0, prevT = -1, count = 0;

    void addSample(int t, double v) {
      if (prevT < 0) {
        segT0 = t;
      } else if (t - prevT > 1.5 * stepNs || t <= prevT) {
        segments.add(Segment(segStart, count - segStart, segT0));
        segStart = count;
        segT0 = t;
      }
      builder.add(v);
      prevT = t;
      count++;
    }

    final bin = await BinaryStream.read(File('${dir.path}/ecg.bin'));
    if (bin != null) {
      final step = (1e9 / fs).round();
      for (final fr in bin.frames) {
        final n = fr.samples.length;
        for (var i = 0; i < n; i++) {
          addSample(fr.timestampNs - (n - 1 - i) * step, fr.samples[i].toDouble());
        }
      }
      if (count > segStart) segments.add(Segment(segStart, count - segStart, segT0));
      final tl = Timeline(started, fs, segments);
      final acc = await BinaryStream.read(File('${dir.path}/acc.bin'));
      return EcgRecording(dir, tl, builder.build(), acc == null ? null : _activity(acc, tl));
    }

    final lines = File('${dir.path}/ecg.csv').openRead().transform(utf8.decoder).transform(const LineSplitter());
    var header = true;
    await for (final line in lines) {
      if (header) {
        header = false;
        continue;
      }
      final comma = line.indexOf(',');
      if (comma <= 0) continue;
      final t = int.tryParse(line.substring(0, comma));
      final v = int.tryParse(line.substring(comma + 1));
      if (t == null || v == null) continue;
      addSample(t, v.toDouble());
    }
    if (count > segStart) segments.add(Segment(segStart, count - segStart, segT0));
    return EcgRecording(dir, Timeline(started, fs, segments), builder.build());
  }
}

/// Aktywność w oknach 2 s osi czasu EKG: odchylenie standardowe modułu przyspieszenia [mg].
Float32List _activity(BinaryStream acc, Timeline tl) {
  final win = 2 * tl.sampleRate;
  final nWin = (tl.totalSamples + win - 1) ~/ win;
  final sum = Float64List(nWin), sum2 = Float64List(nWin), cnt = Int32List(nWin);
  final step = (1e9 / max(1, acc.fs)).round();
  var segIdx = 0;
  for (final fr in acc.frames) {
    final n = fr.samples.length ~/ 3;
    for (var i = 0; i < n; i++) {
      final t = fr.timestampNs - (n - 1 - i) * step;
      // Odpowiadająca próbka EKG (ten sam zegar opaski).
      while (segIdx + 1 < tl.segments.length && t >= tl.segments[segIdx + 1].t0Ns) {
        segIdx++;
      }
      final s = tl.segments[segIdx];
      final k = ((t - s.t0Ns) * tl.sampleRate / 1e9).round();
      if (k < 0 || k >= s.length) continue;
      final w = (s.start + k) ~/ win;
      final x = fr.samples[3 * i].toDouble(), y = fr.samples[3 * i + 1].toDouble(), z = fr.samples[3 * i + 2].toDouble();
      final m = sqrt(x * x + y * y + z * z);
      sum[w] += m;
      sum2[w] += m * m;
      cnt[w]++;
    }
  }
  final out = Float32List(nWin);
  for (var w = 0; w < nWin; w++) {
    if (cnt[w] < 10) {
      out[w] = -1;
      continue;
    }
    final mean = sum[w] / cnt[w];
    out[w] = sqrt(max(0.0, sum2[w] / cnt[w] - mean * mean));
  }
  return out;
}

class _FloatBuilder {
  static const _chunk = 1 << 16;
  final List<Float32List> _chunks = [];
  int _len = 0;

  void add(double v) {
    final c = _len ~/ _chunk;
    if (c == _chunks.length) _chunks.add(Float32List(_chunk));
    _chunks[c][_len % _chunk] = v;
    _len++;
  }

  Float32List build() {
    final out = Float32List(_len);
    for (var c = 0; c < _chunks.length; c++) {
      final from = c * _chunk;
      final n = (_len - from).clamp(0, _chunk);
      out.setRange(from, from + n, _chunks[c]);
    }
    return out;
  }
}

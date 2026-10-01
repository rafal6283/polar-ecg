// Wczytywanie MIT-BIH Arrhythmia Database (format 212, adnotacje .atr) z przepróbkowaniem do 130 Hz.

import 'dart:io';
import 'dart:typed_data';

import 'package:polar_ecg/analysis/ecg_recording.dart';
import 'package:polar_ecg/analysis/filters.dart';

const targetFs = 130;

/// Klasy AAMI dla kodów adnotacji MIT.
const aami = {
  1: 'N', 2: 'N', 3: 'N', 11: 'N', 34: 'N', // N L R j e
  4: 'S', 7: 'S', 8: 'S', 9: 'S', // a J A S
  5: 'V', 10: 'V', // V E
  6: 'F', // F
  12: 'Q', 13: 'Q', 38: 'Q', // / Q f
};

/// Rekordy ze stymulatorem – wykluczane wg AAMI.
const paced = {'102', '104', '107', '217'};

/// Podział de Chazal i wsp. (2004): DS1 do uczenia/strojenia, DS2 do oceny.
const ds1 = ['101', '106', '108', '109', '112', '114', '115', '116', '118', '119', '122', '124', '201', '203', '205',
  '207', '208', '209', '215', '220', '223', '230'];
const ds2 = ['100', '103', '105', '111', '113', '117', '121', '123', '200', '202', '210', '212', '213', '214', '219',
  '221', '222', '228', '231', '232', '233', '234'];

class RefBeat {
  final int sample; // 130 Hz
  final String cls; // N S V F Q
  RefBeat(this.sample, this.cls);
}

class MitRecord {
  final String name;
  final Float32List uv; // 130 Hz
  final List<RefBeat> beats;
  final List<List<int>> afRanges; // [od, do) w próbkach 130 Hz

  MitRecord(this.name, this.uv, this.beats, this.afRanges);

  Timeline get timeline => Timeline(DateTime(2000), targetFs, [Segment(0, uv.length, 0)]);
}

MitRecord loadMitRecord(String dir, String rec) {
  final hea = File('$dir/$rec.hea').readAsLinesSync();
  final h0 = hea.first.split(RegExp(r'\s+'));
  final fs0 = double.parse(h0[2].split('/').first);
  final ch = hea[1].split(RegExp(r'\s+'));
  final gain = double.parse(ch[2].split('(').first.split('/').first);
  final baseline = int.parse(ch[4]);
  if (ch[1] != '212') throw UnsupportedError('format ${ch[1]}');

  // Format 212, 2 sygnały: ramka = 3 bajty, bierzemy sygnał 1 (zwykle MLII).
  final bytes = File('$dir/$rec.dat').readAsBytesSync();
  final nFrames = bytes.length ~/ 3;
  final x = Float64List(nFrames);
  for (var f = 0; f < nFrames; f++) {
    final o = f * 3;
    var v = bytes[o] | ((bytes[o + 1] & 0x0F) << 8);
    if (v & 0x800 != 0) v -= 0x1000;
    x[f] = (v - baseline) / gain * 1000; // µV
  }

  // Antyaliasing i przepróbkowanie do 130 Hz (interpolacja liniowa).
  filtfilt(x, [Biquad.lowpass(50, fs0), Biquad.lowpass(50, fs0)]);
  final n = (nFrames * targetFs / fs0).floor();
  final y = Float32List(n);
  for (var i = 0; i < n; i++) {
    final t = i * fs0 / targetFs;
    final k = t.floor();
    final fr = t - k;
    y[i] = k + 1 < nFrames ? x[k] * (1 - fr) + x[k + 1] * fr : x[k];
  }

  final beats = <RefBeat>[];
  final af = <List<int>>[];
  int? afStart;
  for (final a in _readAtr('$dir/$rec.atr')) {
    final s = (a.sample * targetFs / fs0).round();
    if (a.code == 28) {
      if (a.aux.startsWith('(AFIB')) {
        afStart ??= s;
      } else if (afStart != null) {
        af.add([afStart, s]);
        afStart = null;
      }
      continue;
    }
    final cls = aami[a.code];
    if (cls != null) beats.add(RefBeat(s, cls));
  }
  if (afStart != null) af.add([afStart, n]);
  return MitRecord(rec, y, beats, af);
}

/// Dopasowanie wykrytych R do referencyjnych (tolerancja 150 ms, EC57): indeks wykrytego lub -1.
List<int> matchBeats(Int32List peaks, List<RefBeat> ref) {
  final tol = (0.15 * targetFs).round();
  final used = Uint8List(peaks.length);
  final out = <int>[];
  var k0 = 0;
  for (final b in ref) {
    while (k0 < peaks.length && peaks[k0] < b.sample - tol) {
      k0++;
    }
    int? hit;
    for (var k = k0; k < peaks.length && peaks[k] <= b.sample + tol; k++) {
      if (used[k] == 0 && (hit == null || (peaks[k] - b.sample).abs() < (peaks[hit] - b.sample).abs())) hit = k;
    }
    if (hit != null) used[hit] = 1;
    out.add(hit ?? -1);
  }
  return out;
}

class _Ann {
  final int sample;
  final int code;
  final String aux;
  _Ann(this.sample, this.code, this.aux);
}

/// Adnotacje MIT: 16-bitowe słowa (6 bitów kod, 10 bitów odstęp) + kody specjalne.
List<_Ann> _readAtr(String path) {
  final b = File(path).readAsBytesSync();
  final out = <_Ann>[];
  var t = 0, i = 0;
  while (i + 1 < b.length) {
    final w = b[i] | (b[i + 1] << 8);
    i += 2;
    final code = w >> 10, val = w & 0x3FF;
    if (code == 0 && val == 0) break;
    if (code == 59) {
      final hi = b[i] | (b[i + 1] << 8), lo = b[i + 2] | (b[i + 3] << 8);
      var d = (hi << 16) | lo;
      if (d & 0x80000000 != 0) d -= 0x100000000;
      t += d;
      i += 4;
    } else if (code == 63) {
      final s = String.fromCharCodes(b.sublist(i, i + val)).replaceAll('\x00', '');
      i += val + (val & 1);
      if (out.isNotEmpty) out[out.length - 1] = _Ann(out.last.sample, out.last.code, s);
    } else if (code == 60 || code == 61 || code == 62) {
      // NUM/SUB/CHN – pomijamy
    } else {
      t += val;
      out.add(_Ann(t, code, ''));
    }
  }
  return out;
}

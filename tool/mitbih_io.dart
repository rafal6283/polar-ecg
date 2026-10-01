// Wczytywanie baz MIT-BIH (mitdb 360 Hz, svdb 128 Hz; format 212, adnotacje .atr) z przepróbkowaniem do 130 Hz.

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

  /// Epizody rytmów z adnotacji (np. 'AFIB', 'AFL', 'SVTA', 'BII', 'N'): [od, do) w próbkach 130 Hz.
  final Map<String, List<List<int>>> rhythms;

  /// Epizody ST z adnotacji edb (aux '(ST…' … 'ST…)'): [od, szczyt, do) i opis.
  final List<({int start, int end, String desc})> stEpisodes;

  MitRecord(this.name, this.uv, this.beats, this.rhythms, [this.stEpisodes = const []]);

  List<List<int>> get afRanges => rhythms['AFIB'] ?? const [];

  Timeline get timeline => Timeline(DateTime(2000), targetFs, [Segment(0, uv.length, 0)]);
}

/// Odprowadzenie: [lead] = nazwa sygnału z nagłówka (np. 'II', 'V5', 'MLII'); domyślnie pierwszy sygnał.
/// [ann] = rozszerzenie adnotacji ('atr'; dla afdb rytm w 'atr', pobudzenia bez klas w 'qrs').
MitRecord loadMitRecord(String dir, String rec, {String? lead, int? channel, String ann = 'atr'}) {
  final hea = File('$dir/$rec.hea').readAsLinesSync().where((l) => l.trim().isNotEmpty && !l.startsWith('#')).toList();
  final h0 = hea.first.trim().split(RegExp(r'\s+'));
  final nSig = int.parse(h0[1]);
  final fs0 = double.parse(h0[2].split('/').first);
  final sigs = [for (var k = 0; k < nSig; k++) hea[1 + k].trim().split(RegExp(r'\s+'))];
  var c = channel ?? 0;
  if (lead != null) {
    c = sigs.indexWhere((x) => x.length > 8 && x.sublist(8).join(' ') == lead);
    if (c < 0) throw ArgumentError('brak odprowadzenia $lead w $rec');
  }
  final ch = sigs[c];
  final fmt = ch[1];
  final g0 = double.parse(ch[2].split('(').first.split('/').first);
  final gain = g0 > 0 ? g0 : 200.0; // WFDB: wzmocnienie 0 = domyślne 200 jedn./mV (np. część svdb)
  final baseline = ch[2].contains('(') ? int.parse(ch[2].split('(')[1].split(')').first) : int.parse(ch[4]);

  final bytes = File('$dir/${ch[0]}').readAsBytesSync();
  late final Float64List x;
  if (fmt == '212') {
    // 2 sygnały w ramce 3-bajtowej.
    if (nSig != 2) throw UnsupportedError('format 212 z $nSig sygnałami');
    final nFrames = bytes.length ~/ 3;
    x = Float64List(nFrames);
    for (var f = 0; f < nFrames; f++) {
      final o = f * 3;
      var v = c == 0 ? bytes[o] | ((bytes[o + 1] & 0x0F) << 8) : bytes[o + 2] | ((bytes[o + 1] & 0xF0) << 4);
      if (v & 0x800 != 0) v -= 0x1000;
      x[f] = (v - baseline) / gain * 1000; // µV
    }
  } else if (fmt == '16') {
    final bd = ByteData.sublistView(bytes);
    final nFrames = bytes.length ~/ (2 * nSig);
    x = Float64List(nFrames);
    for (var f = 0; f < nFrames; f++) {
      x[f] = (bd.getInt16((f * nSig + c) * 2, Endian.little) - baseline) / gain * 1000;
    }
  } else {
    throw UnsupportedError('format $fmt');
  }
  final nFrames = x.length;

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
  final rhythms = <String, List<List<int>>>{};
  final st = <({int start, int end, String desc})>[];
  String? cur;
  int? curStart, stStart;
  for (final a in _readAtr('$dir/$rec.$ann')) {
    final s = (a.sample * targetFs / fs0).round();
    if (a.code == 28 && a.aux.startsWith('(')) {
      if (cur != null) rhythms.putIfAbsent(cur, () => []).add([curStart!, s]);
      cur = a.aux.substring(1).trim();
      curStart = s;
      continue;
    }
    if (a.code == 18 || a.code == 28 || a.code == 32 || a.code == 33) {
      // STCH (18): epizody ST w edb, aux '(ST<kanał><+/->' … 'ST<kanał><+/->)' – tylko wybrany kanał.
      if (a.aux.startsWith('(ST$c')) stStart = s;
      if (a.aux.startsWith('ST$c') && a.aux.endsWith(')') && stStart != null) {
        st.add((start: stStart, end: s, desc: a.aux));
        stStart = null;
      }
      continue;
    }
    final cls = aami[a.code];
    if (cls != null) beats.add(RefBeat(s, cls));
  }
  if (cur != null) rhythms.putIfAbsent(cur, () => []).add([curStart!, n]);
  return MitRecord(rec, y, beats, rhythms, st);
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

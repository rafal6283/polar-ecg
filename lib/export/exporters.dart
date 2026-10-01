import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../analysis/analysis_result.dart';
import '../analysis/ecg_recording.dart';
import '../recording/markers.dart';

/// Eksport EDF+ (European Data Format): surowe EKG [µV] + kanał adnotacji
/// (zdarzenia, objawy, pobudzenia S/V). Przy przerwach w transmisji – EDF+D
/// (rekordy z własnym czasem rozpoczęcia), inaczej EDF+C.
Future<File> exportEdf({
  required File out,
  required EcgRecording rec,
  required AnalysisResult a,
  List<SymptomMarker> markers = const [],
  String patientName = '',
  String sex = '',
  String device = 'Polar H10',
}) async {
  final tl = rec.timeline;
  final fs = tl.sampleRate;
  final x = rec.uv;

  // Adnotacje: (czas od początku [s], czas trwania [s] lub null, tekst).
  final ann = <(double, double?, String)>[];
  double sec(int sample) => tl.offsetOf(sample).inMicroseconds / 1e6;
  for (final e in a.events) {
    ann.add((sec(e.startSample), max(0.0, sec(e.endSample) - sec(e.startSample)), '${e.type.label} ${e.detail}'.trim()));
  }
  for (final m in markers) {
    if (m.sample >= 0) ann.add((sec(m.sample), null, 'Objaw: ${m.label}'));
  }
  for (var k = 0; k < a.rPeaks.length; k++) {
    final l = a.labels[k];
    if (l == BeatType.ventricular || l == BeatType.supraventricular) ann.add((sec(a.rPeaks[k]), null, BeatType.letters[l]));
  }
  ann.sort((p, q) => p.$1.compareTo(q.$1));

  // Rekordy 1 s w obrębie ciągłych fragmentów.
  final records = <(int, double)>[]; // (indeks pierwszej próbki, początek rekordu [s])
  for (final s in tl.segments) {
    final segStart = sec(s.start);
    for (var j = 0; j * fs < s.length; j++) {
      records.add((s.start + j * fs, segStart + j));
    }
  }
  final continuous = tl.segments.length <= 1;

  // TAL-e na rekord: znacznik czasu + adnotacje zaczynające się w tym rekordzie.
  String num(double v) => v.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  final tals = List.generate(records.length, (r) => StringBuffer('+${num(records[r].$2)}\x14\x14\x00'));
  var ri = 0;
  for (final (t, d, text) in ann) {
    while (ri + 1 < records.length && records[ri + 1].$2 <= t) {
      ri++;
    }
    final clean = text.replaceAll(RegExp(r'[\x00-\x1f]'), ' ');
    tals[ri].write('+${num(t)}${d == null ? '' : '\x15${num(d)}'}\x14$clean\x14\x00');
  }
  final annBytes = [for (final t in tals) utf8.encode(t.toString())];
  final annSamples = max(30, (annBytes.map((b) => b.length).fold(0, max) + 1) ~/ 2 + 1);

  String field(String s, int n) {
    final ascii = s.replaceAll(RegExp(r'[^\x20-\x7e]'), '_');
    return ascii.length >= n ? ascii.substring(0, n) : ascii.padRight(n);
  }

  const months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
  final st = tl.started;
  String two(int v) => v.toString().padLeft(2, '0');
  final sexCode = sex == 'M' ? 'M' : (sex == 'K' ? 'F' : 'X');
  final name = patientName.trim().isEmpty ? 'X' : patientName.trim().replaceAll(' ', '_');
  final header = StringBuffer()
    ..write(field('0', 8))
    ..write(field('X $sexCode X $name', 80))
    ..write(field('Startdate ${two(st.day)}-${months[st.month - 1]}-${st.year} X X ${device.replaceAll(' ', '_')}', 80))
    ..write(field('${two(st.day)}.${two(st.month)}.${two(st.year % 100)}', 8))
    ..write(field('${two(st.hour)}.${two(st.minute)}.${two(st.second)}', 8))
    ..write(field('${256 * 3}', 8))
    ..write(field(continuous ? 'EDF+C' : 'EDF+D', 44))
    ..write(field('${records.length}', 8))
    ..write(field('1', 8))
    ..write(field('2', 4));
  for (final v in ['ECG', 'EDF Annotations']) {
    header.write(field(v, 16));
  }
  for (final v in ['Polar H10 chest strap ECG', '']) {
    header.write(field(v, 80));
  }
  for (final v in ['uV', '']) {
    header.write(field(v, 8));
  }
  for (final v in ['-32768', '-1']) {
    header.write(field(v, 8));
  }
  for (final v in ['32767', '1']) {
    header.write(field(v, 8));
  }
  for (final v in ['-32768', '-32768']) {
    header.write(field(v, 8));
  }
  for (final v in ['32767', '32767']) {
    header.write(field(v, 8));
  }
  for (final v in ['None (raw)', '']) {
    header.write(field(v, 80));
  }
  for (final v in ['$fs', '$annSamples']) {
    header.write(field(v, 8));
  }
  header.write(field('', 32 * 2));

  final sink = out.openWrite()..add(ascii.encode(header.toString()));
  final rec16 = ByteData(fs * 2 + annSamples * 2);
  for (var r = 0; r < records.length; r++) {
    final first = records[r].$1;
    final seg = tl.segments[tl.segmentIndexOf(first)];
    for (var i = 0; i < fs; i++) {
      final idx = min(first + i, seg.end - 1); // ostatni niepełny rekord – dopełnienie ostatnią próbką
      rec16.setInt16(2 * i, x[idx].round().clamp(-32768, 32767), Endian.little);
    }
    final b = annBytes[r];
    for (var i = 0; i < annSamples * 2; i++) {
      rec16.setUint8(fs * 2 + i, i < b.length ? b[i] : 0);
    }
    sink.add(Uint8List.fromList(rec16.buffer.asUint8List()));
  }
  await sink.flush();
  await sink.close();
  return out;
}

/// CSV z EKG: czas od początku [s], napięcie [µV], etykieta pobudzenia w próbce załamka R.
Future<File> exportEcgCsv({required File out, required EcgRecording rec, required AnalysisResult a}) async {
  final tl = rec.timeline;
  final labelAt = <int, String>{
    for (var k = 0; k < a.rPeaks.length; k++) a.rPeaks[k]: BeatType.letters[a.labels[k]],
  };
  final sink = out.openWrite()..writeln('czas_s;uV;R');
  final sb = StringBuffer();
  for (var i = 0; i < rec.uv.length; i++) {
    final t = tl.offsetOf(i).inMicroseconds / 1e6;
    sb
      ..write(t.toStringAsFixed(4).replaceAll('.', ','))
      ..write(';')
      ..write(rec.uv[i].round())
      ..write(';')
      ..writeln(labelAt[i] ?? '');
    if (sb.length > 1 << 16) {
      sink.write(sb);
      sb.clear();
    }
  }
  sink.write(sb);
  await sink.flush();
  await sink.close();
  return out;
}

/// CSV odstępów RR (np. do Kubios HRV): czas [s], RR [ms], typ pobudzenia kończącego odstęp.
Future<File> exportRrCsv({required File out, required AnalysisResult a}) async {
  final tl = a.timeline;
  final fs = a.sampleRate;
  final sb = StringBuffer('czas_s;rr_ms;typ;migotanie\n');
  for (var k = 1; k < a.rPeaks.length; k++) {
    if (tl.segmentIndexOf(a.rPeaks[k]) != tl.segmentIndexOf(a.rPeaks[k - 1])) continue; // przerwa
    final t = tl.offsetOf(a.rPeaks[k]).inMicroseconds / 1e6;
    final rr = (a.rPeaks[k] - a.rPeaks[k - 1]) * 1000 / fs;
    sb.writeln('${t.toStringAsFixed(3).replaceAll('.', ',')};${rr.round()};${BeatType.letters[a.labels[k]]};${a.inAf[k]}');
  }
  await out.writeAsString(sb.toString());
  return out;
}

import 'dart:convert';
import 'dart:io';

import '../analysis/ecg_recording.dart';

/// Objawy do wyboru przy znaczniku.
const symptoms = [
  'Kołatanie serca',
  'Nierówne bicie',
  'Zawroty głowy',
  'Ból / ucisk w klatce',
  'Duszność',
  'Osłabienie',
  'Omdlenie / prawie omdlenie',
  'Inne',
];

class SymptomMarker {
  final DateTime time;
  final int sample; // indeks próbki w zapisie (-1, gdy poza sygnałem)
  final String symptom;
  final String note;

  SymptomMarker(this.time, this.sample, this.symptom, this.note);

  String get label => note.isEmpty ? symptom : '$symptom – $note';
}

/// Wczytuje markers.json i przypisuje znacznikom próbki sygnału
/// (wg zegara opaski, a gdy go brak – wg czasu telefonu).
Future<List<SymptomMarker>> loadMarkers(String path, Timeline tl) async {
  final f = File('$path/markers.json');
  if (!await f.exists()) return [];
  final list = jsonDecode(await f.readAsString()) as List;
  final out = <SymptomMarker>[];
  for (final m in list.cast<Map<String, dynamic>>()) {
    final time = DateTime.fromMillisecondsSinceEpoch(m['phone_ms'] as int);
    var sample = -1;
    final ns = m['sensor_ns'] as int?;
    if (ns != null) {
      for (final s in tl.segments) {
        final k = ((ns - s.t0Ns) * tl.sampleRate / 1e9).round();
        if (k >= 0 && k < s.length + tl.sampleRate) {
          sample = s.start + k.clamp(0, s.length - 1);
          break;
        }
      }
    }
    if (sample < 0) {
      final off = time.difference(tl.started);
      if (!off.isNegative && off <= tl.totalDuration) sample = tl.sampleAt(off);
    }
    out.add(SymptomMarker(time, sample, m['symptom'] as String? ?? 'Objaw', m['note'] as String? ?? ''));
  }
  return out;
}

import 'analysis_result.dart';

/// Rytm wokół chwili [sample] (±[windowSec]) – do zestawienia zgłoszonego objawu z zapisem EKG.
/// [abnormal] – w oknie było zaburzenie rytmu (AF, zdarzenie średniej/wysokiej wagi, pobudzenia dodatkowe).
({String text, bool abnormal}) rhythmAt(AnalysisResult a, int sample, {int windowSec = 30}) {
  final fs = a.sampleRate;
  final from = sample - windowSec * fs, to = sample + windowSec * fs;
  String clock(int s) {
    final t = a.timeline.timeOf(s);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  }

  final parts = <String>[];
  var abnormal = false;
  for (final e in a.events) {
    if (e.endSample < from || e.startSample > to) continue;
    if (e.type == EventType.af) {
      parts.add('migotanie przedsionków (napad ${clock(e.startSample)}–${clock(e.endSample)}, ${e.detail})');
      abnormal = true;
    } else if (e.severity != Severity.low) {
      parts.add('${e.type.label.toLowerCase()}${e.detail.isEmpty ? '' : ' (${e.detail})'}');
      abnormal = true;
    }
  }

  var total = 0, readable = 0, v = 0, s = 0, rrN = 0;
  var rrSum = 0.0;
  for (var k = a.beatIndexAtOrAfter(from); k < a.rPeaks.length && a.rPeaks[k] <= to; k++) {
    total++;
    final l = a.labels[k];
    if (l == BeatType.unknown) continue;
    readable++;
    if (l == BeatType.ventricular) v++;
    if (l == BeatType.supraventricular) s++;
    if (k > 0 && a.labels[k - 1] != BeatType.unknown) {
      final rr = (a.rPeaks[k] - a.rPeaks[k - 1]) / fs;
      if (rr > 0.25 && rr < 2.5) {
        rrSum += rr;
        rrN++;
      }
    }
  }
  if (total == 0 || readable < 0.5 * total || rrN < 5) {
    if (parts.isEmpty) return (text: 'sygnał nieczytelny – rytmu nie da się ocenić', abnormal: false);
    return (text: parts.join('; '), abnormal: abnormal);
  }
  final hr = (60 * rrN / rrSum).round();
  final ectopy = [if (v > 0) 'pobudzenia V: $v', if (s > 0) 'S: $s'];
  if (ectopy.isNotEmpty) abnormal = true;
  final afHere = parts.any((p) => p.startsWith('migotanie'));
  if (!afHere) {
    parts.insert(
        0,
        ectopy.isEmpty && parts.isEmpty
            ? 'rytm bez zaburzeń, $hr/min'
            : 'tętno $hr/min${ectopy.isEmpty ? '' : ', ${ectopy.join(', ')}'}');
  }
  return (text: parts.join('; '), abnormal: abnormal);
}

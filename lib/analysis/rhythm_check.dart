import 'analysis_result.dart';

enum CheckVerdict { unreadable, af, ectopy, tachy, brady, irregular, regular }

/// Wynik szybkiego sprawdzenia rytmu (zapis 1–2 min).
class RhythmVerdict {
  final CheckVerdict verdict;
  final String title, detail;
  final double? hr;
  final int v, s;
  final double readablePct;

  RhythmVerdict(this.verdict, this.title, this.detail, {this.hr, this.v = 0, this.s = 0, this.readablePct = 0});

  /// Wymaga uwagi (kolor ostrzegawczy w interfejsie).
  bool get abnormal => verdict == CheckVerdict.af || verdict == CheckVerdict.ectopy ||
      verdict == CheckVerdict.tachy || verdict == CheckVerdict.brady || verdict == CheckVerdict.irregular;
}

/// Ocena krótkiego zapisu: czytelność, AF, pobudzenia dodatkowe, częstość, niemiarowość.
RhythmVerdict rhythmVerdict(AnalysisResult a) {
  final st = a.stats.values;
  final beats = a.rPeaks.length;
  final unknown = a.count(BeatType.unknown);
  final readable = beats == 0 ? 0.0 : 100 * (beats - unknown) / beats;
  final hr = st['hr_mean']?.toDouble();
  final v = a.count(BeatType.ventricular), s = a.count(BeatType.supraventricular);
  final analyzed = (st['analyzed_s'] ?? 0).toDouble();
  RhythmVerdict out(CheckVerdict c, String t, String d) =>
      RhythmVerdict(c, t, d, hr: hr, v: v, s: s, readablePct: readable);
  final hrText = hr == null ? '' : 'tętno ${hr.round()}/min';

  if (beats < 15 || readable < 60 || analyzed < 20 || hr == null) {
    return out(CheckVerdict.unreadable, 'Sygnał nieczytelny',
        'Za dużo zakłóceń, by ocenić rytm. Zwilż elektrody, zapnij pasek ciaśniej, usiądź spokojnie i powtórz.');
  }
  final af = a.events.where((e) => e.type == EventType.af).toList();
  if (af.isNotEmpty) {
    final afSec = af.fold<double>(0, (x, e) => x + (e.endSample - e.startSample) / a.sampleRate);
    return out(CheckVerdict.af, 'Podejrzenie migotania przedsionków',
        'Rytm niemiarowy przez ${afSec.round()} s z ${analyzed.round()} s zapisu, $hrText. '
            'Jeśli masz objawy lub to nowy napad – skontaktuj się z lekarzem zgodnie z jego zaleceniami.');
  }
  final ectopic = v + s;
  final runs = a.events.where((e) => e.severity != Severity.low && e.type != EventType.af).map((e) => e.type.label);
  if (ectopic >= 3 || runs.isNotEmpty) {
    return out(CheckVerdict.ectopy, 'Rytm z pobudzeniami dodatkowymi',
        '$hrText; pobudzenia komorowe: $v, nadkomorowe: $s${runs.isEmpty ? '' : '; ${runs.toSet().join(', ')}'}.');
  }
  final extra = ectopic > 0 ? ', pojedyncze pobudzenia dodatkowe: $ectopic' : ', bez pobudzeń dodatkowych';
  if (hr > 100) {
    return out(CheckVerdict.tachy, 'Szybki rytm miarowy',
        '$hrText$extra. Po wysiłku lub emocjach to zwykle rytm zatokowy – powtórz po kilku minutach odpoczynku.');
  }
  if (hr < 50) return out(CheckVerdict.brady, 'Wolny rytm', '$hrText$extra.');
  final pnn200 = st['pnn200_pct']?.toDouble();
  if (pnn200 != null && pnn200 > 30) {
    return out(CheckVerdict.irregular, 'Rytm niemiarowy, bez cech migotania',
        '$hrText$extra. Niemiarowość nie spełnia kryteriów AF (np. oddechowa); przy objawach powtórz pomiar.');
  }
  return out(CheckVerdict.regular, 'Rytm miarowy', '$hrText$extra.');
}

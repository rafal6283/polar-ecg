import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/live_analyzer.dart';

import 'synthetic_ecg.dart';

void main() {
  test('analiza na żywo liczy pobudzenia przy podawaniu ramkami jak z H10', () {
    final s = SyntheticEcg(seed: 7)
      ..sinus(40)
      ..withPvcs(200, every: 10)
      ..pause(2.6)
      ..sinus(40);
    final x = s.render();
    final live = LiveAnalyzer(SyntheticEcg.fs);
    const frame = 73;
    var sinceProcess = 0;
    for (var i = 0; i < x.length; i += frame) {
      final end = i + frame < x.length ? i + frame : x.length;
      live.addSamples([for (var k = i; k < end; k++) x[k].round()]);
      sinceProcess += end - i;
      if (sinceProcess >= 5 * SyntheticEcg.fs) {
        live.process();
        sinceProcess = 0;
      }
    }
    live.process();

    final truthV = s.beatTypes.where((t) => t == 'V').length;
    // ignore: avoid_print
    print('beats=${live.beats}/${s.beatTimes.length} V=${live.ve}/$truthV S=${live.sv} Q=${live.unknown} '
        'hr=${live.hrMean?.round()} events=${live.events.map((e) => e.label).toList()}');
    // Ostatnie ~2 s nie są jeszcze policzone (margines na niepełne okno).
    expect(live.beats, closeTo(s.beatTimes.length, 4));
    expect(live.ve, closeTo(truthV, 2));
    expect(live.sv, lessThan(3));
    expect(live.events.where((e) => e.label.startsWith('Pauza')).length, 1);
  });
}

// Odtworzenie zapisu przez analizę na żywo (jak w aplikacji: EKG co 1 s, odstępy RR opaski, przeliczenie co 5 s)
// – sprawdzenie alarmów AF bez telefonu, z RR opaski i bez nich.
// dart run tool/live_replay.dart <katalog_zapisu> <sekundy>
// ignore_for_file: avoid_print, curly_braces_in_flow_control_structures

import 'dart:io';

import 'package:polar_ecg/analysis/live_analyzer.dart';
import 'package:polar_ecg/analysis/ecg_recording.dart';

Future<void> main(List<String> a) async {
  final rec = await EcgRecording.load(Directory(a[0]));
  final secs = int.parse(a[1]);
  final dev = rec.deviceRr ?? [];
  for (final useRr in [false, true]) {
    final live = LiveAnalyzer(130);
    var di = 0;
    final hits = <int>[];
    for (var s = 0; s < secs; s++) {
      final from = s * 130, to = (s + 1) * 130;
      live.addSamples([for (var i = from; i < to && i < rec.uv.length; i++) rec.uv[i].round()]);
      if (useRr) {
        final batch = <double>[];
        while (di < dev.length && dev[di].$1 < to) {
          batch.add(dev[di].$2);
          di++;
        }
        if (batch.isNotEmpty) live.addDeviceRr(batch);
      }
      if (s % 5 == 4) {
        live.process();
        if (live.afNow) hits.add(s);
      }
    }
    print(
      '${useRr ? 'z RR opaski' : 'tylko EKG  '}: AF na żywo w sekundach: $hits; zdarzenia: ${live.events.map((e) => e.label).toList()}',
    );
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../analysis/analysis_result.dart';
import '../analysis/analyzer.dart';
import '../analysis/ecg_recording.dart';
import '../recording/recorder.dart';

/// Eksport epizodów migotania przedsionków do Kreski (wspólny format „wymiana-zdarzen” v1).
///
/// {
///   "format": "wymiana-zdarzen", "version": 1, "source": "polar-ekg", "exported_at": ms,
///   "windows": [{"start": ms, "end": ms}],            // kiedy EKG faktycznie było zapisywane
///   "events":  [{"id": "...", "type": "af", "start": ms, "end": ms}]
/// }
/// Czasy w milisekundach od epoki (UTC). Plik zawiera całą historię – import w Kresce
/// zastępuje poprzednie dane z tego źródła, więc można eksportować wielokrotnie.
class ExchangeExport {
  final File file;
  final int recordings; // zapisy uwzględnione (przeanalizowane)
  final int skipped; // zapisy bez aktualnej analizy
  final int episodes;
  final Duration afTotal;

  ExchangeExport(this.file, this.recordings, this.skipped, this.episodes, this.afTotal);
}

Future<ExchangeExport> exportAfExchange() async {
  final root = await Recorder.recordingsRoot();
  final dirs = root.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
  final windows = <Map<String, int>>[];
  final events = <Map<String, Object>>[];
  var used = 0, skipped = 0;
  var afMs = 0;

  for (final d in dirs) {
    final f = File('${d.path}/$analysisFile');
    if (!f.existsSync()) {
      skipped++;
      continue;
    }
    Map<String, dynamic> j;
    try {
      j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      skipped++;
      continue;
    }
    if (j['version'] != AnalysisResult.version) {
      skipped++;
      continue;
    }
    final tl = Timeline(
      DateTime.parse(j['started'] as String),
      j['sample_rate'] as int,
      [for (final s in j['segments'] as List) Segment.fromJson(s as List)],
    );
    if (tl.segments.isEmpty) continue;
    used++;
    int ms(num sample) => tl.timeOf(sample).millisecondsSinceEpoch;

    for (final s in tl.segments) {
      windows.add({'start': ms(s.start), 'end': ms(s.end)});
    }
    final name = d.uri.pathSegments.where((p) => p.isNotEmpty).last;
    var k = 0;
    for (final e in j['events'] as List) {
      final ev = EcgEvent.fromJson(e as Map<String, dynamic>);
      if (ev.type != EventType.af) continue;
      final start = ms(ev.startSample), end = ms(ev.endSample);
      events.add({'id': '$name-af${k++}', 'type': 'af', 'start': start, 'end': end});
      afMs += end - start;
    }
  }

  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final out = File('${(await getTemporaryDirectory()).path}/polar-ekg-af-${now.year}-${two(now.month)}-${two(now.day)}.json');
  await out.writeAsString(jsonEncode({
    'format': 'wymiana-zdarzen',
    'version': 1,
    'source': 'polar-ekg',
    'exported_at': now.millisecondsSinceEpoch,
    'windows': windows,
    'events': events,
  }));
  return ExchangeExport(out, used, skipped, events.length, Duration(milliseconds: afMs));
}

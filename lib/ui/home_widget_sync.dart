import 'dart:convert';
import 'dart:io';

import 'package:home_widget/home_widget.dart';

import '../analysis/af_episodes.dart';
import '../analysis/hrv_session.dart';
import '../recording/recorder.dart';
import 'viewer/format.dart';

/// Widżet na ekranie głównym (Android): ostatnie poranne HRV z oceną i ostatni napad AF.
Future<void> updateHomeWidget() async {
  if (!Platform.isAndroid) return;
  try {
    final root = await Recorder.recordingsRoot();
    final hist = await HrvHistory.load(root.parent);
    final rel = [for (final h in hist) if (h.reliable) h]..sort((a, b) => a.time.compareTo(b.time));
    if (rel.isNotEmpty) {
      final last = rel.last;
      final st = hrvBaseline(rel, last).status;
      final ago = DateTime.now().difference(last.time).inDays;
      await HomeWidget.saveWidgetData<String>('w_hrv', '${last.rmssd.round()} ms · tętno ${last.hr.round()}');
      await HomeWidget.saveWidgetData<String>('w_hrv_status', '${st.label}${ago == 0 ? ' · dziś' : ago == 1 ? ' · wczoraj' : ' · $ago dni temu'}');
      await HomeWidget.saveWidgetData<String>('w_hrv_level', st.name);
    }
    AfEpisode? lastAf;
    for (final d in root.listSync().whereType<Directory>()) {
      final f = File('${d.path}/summary.json');
      if (!f.existsSync()) continue;
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        for (final e in (j['af_episodes'] as List? ?? const [])) {
          final ep = AfEpisode.fromJson(e as Map<String, dynamic>);
          if (lastAf == null || ep.start.isAfter(lastAf.start)) lastAf = ep;
        }
      } catch (_) {}
    }
    final af = lastAf;
    await HomeWidget.saveWidgetData<String>(
        'w_af',
        af == null
            ? 'Brak napadów AF w zapisach'
            : 'Ostatni napad AF: ${fmtDate(af.start)} ${fmtClock(af.start).substring(0, 5)} · ${(af.duration.inSeconds / 60).ceil()} min');
    await HomeWidget.updateWidget(androidName: 'PolarWidget');
  } catch (_) {}
}

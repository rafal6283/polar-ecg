import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:quick_actions/quick_actions.dart';

/// Szybkie akcje: skróty przy ikonie aplikacji (przytrzymanie – Android i iOS) oraz kafelek
/// szybkich ustawień Androida („Sprawdź rytm”, kanał `polar_ekg/launch` w MainActivity).
class LaunchActions {
  static const check = 'check', hrv = 'hrv';
  static const _channel = MethodChannel('polar_ekg/launch');

  /// [onAction] – wywoływane z nazwą akcji ([check], [hrv]) po uruchomieniu ze skrótu lub kafelka.
  static Future<void> init(void Function(String action) onAction) async {
    try {
      const qa = QuickActions();
      await qa.initialize(onAction);
      await qa.setShortcutItems(const [
        ShortcutItem(type: check, localizedTitle: 'Sprawdź rytm', icon: 'ic_tile_rhythm'),
        ShortcutItem(type: hrv, localizedTitle: 'Pomiar HRV'),
      ]);
    } catch (e) {
      debugPrint('Skróty niedostępne: $e');
    }
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action' && call.arguments is String) onAction(call.arguments as String);
    });
    try {
      final a = await _channel.invokeMethod<String>('takeAction');
      if (a != null) onAction(a);
    } catch (_) {}
  }
}

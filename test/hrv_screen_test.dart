import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/hrv_session.dart';
import 'package:polar_ecg/app_controller.dart';
import 'package:polar_ecg/ble/polar_h10.dart';
import 'package:polar_ecg/settings/app_settings.dart';
import 'package:polar_ecg/ui/hrv_screen.dart';
import 'package:polar_ecg/ui/theme/app_theme.dart';

void main() {
  testWidgets('pomiar HRV: wyciszenie -> pomiar -> wynik zapisany w historii', (tester) async {
    final docs = Directory.systemTemp.createTempSync('hrvdocs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => docs.path);
    final c = AppController(AppSettings.instance)
      ..device = PolarH10(BluetoothDevice.fromId('A0:9E:1A:12:34:56'))
      ..link = LinkState.connected
      ..heartRate = 60;
    await tester.pumpWidget(MaterialApp(theme: buildAppTheme(Brightness.light), home: HrvMeasureScreen(controller: c)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.tap(find.text('Rozpocznij pomiar'));
    await tester.pump();
    expect(find.text('Wyciszenie'), findsOneWidget);
    for (var s = 0; s < 61; s++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Pomiar'), findsOneWidget);
    for (var s = 0; s < 120; s++) {
      c.injectRr([s.isEven ? 980.0 : 1020.0]);
      await tester.pump(const Duration(seconds: 1));
    }
    for (var k = 0; k < 20 && find.text('RMSSD').evaluate().isEmpty; k++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.text('RMSSD'), findsOneWidget);
    expect(find.text('40'), findsWidgets); // RMSSD 40 ms
    final hist = await tester.runAsync(() => HrvHistory.load(docs));
    expect(hist!.length, 1);
    expect(hist.single.rmssd, closeTo(40, 0.5));
    docs.deleteSync(recursive: true);
  });
}

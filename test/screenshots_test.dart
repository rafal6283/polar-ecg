// Zrzuty ekranów do przeglądu wyglądu (bez telefonu): SCREENSHOTS=<katalog> flutter test test/screenshots_test.dart
// Bez zmiennej SCREENSHOTS test jest pomijany. Czcionki: Roboto z assets + ikony Material z SDK Fluttera.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polar_ecg/analysis/analyzer.dart';
import 'package:polar_ecg/analysis/live_analyzer.dart';
import 'dart:convert';

import 'package:polar_ecg/alarms/alarm_service.dart';
import 'package:polar_ecg/app_controller.dart';
import 'package:polar_ecg/recording/binary_format.dart';
import 'package:polar_ecg/ui/legend_screen.dart';
import 'package:polar_ecg/ui/recordings_screen.dart';
import 'package:polar_ecg/ui/settings_screen.dart';
import 'package:polar_ecg/ui/viewer/recording_screen.dart';
import 'package:polar_ecg/ble/polar_h10.dart';
import 'package:polar_ecg/settings/app_settings.dart';
import 'package:polar_ecg/ui/home_screen.dart';
import 'package:polar_ecg/ui/theme/app_theme.dart';

import 'synthetic_ecg.dart';

final _out = Platform.environment['SCREENSHOTS'];

Future<void> _loadFonts() async {
  final roboto = FontLoader('Roboto')
    ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync())))
    ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/Roboto-Bold.ttf').readAsBytesSync())));
  await roboto.load();
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/home/user/sdk/flutter';
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(
        File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
}

Future<void> _shot(WidgetTester tester, String name) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100)); // dokończenie animacji przejść
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 1);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Widget _app(Widget home, Brightness b) => RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        home: home,
      ),
    );

/// Kontroler „połączony” z syntetycznym EKG (pobudzenia V), bez Bluetootha.
AppController _fakeConnected() {
  final c = AppController(AppSettings.instance);
  c.device = PolarH10(BluetoothDevice.fromId('A0:9E:1A:12:34:56'));
  c.link = LinkState.connected;
  c.heartRate = 72;
  c.lastRr = 828;
  c.battery = 84;
  c.skinContact = true;
  final s = SyntheticEcg(seed: 2)
    ..sinus(120)
    ..withPvcs(60);
  final x = s.render();
  final ints = [for (final v in x) v.round()];
  c.ecg.addAll(ints);
  final live = LiveAnalyzer(130);
  for (var i = 0; i < ints.length; i += 650) {
    live.addSamples(ints.sublist(i, i + 650 > ints.length ? ints.length : i + 650));
    live.process();
  }
  c.live = live;
  return c;
}

/// Syntetyczny zapis w formacie aplikacji (sinus, pobudzenia V i S, pauza, zakłócenia) + znacznik objawu.
Future<String> _writeRecording({String? root, String name = '20260115_073000', int seed = 11}) async {
  final dir = Directory('${root ?? Directory.systemTemp.createTempSync('shots').path}/$name')..createSync(recursive: true);
  File('${dir.path}/meta.json').writeAsStringSync(jsonEncode({
    'sample_rate_hz': 130,
    'started': DateTime(2026, 1, 15, 7, 30).toIso8601String(),
    'device': 'Polar H10 A1B2C3D4',
  }));
  final s = SyntheticEcg(seed: seed)
    ..sinus(240)
    ..withPvcs(180)
    ..sinus(60)
    ..pause(3.1)
    ..sinus(120)
    ..noise(15)
    ..sinus(120);
  final x = s.render();
  final ecg = BinaryStreamWriter.create(File('${dir.path}/ecg.bin'), 'PECG', fs: 130, channels: 1);
  const step = 1000000000 ~/ 130;
  for (var i = 0; i < x.length; i += 73) {
    final end = i + 73 < x.length ? i + 73 : x.length;
    ecg.addFrame((end - 1) * step, [for (var k = i; k < end; k++) x[k].round()]);
  }
  await ecg.close();
  File('${dir.path}/markers.json').writeAsStringSync(jsonEncode([
    {'phone_ms': DateTime(2026, 1, 15, 7, 34).millisecondsSinceEpoch, 'symptom': 'Kołatanie serca', 'note': ''},
  ]));
  return dir.path;
}

Future<void> _settle(WidgetTester tester) async {
  for (var k = 0; k < 100; k++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  final skip = _out == null;

  setUpAll(() async {
    if (!skip) await _loadFonts();
  });

  for (final b in Brightness.values) {
    final suffix = b == Brightness.dark ? '_dark' : '';
    testWidgets('monitor – wyszukiwanie$suffix', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(_app(MonitorPage(controller: AppController(AppSettings.instance)), b));
      await _shot(tester, '01_monitor_skan$suffix');
    }, skip: skip);

    testWidgets('monitor – na żywo$suffix', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(_app(MonitorPage(controller: _fakeConnected()), b));
      await tester.pump(const Duration(seconds: 2));
      await _shot(tester, '02_monitor_live$suffix');
      await tester.drag(find.byType(ListView).first, const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 500));
      await _shot(tester, '03_monitor_live_dol$suffix');
    }, skip: skip);

    testWidgets('zapis – przebieg, zdarzenia, raport, grupy$suffix', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      final path = (await tester.runAsync(_writeRecording))!;
      await tester.pumpWidget(_app(RecordingScreen(path: path, title: '15.01.2026, 07:30'), b));
      await _settle(tester);
      await _shot(tester, '10_zapis_przebieg$suffix');
      await tester.tap(find.textContaining('Zdarzenia'));
      await tester.pump(const Duration(seconds: 1));
      await _shot(tester, '11_zapis_zdarzenia$suffix');
      await tester.tap(find.text('Raport'));
      await tester.pump(const Duration(seconds: 1));
      await _shot(tester, '12_zapis_raport$suffix');
      await tester.drag(find.byType(ListView).last, const Offset(0, -700));
      await tester.pump(const Duration(seconds: 1));
      await _shot(tester, '13_zapis_raport_dol$suffix');
      await tester.tap(find.byTooltip('Grupy morfologii'));
      await tester.pump(const Duration(milliseconds: 600));
      await _settle(tester);
      await _shot(tester, '14_grupy$suffix');
    }, skip: skip);

    testWidgets('ustawienia i legenda$suffix', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      final settings = AppSettings.instance;
      await tester.pumpWidget(_app(SettingsScreen(settings: settings, alarms: AlarmService(settings)), b));
      await tester.pump(const Duration(milliseconds: 300));
      await _shot(tester, '20_ustawienia$suffix');
      await tester.pumpWidget(_app(const LegendScreen(), b));
      await tester.pump(const Duration(milliseconds: 300));
      await _shot(tester, '21_legenda$suffix');
    }, skip: skip);

    testWidgets('lista zapisów$suffix', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      final docs = Directory.systemTemp.createTempSync('docs');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), (call) async => docs.path);
      await tester.runAsync(() async {
        final root = '${docs.path}/recordings';
        final a = await _writeRecording(root: root, name: '20260115_073000');
        await _writeRecording(root: root, name: '20260114_221500', seed: 5);
        await analyzeRecordingDir(a); // zapisuje analysis.json
      });
      await tester.pumpWidget(_app(const RecordingsScreen(), b));
      await _settle(tester);
      await _shot(tester, '22_zapisy$suffix');
    }, skip: skip);
  }
}

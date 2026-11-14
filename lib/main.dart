import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:koofr_backup_ui/koofr_backup_ui.dart' show KoofrBackground, KoofrBackup;

import 'app_controller.dart';
import 'recording/koofr_backup.dart';
import 'health/health_connect.dart';
import 'ui/home_widget_sync.dart';
import 'settings/app_settings.dart';
import 'ui/home_screen.dart';
import 'ui/hrv_screen.dart';
import 'ui/launch_actions.dart';
import 'ui/rhythm_check_screen.dart';
import 'ui/theme/app_theme.dart';

/// Kopia i wysyłka epizodów AF na Koofr w tle (Android). Zapis w toku (pliki zmienione w ostatnich
/// 3 minutach) wstrzymuje pracę w tle — wtedy kopia poczeka do zakończenia nagrywania.
@pragma('vm:entry-point')
void koofrCallback() => KoofrBackground.dispatch(() async {
      await AppSettings.instance.load();
      final recording = await PolarBackup.recentlyWritten(const Duration(minutes: 3));
      return PolarBackup(() => recording);
    });

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  AppController.initForegroundTask();
  final settings = AppSettings.instance;
  await settings.load();
  final controller = AppController(settings);
  // kopia na Koofr w tle (pomija zapis w toku)
  KoofrBackup.setup(PolarBackup(() => controller.recorder?.dir))
      .then((_) => KoofrBackground.start(koofrCallback))
      .ignore();
  // tętno i HRV z nowych zapisów do Health Connect (gdy włączone)
  Future<void>.delayed(const Duration(seconds: 20), HealthConnect.pushPending).ignore();
  Future<void>.delayed(const Duration(seconds: 5), updateHomeWidget).ignore();
  runApp(PolarEcgApp(controller: controller));
}

class PolarEcgApp extends StatefulWidget {
  final AppController controller;

  const PolarEcgApp({super.key, required this.controller});

  @override
  State<PolarEcgApp> createState() => _PolarEcgAppState();
}

class _PolarEcgAppState extends State<PolarEcgApp> {
  final _navigator = GlobalKey<NavigatorState>();

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    LaunchActions.init(_onAction);
  }

  /// Skrót / kafelek: otwiera ekran od razu (po zbudowaniu nawigatora).
  void _onAction(String action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = _navigator.currentState;
      if (nav == null) return;
      nav.popUntil((r) => r.isFirst);
      nav.push(MaterialPageRoute(
        builder: (_) => action == LaunchActions.hrv
            ? HrvMeasureScreen(controller: controller)
            : RhythmCheckScreen(controller: controller),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        navigatorKey: _navigator,
        title: 'Polar EKG',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        home: HomeScreen(controller: controller),
      ),
    );
  }
}

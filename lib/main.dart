import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_controller.dart';
import 'settings/app_settings.dart';
import 'ui/home_screen.dart';
import 'ui/hrv_screen.dart';
import 'ui/launch_actions.dart';
import 'ui/rhythm_check_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  AppController.initForegroundTask();
  final settings = AppSettings.instance;
  await settings.load();
  runApp(PolarEcgApp(controller: AppController(settings)));
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

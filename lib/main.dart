import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:koofr_backup_ui/koofr_backup_ui.dart' show KoofrBackground, KoofrBackup;

import 'app_controller.dart';
import 'recording/koofr_backup.dart';
import 'settings/app_settings.dart';
import 'ui/home_screen.dart';
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
  runApp(PolarEcgApp(controller: controller));
}

class PolarEcgApp extends StatelessWidget {
  final AppController controller;

  const PolarEcgApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Polar EKG',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        home: HomeScreen(controller: controller),
      ),
    );
  }
}

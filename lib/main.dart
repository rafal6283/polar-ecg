import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_controller.dart';
import 'settings/app_settings.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  AppController.initForegroundTask();
  final settings = AppSettings.instance;
  await settings.load();
  runApp(PolarEcgApp(controller: AppController(settings)));
}

class PolarEcgApp extends StatelessWidget {
  final AppController controller;

  const PolarEcgApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFC62828);
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Polar EKG',
        theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
        home: HomeScreen(controller: controller),
      ),
    );
  }
}

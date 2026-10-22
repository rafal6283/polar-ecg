import 'package:flutter/services.dart';

/// Roboto z assets (polskie znaki w PDF); null => czcionki systemowe.
Future<(Uint8List, Uint8List)?> loadReportFonts() async {
  try {
    final r = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
    final b = await rootBundle.load('assets/fonts/Roboto-Bold.ttf');
    return (r.buffer.asUint8List(r.offsetInBytes, r.lengthInBytes), b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes));
  } catch (_) {
    return null;
  }
}

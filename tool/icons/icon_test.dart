// Generator ikon aplikacji (Android legacy + adaptacyjna + monochromatyczna, iOS, ekran startowy).
// Uruchomienie z katalogu projektu: flutter test tool/icons/icon_test.dart
// Rysunek: białe serce z linią EKG (czerwień) na granatowym tle z gradientem.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const navyTop = Color(0xFF13698C), navyBottom = Color(0xFF083B52), ecgRed = Color(0xFFD7263D);

/// Kształt serca w kwadracie [0,1]×[0,1].
Path heartPath(Rect r) {
  double x(double v) => r.left + v * r.width;
  double y(double v) => r.top + v * r.height;
  return Path()
    ..moveTo(x(0.5), y(0.93))
    ..cubicTo(x(0.18), y(0.70), x(0.0), y(0.50), x(0.0), y(0.30))
    ..cubicTo(x(0.0), y(0.12), x(0.15), y(0.0), x(0.30), y(0.0))
    ..cubicTo(x(0.40), y(0.0), x(0.47), y(0.05), x(0.5), y(0.14))
    ..cubicTo(x(0.53), y(0.05), x(0.60), y(0.0), x(0.70), y(0.0))
    ..cubicTo(x(0.85), y(0.0), x(1.0), y(0.12), x(1.0), y(0.30))
    ..cubicTo(x(1.0), y(0.50), x(0.82), y(0.70), x(0.5), y(0.93))
    ..close();
}

/// Linia EKG (P, QRS, T) przez serce; [r] – prostokąt rysunku.
Path ecgPath(Rect r) {
  final pts = <Offset>[
    const Offset(0.00, 0.52), const Offset(0.20, 0.52), const Offset(0.26, 0.46), const Offset(0.32, 0.52),
    const Offset(0.40, 0.52), const Offset(0.45, 0.60), const Offset(0.52, 0.14), const Offset(0.59, 0.78),
    const Offset(0.64, 0.52), const Offset(0.72, 0.52), const Offset(0.79, 0.42), const Offset(0.86, 0.52),
    const Offset(1.00, 0.52),
  ];
  final p = Path();
  for (final (i, o) in pts.indexed) {
    final q = Offset(r.left + o.dx * r.width, r.top + o.dy * r.height);
    i == 0 ? p.moveTo(q.dx, q.dy) : p.lineTo(q.dx, q.dy);
  }
  return p;
}

/// Rysunek na płótnie [size]. [scale] – udział rysunku w płótnie (adaptacyjna: bezpieczna strefa 66/108).
/// [bg] – tło z gradientem i zaokrągleniem; [mono] – całość jednym kolorem (ikona tematyczna Androida 13+).
void paintIcon(Canvas c, double size, {required double scale, required bool bg, bool mono = false, double radius = 0}) {
  final full = Rect.fromLTWH(0, 0, size, size);
  if (bg) {
    final paint = Paint()
      ..shader = ui.Gradient.linear(full.topLeft, full.bottomRight, [navyTop, navyBottom]);
    c.drawRRect(RRect.fromRectAndRadius(full, Radius.circular(radius * size)), paint);
  }
  final s = size * scale;
  final art = Rect.fromCenter(center: full.center.translate(0, size * 0.015), width: s, height: s * 0.9);
  final heart = heartPath(art);
  // Linia EKG: czerwona w sercu, biała poza nim; w wersji mono wycięta z serca.
  final line = ecgPath(Rect.fromLTWH(full.left + size * (1 - scale * 1.18) / 2, art.top, s * 1.18, art.height));
  final w = s * 0.068; // grubość względem rysunku (ta sama proporcja we wszystkich wariantach)
  if (mono) {
    c.saveLayer(full, Paint());
    c.drawPath(heart, Paint()..color = Colors.white);
    c.drawPath(line, Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 1.1
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round);
    c.restore();
    return;
  }
  c.drawPath(heart, Paint()..color = Colors.white);
  c.save();
  c.clipPath(heart);
  c.drawPath(line, Paint()
    ..color = ecgRed
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round);
  c.restore();
  // Poza sercem linia biała (ciągłość na granatowym tle).
  c.save();
  c.clipPath(Path.combine(PathOperation.difference, Path()..addRect(full), heart));
  c.drawPath(line, Paint()
    ..color = Colors.white
    ..style = PaintingStyle.stroke
    ..strokeWidth = w * 0.8
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round);
  c.restore();
}

Future<void> render(String path, int px, void Function(Canvas c, double size) draw) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  draw(c, px.toDouble());
  final img = await rec.endRecording().toImage(px, px);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  test('generuj ikony', () async {
    const res = 'android/app/src/main/res';
    const dens = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
    for (final e in dens.entries) {
      // Legacy (Android < 8): zaokrąglony kwadrat 48 dp.
      await render('$res/mipmap-${e.key}/ic_launcher.png', (48 * e.value).round(),
          (c, s) => paintIcon(c, s, scale: 0.62, bg: true, radius: 0.22));
      // Adaptacyjna: pierwszy plan 108 dp (rysunek w bezpiecznej strefie ~60 dp), tło – kolor.
      await render('$res/mipmap-${e.key}/ic_launcher_foreground.png', (108 * e.value).round(),
          (c, s) => paintIcon(c, s, scale: 0.40, bg: false));
      await render('$res/mipmap-${e.key}/ic_launcher_monochrome.png', (108 * e.value).round(),
          (c, s) => paintIcon(c, s, scale: 0.40, bg: false, mono: true));
      // Ekran startowy: sam rysunek na tle w kolorze motywu (launch_background.xml).
      await render('$res/drawable-${e.key}/splash_logo.png', (160 * e.value).round(),
          (c, s) => paintIcon(c, s, scale: 0.62, bg: true, radius: 0.22));
    }
    // iOS: pełny kwadrat bez przezroczystości (system sam zaokrągla).
    const ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final iosSizes = {
      'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40, 'Icon-App-20x20@3x.png': 60,
      'Icon-App-29x29@1x.png': 29, 'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
      'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80, 'Icon-App-40x40@3x.png': 120,
      'Icon-App-60x60@2x.png': 120, 'Icon-App-60x60@3x.png': 180, 'Icon-App-76x76@1x.png': 76,
      'Icon-App-76x76@2x.png': 152, 'Icon-App-83.5x83.5@2x.png': 167, 'Icon-App-1024x1024@1x.png': 1024,
    };
    if (Directory(ios).existsSync()) {
      for (final e in iosSizes.entries) {
        await render('$ios/${e.key}', e.value, (c, s) => paintIcon(c, s, scale: 0.62, bg: true));
      }
    }
    // Podgląd do przeglądu (nie trafia do aplikacji).
    await render('build/icon_preview.png', 512, (c, s) => paintIcon(c, s, scale: 0.62, bg: true, radius: 0.22));
    expect(File('$res/mipmap-xxxhdpi/ic_launcher.png').existsSync(), isTrue);
  });
}

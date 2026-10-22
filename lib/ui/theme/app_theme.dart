import 'package:flutter/material.dart';

/// Kolory semantyczne aplikacji (pobudzenia, statusy, papier EKG) – jedno źródło dla wszystkich ekranów.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color ok, warning, danger, info;
  final Color beatN, beatS, beatV, beatQ, af, symptom;
  final Color paper, gridMinor, gridMajor, trace;
  final Color ecgAccent; // czerwień EKG (nagrywanie, logo)

  const AppColors({
    required this.ok,
    required this.warning,
    required this.danger,
    required this.info,
    required this.beatN,
    required this.beatS,
    required this.beatV,
    required this.beatQ,
    required this.af,
    required this.symptom,
    required this.paper,
    required this.gridMinor,
    required this.gridMajor,
    required this.trace,
    required this.ecgAccent,
  });

  static const light = AppColors(
    ok: Color(0xFF2E7D32),
    warning: Color(0xFFE65100),
    danger: Color(0xFFC62828),
    info: Color(0xFF1565C0),
    beatN: Color(0xFF78909C),
    beatS: Color(0xFF1565C0),
    beatV: Color(0xFFC62828),
    beatQ: Color(0xFFB0A000),
    af: Color(0xFF8E24AA),
    symptom: Color(0xFF7B1FA2),
    paper: Color(0xFFFFF8F6),
    gridMinor: Color(0xFFF6D3CC),
    gridMajor: Color(0xFFE8A196),
    trace: Color(0xFF111111),
    ecgAccent: Color(0xFFD7263D),
  );

  static const dark = AppColors(
    ok: Color(0xFF81C784),
    warning: Color(0xFFFFB74D),
    danger: Color(0xFFEF5350),
    info: Color(0xFF64B5F6),
    beatN: Color(0xFF90A4AE),
    beatS: Color(0xFF64B5F6),
    beatV: Color(0xFFEF5350),
    beatQ: Color(0xFFD4C84A),
    af: Color(0xFFCE93D8),
    symptom: Color(0xFFCE93D8),
    paper: Color(0xFF161214),
    gridMinor: Color(0xFF34262A),
    gridMajor: Color(0xFF5A3A40),
    trace: Color(0xFFECECEC),
    ecgAccent: Color(0xFFFF5A6E),
  );

  /// Kolor etykiety pobudzenia (BeatType: 0 N, 1 S, 2 V, 3 Q).
  Color beat(int label) => switch (label) {
        1 => beatS,
        2 => beatV,
        3 => beatQ,
        _ => beatN,
      };

  static AppColors of(BuildContext context) => Theme.of(context).extension<AppColors>() ?? light;

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(covariant AppColors? other, double t) => t < 0.5 || other == null ? this : other;
}

/// Motyw: granat/morski (spokojny, „kliniczny”), czerwień EKG jako akcent, czytelne liczby
/// (cyfry o stałej szerokości – wartości na żywo nie „skaczą”).
ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0B4F6C),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
  ).copyWith(
    primary: dark ? const Color(0xFF7FCCEA) : const Color(0xFF0B4F6C),
    onPrimary: dark ? const Color(0xFF00344A) : Colors.white,
    secondary: dark ? const Color(0xFF7FD6C2) : const Color(0xFF00796B),
    error: dark ? const Color(0xFFFF8A80) : const Color(0xFFC62828),
    surface: dark ? const Color(0xFF0F1417) : const Color(0xFFF7F9FA),
  );
  final colors = dark ? AppColors.dark : AppColors.light;
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  const tabular = [FontFeature.tabularFigures()];
  final text = base.textTheme.copyWith(
    displaySmall: base.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabular),
    headlineMedium: base.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabular),
    titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabular),
    titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabular),
    titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.1),
    labelSmall: base.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.3),
  );
  final cardColor = dark ? const Color(0xFF172025) : Colors.white;
  final border = BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.4 : 0.6));
  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    extensions: [colors],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface, fontSize: 21, fontWeight: FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      color: cardColor,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: border),
      clipBehavior: Clip.antiAlias,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: cardColor,
      indicatorColor: scheme.primaryContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      height: 68,
      labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: text.titleSmall,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: text.titleSmall,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: border,
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      iconColor: scheme.onSurfaceVariant,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5), space: 1),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: cardColor, surfaceTintColor: Colors.transparent),
    tabBarTheme: TabBarThemeData(
      labelStyle: text.titleSmall,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: scheme.outlineVariant.withValues(alpha: 0.5),
    ),
  );
}

/// Nagłówek sekcji (małe wersaliki).
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(children: [
        Expanded(
          child: Text(text.toUpperCase(),
              style: t.labelMedium?.copyWith(
                  letterSpacing: 1.1, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
        ),
        ?trailing,
      ]),
    );
  }
}

/// Plakietka statusu: kolorowa kropka/ikona + tekst na tle w odcieniu koloru.
class StatusPill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const StatusPill({super.key, required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Kafelek wartości: etykieta, liczba z jednostką, opcjonalny opis; kolor wartości przy przekroczeniu.
class MetricTile extends StatelessWidget {
  final String label, value;
  final String? unit, sub;
  final Color? color;
  final IconData? icon;
  const MetricTile(this.label, this.value, {super.key, this.unit, this.sub, this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            if (icon != null) ...[Icon(icon, size: 14, color: color ?? scheme.onSurfaceVariant), const SizedBox(width: 4)],
            Expanded(child: Text(label, style: t.labelSmall, overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 2),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Flexible(
              child: Text(value,
                  style: t.titleLarge?.copyWith(color: color, height: 1.15), overflow: TextOverflow.ellipsis),
            ),
            if (unit != null) ...[const SizedBox(width: 3), Text(unit!, style: t.labelSmall)],
          ]),
          if (sub != null) Text(sub!, style: t.labelSmall?.copyWith(fontSize: 10.5), overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

/// Siatka kafelków: 2 kolumny na telefonie, więcej na szerszym ekranie.
class MetricGrid extends StatelessWidget {
  final List<Widget> children;
  const MetricGrid({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 900 ? 4 : (c.maxWidth > 560 ? 3 : 2);
      const gap = 8.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final ch in children) SizedBox(width: w, child: ch),
      ]);
    });
  }
}

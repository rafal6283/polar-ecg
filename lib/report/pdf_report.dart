import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../analysis/analysis_result.dart';
import '../analysis/confidence.dart';
import '../analysis/reference_ranges.dart';
import '../recording/markers.dart';

/// Dane osoby do nagłówka raportu.
class ReportPerson {
  final String name;
  final int? age;
  final String sex;
  const ReportPerson({this.name = '', this.age, this.sex = ''});
}

/// Raport PDF dla lekarza: podsumowanie, parametry przebiegu, zdarzenia, objawy
/// i fragmenty EKG (25 mm/s, 10 mm/mV) z najważniejszymi momentami.
Future<Uint8List> buildPdfReport({
  required AnalysisResult a,
  required Float32List signal,
  List<SymptomMarker> markers = const [],
  ReportPerson person = const ReportPerson(),
  String? deviceName,
  (Uint8List regular, Uint8List bold)? fontData, // czcionka dołączona do aplikacji (assets/fonts)
}) async {
  final fonts = fontData != null
      ? (pw.Font.ttf(ByteData.sublistView(fontData.$1)), pw.Font.ttf(ByteData.sublistView(fontData.$2)))
      : await _loadFonts();
  String tx(String s) => fonts == null ? _ascii(s) : s;
  final doc = pw.Document(
    theme: fonts == null ? null : pw.ThemeData.withFont(base: fonts.$1, bold: fonts.$2),
    title: 'Raport EKG',
  );
  final s = a.stats.values;
  final tl = a.timeline;
  String clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  String date(DateTime t) => '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year}';
  String num0(num? v, [int d = 0]) => v == null ? '-' : v.toStringAsFixed(d).replaceAll('.', ',');
  String dur(num? sec) {
    if (sec == null) return '-';
    final d = Duration(seconds: sec.round());
    return d.inHours > 0 ? '${d.inHours} h ${d.inMinutes % 60} min' : '${d.inMinutes} min ${d.inSeconds % 60} s';
  }

  const red = PdfColor.fromInt(0xFFC62828);
  final small = const pw.TextStyle(fontSize: 8, color: _grey);
  pw.Widget section(String title) => pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(top: 14, bottom: 6),
        padding: const pw.EdgeInsets.only(bottom: 3),
        decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _navy, width: 0.8))),
        child: pw.Text(tx(title).toUpperCase(),
            style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold, color: _navy, letterSpacing: 0.8)),
      );
  // Nagłówek sekcji razem z treścią o stałej wysokości (nie rozdzielane między strony).
  // (Row – poziomy Flex – nie dzieli się między strony, w przeciwieństwie do Column.)
  pw.Widget keep(List<pw.Widget> children) => pw.Row(children: [
        pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: children)),
      ]);
  final conf = AnalysisConfidence.of(a);
  final confColor = switch (conf.level) {
    ConfidenceLevel.high => PdfColors.green800,
    ConfidenceLevel.medium => PdfColors.orange800,
    ConfidenceLevel.low => red,
  };

  // Wybór fragmentów EKG: objawy, zdarzenia (od najpoważniejszych), przykład rytmu podstawowego.
  final strips = <(int, String)>[];
  for (final m in markers) {
    if (m.sample >= 0) strips.add((m.sample, 'Objaw: ${m.label} (${clock(m.time)})'));
  }
  final evSorted = [...a.events]..sort((x, y) => y.severity.index.compareTo(x.severity.index));
  for (final e in evSorted) {
    if (strips.length >= 8) break;
    if (strips.any((st) => (st.$1 - e.startSample).abs() < 10 * a.sampleRate)) continue;
    strips.add((e.startSample, '${e.type.label} ${e.detail} (${clock(tl.timeOf(e.startSample))})'));
  }
  if (strips.length < 8) {
    final vIdx = [for (var i = 0; i < a.labels.length; i++) if (a.labels[i] == BeatType.ventricular) i];
    if (vIdx.isNotEmpty) {
      final k = vIdx.first;
      strips.add((a.rPeaks[k], 'Przykładowe pobudzenie komorowe (${clock(tl.timeOf(a.rPeaks[k]))})'));
    }
  }
  final firstN = a.labels.indexWhere((l) => l == BeatType.normal);
  if (firstN >= 0) {
    final mid = a.labels.length ~/ 2;
    final k = a.labels[mid] == BeatType.normal ? mid : firstN;
    strips.insert(0, (a.rPeaks[k], 'Rytm podstawowy (${clock(tl.timeOf(a.rPeaks[k]))})'));
  }

  final bad = outOfRange(s, sex: person.sex);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(15 * PdfPageFormat.mm),
    footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text(tx('Polar EKG · analiza automatyczna z jednego odprowadzenia – nie jest diagnozą lekarską.'), style: small),
      pw.Text('${ctx.pageNumber}/${ctx.pagesCount}', style: small),
    ]),
    build: (ctx) => [
      _header(tx),
      pw.SizedBox(height: 10),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: _infoBox(tx, 'Osoba', [
            person.name.isEmpty ? 'nie podano' : person.name,
            [
              if (person.age != null) 'wiek ${person.age}',
              if (person.sex == 'M') 'mężczyzna' else if (person.sex == 'K') 'kobieta',
            ].join(', '),
          ]),
        ),
        pw.SizedBox(width: 8),
        pw.Expanded(
          flex: 2,
          child: _infoBox(tx, 'Zapis', [
            '${date(tl.started)}, początek ${clock(tl.started)} · czas ${dur(s['duration_s'])} '
                '(analizowane ${dur(s['analyzed_s'])})',
            '${deviceName ?? 'Polar H10'} · jedno odprowadzenie piersiowe, 130 Hz · wydruk 25 mm/s, 10 mm/mV',
          ]),
        ),
      ]),
      pw.SizedBox(height: 6),
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: pw.BoxDecoration(
            border: pw.Border(left: pw.BorderSide(color: confColor, width: 3)), color: PdfColors.grey100),
        child: pw.RichText(
          text: pw.TextSpan(style: const pw.TextStyle(fontSize: 8.5), children: [
            pw.TextSpan(text: tx('Wiarygodność analizy: ')),
            pw.TextSpan(text: tx(conf.level.label), style: pw.TextStyle(color: confColor, fontWeight: pw.FontWeight.bold)),
            if (conf.reasons.isNotEmpty) pw.TextSpan(text: tx(' – ${conf.reasons.join('; ')}')),
          ]),
        ),
      ),
      pw.SizedBox(height: 10),
      pw.Row(children: [
        for (final (i, k) in [
          ('Tętno średnie', '${num0(s['hr_mean'])} /min', '${num0(s['hr_min'])}–${num0(s['hr_max'])} /min'),
          ('Pobudzenia V', num0(s['v']), '${num0(s['v_per_h'], 1)} /h'),
          ('Pobudzenia S', num0(s['s']), '${num0(s['s_per_h'], 1)} /h'),
          ('Migotanie (AF)', '${num0(s['af_burden_pct'], 1)} %', 'czasu zapisu'),
          ('Najdłuższa pauza', s['longest_pause_s'] == null ? '–' : '${num0(s['longest_pause_s'], 1)} s',
              s['longest_pause_s'] == null ? 'brak > 2 s' : 'najdłuższa'),
        ].indexed) ...[
          if (i > 0) pw.SizedBox(width: 6),
          pw.Expanded(child: _kpi(tx, k.$1, k.$2, k.$3)),
        ],
      ]),

      section('Podsumowanie'),
      _table(tx, [
        ['Tętno średnie / min / maks', '${num0(s['hr_mean'])} / ${num0(s['hr_min'])} / ${num0(s['hr_max'])} /min'],
        if (s['hr_rest'] != null) ['Tętno w spoczynku (akcelerometr)', '${num0(s['hr_rest'])} /min'],
        ['Liczba pobudzeń', num0(s['beats'])],
        ['Pobudzenia komorowe (V)', '${num0(s['v'])} (${num0(s['v_per_h'], 1)}/h)'],
        ['Pobudzenia nadkomorowe (S)', '${num0(s['s'])} (${num0(s['s_per_h'], 1)}/h)'],
        ['Obciążenie migotaniem przedsionków', '${num0(s['af_burden_pct'], 1)} %'],
        ['Najdłuższa pauza', s['longest_pause_s'] == null ? 'brak > 2 s' : '${num0(s['longest_pause_s'], 1)} s'],
        ['HRV: SDNN / RMSSD / pNN50', '${num0(s['sdnn_ms'])} ms / ${num0(s['rmssd_ms'])} ms / ${num0(s['pnn50_pct'], 1)} %'],
        if (s['act_rest_pct'] != null)
          ['Aktywność: spoczynek / lekka / umiark. / intens.',
            '${num0(s['act_rest_pct'])} / ${num0(s['act_light_pct'])} / ${num0(s['act_moderate_pct'])} / ${num0(s['act_vigorous_pct'])} %'],
      ]),

      section('Parametry przebiegu (uśredniony zespół)'),
      pw.Text(tx(bad.isEmpty ? 'W normie' : 'Poza zakresem: ${bad.map((p) => p.label).join(', ')}'),
          style: pw.TextStyle(color: bad.isEmpty ? PdfColors.green800 : red, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          flex: 3,
          child: _table(tx, [
            for (final p in paramsFor(person.sex))
              if (s[p.key] != null)
                [
                  p.label,
                  '${num0(s[p.key], p.digits)} ${p.unit}',
                  p.rated ? p.rangeText : '',
                  p.within(s[p.key]) == false ? '!' : '',
                ],
          ], header: ['Parametr', 'Wartość', 'Zakres', '']),
        ),
        pw.SizedBox(width: 8),
        if (a.template != null) pw.Expanded(flex: 2, child: _templateWidget(a)),
      ]),

      if (markers.isNotEmpty && markers.length <= 15)
        keep([
          section('Zgłoszone objawy'),
          _table(tx, [for (final m in markers) [clock(m.time), m.label]], header: ['Godzina', 'Objaw']),
        ])
      else if (markers.isNotEmpty) ...[
        section('Zgłoszone objawy'),
        _table(tx, [for (final m in markers) [clock(m.time), m.label]], header: ['Godzina', 'Objaw']),
      ],

      section('Zdarzenia (${a.events.length})'),
      if (a.events.isEmpty)
        pw.Text(tx('Nie wykryto zaburzeń rytmu.'))
      else
        _table(tx, [
          for (final e in a.events.take(40))
            [clock(tl.timeOf(e.startSample)), e.type.label, e.detail, switch (e.severity) {
              Severity.high => 'wysoka',
              Severity.medium => 'średnia',
              Severity.low => 'niska',
            }],
        ], header: ['Godzina', 'Zdarzenie', 'Szczegóły', 'Waga']),
      if (a.events.length > 40) pw.Text(tx('… i ${a.events.length - 40} kolejnych'), style: small),

      keep([section('Tętno w czasie zapisu'), _hrTrend(a)]),

      for (final (i, (sample, title)) in strips.indexed)
        keep([
          if (i == 0) section('Fragmenty EKG'),
          pw.Text(tx(title), style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 2),
          _strip(a, signal, sample),
          pw.SizedBox(height: 8),
        ]),
      pw.SizedBox(height: 8),
      pw.Text(
          tx('Oznaczenia: N – prawidłowe, S – nadkomorowe, V – komorowe, Q – nieczytelne, A – w migotaniu. '
              'Klasyfikacja automatyczna (sieć neuronowa uczona na MIT-BIH, personalizowana poprawkami użytkownika). '
              'Wartości QT i ST z jednego niestandardowego odprowadzenia są orientacyjne.'),
          style: small),
    ],
  ));
  return doc.save();
}

const _navy = PdfColor.fromInt(0xFF0B4F6C);
const _navyLight = PdfColor.fromInt(0xFFE3EEF3);
const _ecgRed = PdfColor.fromInt(0xFFD7263D);
const _grey = PdfColor.fromInt(0xFF5F6B70);

pw.Widget _table(String Function(String) tx, List<List<String>> rows, {List<String>? header}) =>
    pw.TableHelper.fromTextArray(
      headers: header?.map(tx).toList(),
      data: [for (final r in rows) r.map(tx).toList()],
      cellStyle: const pw.TextStyle(fontSize: 9),
      headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: _navy),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
      border: const pw.TableBorder(horizontalInside: pw.BorderSide(width: 0.3, color: PdfColors.grey300)),
      headerDecoration: const pw.BoxDecoration(color: _navyLight),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF7F9FA)),
    );

/// Pasek tytułowy: logo (serce z EKG) i nazwa raportu.
pw.Widget _header(String Function(String) tx) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const pw.BoxDecoration(color: _navy, borderRadius: pw.BorderRadius.all(pw.Radius.circular(6))),
      child: pw.Row(children: [
        pw.Container(
          width: 30,
          height: 30,
          decoration: const pw.BoxDecoration(color: PdfColors.white, borderRadius: pw.BorderRadius.all(pw.Radius.circular(7))),
          child: pw.CustomPaint(size: const PdfPoint(30, 30), painter: _paintLogo),
        ),
        pw.SizedBox(width: 10),
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(tx('Raport EKG'),
                style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
            pw.Text(tx('Zapis z opaski piersiowej Polar H10 – analiza rytmu i przebiegu'),
                style: const pw.TextStyle(fontSize: 9, color: PdfColor.fromInt(0xFFCFE3EC))),
          ]),
        ),
        pw.Text(tx('Polar EKG'), style: pw.TextStyle(fontSize: 9, color: PdfColors.white, fontWeight: pw.FontWeight.bold)),
      ]),
    );

/// Logo w kwadracie 30 pt (układ PDF: oś Y w górę).
void _paintLogo(PdfGraphics c, PdfPoint size) {
  final w = size.x, h = size.y;
  double x(double v) => 5 + v * (w - 10);
  double y(double v) => h - (6 + v * (h - 11)); // v=0 góra serca
  c
    ..setFillColor(_ecgRed)
    ..moveTo(x(0.5), y(0.93))
    ..curveTo(x(0.18), y(0.70), x(0.0), y(0.50), x(0.0), y(0.30))
    ..curveTo(x(0.0), y(0.12), x(0.15), y(0.0), x(0.30), y(0.0))
    ..curveTo(x(0.40), y(0.0), x(0.47), y(0.05), x(0.5), y(0.14))
    ..curveTo(x(0.53), y(0.05), x(0.60), y(0.0), x(0.70), y(0.0))
    ..curveTo(x(0.85), y(0.0), x(1.0), y(0.12), x(1.0), y(0.30))
    ..curveTo(x(1.0), y(0.50), x(0.82), y(0.70), x(0.5), y(0.93))
    ..closePath()
    ..fillPath();
  const pts = [
    (0.0, 0.52), (0.30, 0.52), (0.40, 0.60), (0.50, 0.18), (0.58, 0.76), (0.66, 0.52), (1.0, 0.52),
  ];
  c
    ..setStrokeColor(PdfColors.white)
    ..setLineWidth(1.6)
    ..setLineJoin(PdfLineJoin.round)
    ..setLineCap(PdfLineCap.round);
  for (final (i, p) in pts.indexed) {
    i == 0 ? c.moveTo(x(p.$1), y(p.$2)) : c.lineTo(x(p.$1), y(p.$2));
  }
  c.strokePath();
}

pw.Widget _infoBox(String Function(String) tx, String title, List<String> lines) => pw.Container(
      padding: const pw.EdgeInsets.all(7),
      decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300, width: 0.6),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5))),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(tx(title).toUpperCase(),
            style: pw.TextStyle(fontSize: 7.5, color: _navy, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8)),
        pw.SizedBox(height: 2),
        for (final (i, l) in lines.where((l) => l.isNotEmpty).indexed)
          pw.Text(tx(l), style: pw.TextStyle(fontSize: i == 0 ? 10 : 8.5, fontWeight: i == 0 ? pw.FontWeight.bold : null)),
      ]),
    );

pw.Widget _kpi(String Function(String) tx, String label, String value, String sub) => pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(7, 6, 7, 6),
      decoration: const pw.BoxDecoration(color: _navyLight, borderRadius: pw.BorderRadius.all(pw.Radius.circular(5))),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(tx(label), style: const pw.TextStyle(fontSize: 7.5, color: _grey)),
        pw.SizedBox(height: 1),
        pw.Text(tx(value), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _navy)),
        pw.Text(tx(sub), style: const pw.TextStyle(fontSize: 7.5, color: _grey)),
      ]),
    );

const _gridMinor = PdfColor.fromInt(0xFFF6D3CC);
const _gridMajor = PdfColor.fromInt(0xFFE8A196);

/// Fragment EKG 7 s: 25 mm/s, 10 mm/mV, siatka 1 mm / 5 mm, etykiety pobudzeń.
pw.Widget _strip(AnalysisResult a, Float32List f, int center) {
  const seconds = 7.0, mmPerS = 25.0, mmPerMv = 10.0, heightMm = 30.0;
  final fs = a.sampleRate;
  final start = max(0, center - (seconds * fs / 2).round());
  final end = min(f.length, start + (seconds * fs).round());
  const mm = PdfPageFormat.mm;
  const w = seconds * mmPerS * mm, h = heightMm * mm;
  // Linia bazowa: mediana sygnału we fragmencie.
  final seg = [for (var i = start; i < end; i++) f[i]]..sort();
  final base = seg.isEmpty ? 0.0 : seg[seg.length ~/ 2];
  double x(int i) => (i - start) / fs * mmPerS * mm;
  double y(double uv) => h / 2 + (uv - base) / 1000 * mmPerMv * mm;

  final labels = <pw.Widget>[];
  for (var k = a.beatIndexAtOrAfter(start); k < a.rPeaks.length && a.rPeaks[k] < end; k++) {
    final l = a.labels[k];
    final letter = a.inAf[k] == 1 && l == BeatType.normal ? 'A' : BeatType.letters[l];
    labels.add(pw.Positioned(
      left: x(a.rPeaks[k]) - 3,
      top: 0,
      child: pw.Text(letter,
          style: pw.TextStyle(
            fontSize: 7,
            fontWeight: l == BeatType.normal ? pw.FontWeight.normal : pw.FontWeight.bold,
            color: switch (l) {
              BeatType.ventricular => PdfColors.red800,
              BeatType.supraventricular => PdfColors.blue800,
              _ => PdfColors.grey700,
            },
          )),
    ));
  }
  return pw.Stack(children: [
    pw.CustomPaint(
      size: const PdfPoint(w, h),
      painter: (canvas, size) {
        for (var i = 0; i <= seconds * mmPerS; i++) {
          canvas
            ..setStrokeColor(i % 5 == 0 ? _gridMajor : _gridMinor)
            ..setLineWidth(i % 5 == 0 ? 0.5 : 0.2)
            ..moveTo(i * mm, 0)
            ..lineTo(i * mm, h)
            ..strokePath();
        }
        for (var j = 0; j <= heightMm; j++) {
          canvas
            ..setStrokeColor(j % 5 == 0 ? _gridMajor : _gridMinor)
            ..setLineWidth(j % 5 == 0 ? 0.5 : 0.2)
            ..moveTo(0, j * mm)
            ..lineTo(w, j * mm)
            ..strokePath();
        }
        if (end - start < 2) return;
        canvas
          ..setStrokeColor(PdfColors.black)
          ..setLineWidth(0.6)
          ..moveTo(x(start), y(f[start]).clamp(0, h));
        for (var i = start + 1; i < end; i++) {
          canvas.lineTo(x(i), y(f[i]).clamp(0, h));
        }
        canvas.strokePath();
      },
    ),
    ...labels,
  ]);
}

/// Uśredniony zespół z zaznaczonymi punktami pomiarowymi.
pw.Widget _templateWidget(AnalysisResult a) {
  final t = a.template!;
  final s = a.stats.values;
  final fs = a.sampleRate;
  const w = 70 * PdfPageFormat.mm, h = 40 * PdfPageFormat.mm;
  final base = (s['m_base_uv'] ?? 0).toDouble();
  var peak = 500.0;
  for (final v in t) {
    peak = max(peak, (v - base).abs());
  }
  double x(double ms) => (ms + 300) / 900 * w;
  double y(double uv) => h / 2 + (uv - base) / (peak * 1.15) * h / 2;
  return pw.CustomPaint(
    size: const PdfPoint(w, h),
    painter: (canvas, size) {
      for (var ms = -300.0; ms <= 600; ms += 40) {
        canvas
          ..setStrokeColor(ms % 200 == 0 ? _gridMajor : _gridMinor)
          ..setLineWidth(0.3)
          ..moveTo(x(ms), 0)
          ..lineTo(x(ms), h)
          ..strokePath();
      }
      const marks = {
        'm_p_on': PdfColors.green700,
        'm_qrs_on': PdfColors.blue700,
        'm_j': PdfColors.purple700,
        'm_t_peak': PdfColors.orange700,
        'm_t_end': PdfColors.red700,
      };
      marks.forEach((k, c) {
        final v = s[k];
        if (v == null) return;
        canvas
          ..setStrokeColor(c)
          ..setLineWidth(0.8)
          ..moveTo(x(v.toDouble()), 0)
          ..lineTo(x(v.toDouble()), h)
          ..strokePath();
      });
      canvas
        ..setStrokeColor(PdfColors.black)
        ..setLineWidth(1)
        ..moveTo(x((0 - a.templatePre) * 1000 / fs), y(t[0]));
      for (var k = 1; k < t.length; k++) {
        canvas.lineTo(x((k - a.templatePre) * 1000 / fs), y(t[k]));
      }
      canvas.strokePath();
    },
  );
}

/// Tętno minutowe w czasie zapisu.
pw.Widget _hrTrend(AnalysisResult a) {
  final fs = a.sampleRate;
  final perMin = <int, List<double>>{};
  for (var k = 1; k < a.rPeaks.length; k++) {
    if (a.labels[k] == BeatType.unknown || a.labels[k - 1] == BeatType.unknown) continue;
    final rr = (a.rPeaks[k] - a.rPeaks[k - 1]) / fs;
    if (rr > 3) continue;
    perMin.putIfAbsent(a.timeline.offsetOf(a.rPeaks[k]).inMinutes, () => []).add(rr);
  }
  final pts = perMin.entries
      .where((e) => e.value.length >= 10)
      .map((e) => (e.key, 60 / (e.value.reduce((p, q) => p + q) / e.value.length)))
      .toList()
    ..sort((p, q) => p.$1.compareTo(q.$1));
  const w = 180 * PdfPageFormat.mm, h = 30 * PdfPageFormat.mm;
  if (pts.length < 2) return pw.Text('Za krótki zapis do wykresu trendu.');
  final maxMin = max(1, pts.last.$1);
  double x(int m) => m / maxMin * w;
  double y(double hr) => (hr.clamp(30, 180) - 30) / 150 * h;
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.CustomPaint(
      size: const PdfPoint(w, h),
      painter: (canvas, size) {
        for (final hr in [60.0, 100.0, 140.0]) {
          canvas
            ..setStrokeColor(PdfColors.grey300)
            ..setLineWidth(0.3)
            ..moveTo(0, y(hr))
            ..lineTo(w, y(hr))
            ..strokePath();
        }
        canvas
          ..setStrokeColor(PdfColors.red700)
          ..setLineWidth(0.8)
          ..moveTo(x(pts.first.$1), y(pts.first.$2));
        for (final p in pts.skip(1)) {
          canvas.lineTo(x(p.$1), y(p.$2));
        }
        canvas.strokePath();
      },
    ),
    pw.Text('Linie: 60, 100, 140 /min; oś pozioma: 0-$maxMin min zapisu', style: const pw.TextStyle(fontSize: 7)),
  ]);
}

/// Zapasowa czcionka z polskimi znakami: systemowa (Android: Roboto, Windows: Arial).
Future<(pw.Font, pw.Font)?> _loadFonts() async {
  const regular = [
    '/system/fonts/Roboto-Regular.ttf',
    '/system/fonts/RobotoStatic-Regular.ttf',
    '/system/fonts/NotoSans-Regular.ttf',
    '/system/fonts/DroidSans.ttf',
    'C:/Windows/Fonts/arial.ttf',
  ];
  const bold = [
    '/system/fonts/Roboto-Bold.ttf',
    '/system/fonts/RobotoStatic-Bold.ttf',
    '/system/fonts/NotoSans-Bold.ttf',
    '/system/fonts/DroidSans-Bold.ttf',
    'C:/Windows/Fonts/arialbd.ttf',
  ];
  Future<pw.Font?> first(List<String> paths) async {
    for (final p in paths) {
      final f = File(p);
      if (await f.exists()) {
        try {
          final bytes = await f.readAsBytes();
          return pw.Font.ttf(ByteData.sublistView(bytes));
        } catch (_) {}
      }
    }
    return null;
  }

  final r = await first(regular);
  if (r == null) return null;
  return (r, await first(bold) ?? r);
}

/// Zastępuje polskie znaki, gdy brak czcionki z ich obsługą.
String _ascii(String s) {
  const map = {
    'ą': 'a', 'ć': 'c', 'ę': 'e', 'ł': 'l', 'ń': 'n', 'ó': 'o', 'ś': 's', 'ź': 'z', 'ż': 'z',
    'Ą': 'A', 'Ć': 'C', 'Ę': 'E', 'Ł': 'L', 'Ń': 'N', 'Ó': 'O', 'Ś': 'S', 'Ź': 'Z', 'Ż': 'Z',
    '–': '-', 'µ': 'u', '≥': '>=', '≤': '<=', '·': '-', '…': '...', '√': 'sqrt', '∛': 'cbrt',
  };
  return s.split('').map((c) => map[c] ?? c).join();
}

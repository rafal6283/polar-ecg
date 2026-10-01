part of 'pdf_report.dart';

/// Jeden zapis w raporcie zbiorczym.
class SummaryItem {
  final AnalysisResult a;
  final List<SymptomMarker> markers;
  const SummaryItem(this.a, this.markers);
}

/// Raport zbiorczy z wielu zapisów (np. tydzień): podsumowanie okresu, tętno i pobudzenia dzień po dniu,
/// pomiary poranne HRV, zdarzenia i objawy ze wszystkich zapisów.
Future<Uint8List> buildSummaryReport({
  required List<SummaryItem> items,
  List<HrvMeasurement> hrv = const [],
  ReportPerson person = const ReportPerson(),
  (Uint8List regular, Uint8List bold)? fontData,
}) async {
  final fonts = fontData != null
      ? (pw.Font.ttf(ByteData.sublistView(fontData.$1)), pw.Font.ttf(ByteData.sublistView(fontData.$2)))
      : await _loadFonts();
  String tx(String s) => fonts == null ? _ascii(s) : s;
  final doc = pw.Document(
    theme: fonts == null ? null : pw.ThemeData.withFont(base: fonts.$1, bold: fonts.$2),
    title: 'Raport zbiorczy EKG',
  );
  final sorted = [...items]..sort((x, y) => x.a.timeline.started.compareTo(y.a.timeline.started));
  String two(int v) => v.toString().padLeft(2, '0');
  String date(DateTime t) => '${two(t.day)}.${two(t.month)}.${t.year}';
  String clock(DateTime t) => '${two(t.hour)}:${two(t.minute)}';
  String num0(num? v, [int d = 0]) => v == null ? '–' : v.toStringAsFixed(d).replaceAll('.', ',');
  String hours(double sec) => sec >= 3600 ? '${num0(sec / 3600, 1)} h' : '${(sec / 60).round()} min';
  final small = const pw.TextStyle(fontSize: 8, color: _grey);
  pw.Widget section(String title) => pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(top: 14, bottom: 6),
        padding: const pw.EdgeInsets.only(bottom: 3),
        decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _navy, width: 0.8))),
        child: pw.Text(tx(title).toUpperCase(),
            style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold, color: _navy, letterSpacing: 0.8)),
      );

  // Sumy okresu (ważone czasem analizy).
  var analyzed = 0.0, beats = 0, v = 0, sv = 0, afSec = 0.0, hrW = 0.0, hrSec = 0.0;
  double? maxPause;
  for (final it in sorted) {
    final s = it.a.stats.values;
    final an = (s['analyzed_s'] ?? 0).toDouble();
    analyzed += an;
    beats += (s['beats'] ?? 0).toInt();
    v += (s['v'] ?? 0).toInt();
    sv += (s['s'] ?? 0).toInt();
    afSec += (s['af_burden_pct'] ?? 0).toDouble() / 100 * an;
    if (s['hr_mean'] != null) {
      hrW += s['hr_mean']!.toDouble() * an;
      hrSec += an;
    }
    final p = s['longest_pause_s']?.toDouble();
    if (p != null) maxPause = max(maxPause ?? 0, p);
  }
  final h = max(analyzed / 3600, 1e-9);

  // Dzień po dniu.
  final days = <DateTime, List<SummaryItem>>{};
  for (final it in sorted) {
    final st = it.a.timeline.started;
    days.putIfAbsent(DateTime(st.year, st.month, st.day), () => []).add(it);
  }
  final dayRows = <List<String>>[];
  final dayHr = <(DateTime, double, double?, double?)>[]; // dzień, śr., min, maks
  for (final e in days.entries) {
    var an = 0.0, dv = 0, ds = 0, daf = 0.0, w = 0.0, ws = 0.0, ev = 0;
    double? mn, mx;
    for (final it in e.value) {
      final s = it.a.stats.values;
      final a1 = (s['analyzed_s'] ?? 0).toDouble();
      an += a1;
      dv += (s['v'] ?? 0).toInt();
      ds += (s['s'] ?? 0).toInt();
      daf += (s['af_burden_pct'] ?? 0).toDouble() / 100 * a1;
      if (s['hr_mean'] != null) {
        w += s['hr_mean']!.toDouble() * a1;
        ws += a1;
      }
      if (s['hr_min'] != null) mn = min(mn ?? 999, s['hr_min']!.toDouble());
      if (s['hr_max'] != null) mx = max(mx ?? 0, s['hr_max']!.toDouble());
      ev += it.a.events.where((x) => x.severity == Severity.high).length;
    }
    final dh = max(an / 3600, 1e-9);
    if (ws > 0) dayHr.add((e.key, w / ws, mn, mx));
    dayRows.add([
      date(e.key),
      '${e.value.length}',
      hours(an),
      ws > 0 ? '${num0(w / ws)} (${num0(mn)}–${num0(mx)})' : '–',
      '$dv (${num0(dv / dh, 1)}/h)',
      '$ds (${num0(ds / dh, 1)}/h)',
      an > 0 ? '${num0(100 * daf / an, 1)} %' : '–',
      ev == 0 ? '–' : '$ev',
    ]);
  }

  final events = [
    for (final it in sorted)
      for (final e in it.a.events)
        if (e.severity != Severity.low) (it.a.timeline.timeOf(e.startSample), e)
  ];
  final symptoms = [
    for (final it in sorted)
      for (final m in it.markers) m
  ];
  final from = sorted.first.a.timeline.started, to = sorted.last.a.timeline.started;
  final hrvIn = [
    for (final m in hrv)
      if (!m.time.isBefore(DateTime(from.year, from.month, from.day)) &&
          m.time.isBefore(DateTime(to.year, to.month, to.day).add(const Duration(days: 1))))
        m
  ];

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(15 * PdfPageFormat.mm),
    footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text(tx('Polar EKG · analiza automatyczna z jednego odprowadzenia – nie jest diagnozą lekarską.'), style: small),
      pw.Text('${ctx.pageNumber}/${ctx.pagesCount}', style: small),
    ]),
    build: (ctx) => [
      _header(tx, title: 'Raport zbiorczy EKG', subtitle: 'Podsumowanie wielu zapisów z opaski Polar H10'),
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
          child: _infoBox(tx, 'Okres', [
            from.day == to.day && from.month == to.month && from.year == to.year
                ? date(from)
                : '${date(from)} – ${date(to)}',
            '${sorted.length} zapisów, łącznie ${hours(analyzed)} analizowanego EKG, ${num0(beats)} uderzeń',
          ]),
        ),
      ]),
      pw.SizedBox(height: 10),
      pw.Row(children: [
        for (final (i, k) in [
          ('Tętno średnie', hrSec > 0 ? '${num0(hrW / hrSec)} /min' : '–', 'ważone czasem'),
          ('Pobudzenia V', num0(v), '${num0(v / h, 1)} /h'),
          ('Pobudzenia S', num0(sv), '${num0(sv / h, 1)} /h'),
          ('Migotanie (AF)', '${num0(analyzed > 0 ? 100 * afSec / analyzed : 0, 1)} %', 'czasu zapisów'),
          ('Najdłuższa pauza', maxPause == null ? '–' : '${num0(maxPause, 1)} s', maxPause == null ? 'brak > 2 s' : 'w okresie'),
        ].indexed) ...[
          if (i > 0) pw.SizedBox(width: 6),
          pw.Expanded(child: _kpi(tx, k.$1, k.$2, k.$3)),
        ],
      ]),
      section('Dzień po dniu'),
      _table(tx, dayRows,
          header: ['Dzień', 'Zapisy', 'Czas', 'Tętno śr. (min–maks)', 'V', 'S', 'AF', 'Zdarzenia wysokie']),
      if (dayHr.length >= 2) ...[
        pw.SizedBox(height: 8),
        _dailyChart(tx, dayHr),
      ],
      if (hrvIn.isNotEmpty) ...[
        section('Poranny pomiar HRV (${hrvIn.length})'),
        _table(tx, [
          for (final m in hrvIn.reversed)
            [
              '${date(m.time)} ${clock(m.time)}',
              '${num0(m.rmssd)} ms',
              num0(m.lnRmssd, 2),
              '${num0(m.hr)} /min',
              '${num0(m.sdnn)} ms',
              m.reliable ? hrvBaseline(hrv, m).status.label : 'mniej wiarygodny',
            ],
        ], header: ['Data', 'RMSSD', 'ln RMSSD', 'Tętno', 'SDNN', 'Ocena']),
      ],
      section('Zdarzenia średniej i wysokiej wagi (${events.length})'),
      if (events.isEmpty)
        pw.Text(tx('Brak.'))
      else
        _table(tx, [
          for (final (t, e) in events.take(80))
            [
              '${date(t)} ${clock(t)}',
              e.type.label,
              e.detail,
              e.severity == Severity.high ? 'wysoka' : 'średnia',
            ],
        ], header: ['Czas', 'Zdarzenie', 'Szczegóły', 'Waga']),
      if (events.length > 80) pw.Text(tx('… i ${events.length - 80} kolejnych'), style: small),
      if (symptoms.isNotEmpty) ...[
        section('Zgłoszone objawy (${symptoms.length})'),
        _table(tx, [for (final m in symptoms) ['${date(m.time)} ${clock(m.time)}', m.label]],
            header: ['Czas', 'Objaw']),
      ],
      section('Zapisy'),
      _table(tx, [
        for (final it in sorted)
          [
            '${date(it.a.timeline.started)} ${clock(it.a.timeline.started)}',
            hours((it.a.stats['duration_s'] ?? 0).toDouble()),
            '${num0(it.a.stats['hr_mean'])} /min',
            num0(it.a.stats['v']),
            num0(it.a.stats['s']),
            '${num0(it.a.stats['af_burden_pct'], 1)} %',
            AnalysisConfidence.of(it.a).level.label,
          ],
      ], header: ['Początek', 'Czas', 'Tętno śr.', 'V', 'S', 'AF', 'Wiarygodność']),
      pw.SizedBox(height: 8),
      pw.Text(
          tx('Szczegóły każdego zapisu (fragmenty EKG, parametry przebiegu) – w raportach pojedynczych zapisów. '
              'Pobudzenia V/S i AF wykrywane automatycznie z jednego odprowadzenia; wartości orientacyjne.'),
          style: small),
    ],
  ));
  return doc.save();
}

/// Tętno dzień po dniu: średnia (punkt) i zakres min–maks (pionowa kreska).
pw.Widget _dailyChart(String Function(String) tx, List<(DateTime, double, double?, double?)> d) {
  const mm = PdfPageFormat.mm;
  const left = 9 * mm, w = 171 * mm, h = 32 * mm, base = 5 * mm;
  const totalH = base + h + 2 * mm;
  final lo = (d.map((e) => e.$3 ?? e.$2).reduce(min) / 10).floor() * 10.0 - 5;
  final hi = (d.map((e) => e.$4 ?? e.$2).reduce(max) / 10).ceil() * 10.0 + 5;
  double x(int i) => left + (i + 0.5) / d.length * w;
  double y(double v) => base + (v - lo) / (hi - lo) * h;
  final step = ((hi - lo) / 4 / 10).ceil() * 10.0;
  final grid = [for (var v = (lo / step).ceil() * step; v <= hi; v += step) v];
  final every = (d.length / 10).ceil();
  return pw.Stack(children: [
    pw.CustomPaint(
      size: const PdfPoint(left + w, totalH),
      painter: (c, size) {
        for (final g in grid) {
          c
            ..setStrokeColor(PdfColors.grey200)
            ..setLineWidth(0.3)
            ..moveTo(left, y(g))
            ..lineTo(left + w, y(g))
            ..strokePath();
        }
        for (var i = 0; i < d.length; i++) {
          final (_, mean, mn, mx) = d[i];
          if (mn != null && mx != null) {
            c
              ..setStrokeColor(const PdfColor.fromInt(0xFFF0A3AE))
              ..setLineWidth(3)
              ..setLineCap(PdfLineCap.round)
              ..moveTo(x(i), y(mn))
              ..lineTo(x(i), y(mx))
              ..strokePath();
          }
          c
            ..setFillColor(_ecgRed)
            ..drawEllipse(x(i), y(mean), 1.8, 1.8)
            ..fillPath();
        }
        c
          ..setStrokeColor(PdfColors.grey500)
          ..setLineWidth(0.4)
          ..drawRect(left, base, w, h)
          ..strokePath();
      },
    ),
    for (final g in grid)
      pw.Positioned(left: 0, top: totalH - y(g) - 3, child: pw.Text(g.round().toString(), style: const pw.TextStyle(fontSize: 6.5, color: _grey))),
    for (var i = 0; i < d.length; i += every)
      pw.Positioned(
          left: x(i) - 8,
          top: totalH - base + 1,
          child: pw.Text('${d[i].$1.day.toString().padLeft(2, '0')}.${d[i].$1.month.toString().padLeft(2, '0')}',
              style: const pw.TextStyle(fontSize: 6.5, color: _grey))),
  ]);
}

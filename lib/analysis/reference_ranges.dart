/// Parametry przebiegu z zakresami referencyjnymi (dorośli, spoczynek) i opisami do legendy.
/// Zakresy pochodzą ze standardowego 12-odprowadzeniowego EKG; odprowadzenie
/// z opaski piersiowej jest inne, więc ocena jest orientacyjna.
class ParamSpec {
  final String key;
  final String label;
  final String unit;
  final double? min, max; // null = bez oceny (parametr informacyjny)
  final int digits;
  final String hint; // krótka uwaga przy wartości
  final String description; // pełny opis do legendy

  const ParamSpec(
    this.key,
    this.label,
    this.unit, {
    this.min,
    this.max,
    this.digits = 0,
    this.hint = '',
    this.description = '',
  });

  bool get rated => min != null || max != null;

  bool? within(num? v) {
    if (v == null || !rated) return null;
    if (min != null && v < min!) return false;
    if (max != null && v > max!) return false;
    return true;
  }

  String get rangeText => !rated
      ? ''
      : min == null
          ? '≤${_f(max!)}'
          : max == null
              ? '≥${_f(min!)}'
              : '${_f(min!)}–${_f(max!)}';

  static String _f(double v) => v == v.roundToDouble() ? v.round().toString() : v.toString().replaceAll('.', ',');
}

const waveformParams = [
  ParamSpec('hr_mean', 'Tętno średnie', '/min', min: 50, max: 100,
      hint: 'spoczynkowe; podczas wysiłku wyższe',
      description: 'Liczba uderzeń serca na minutę, średnio z całego zapisu (z czytelnych odstępów RR). '
          'W spoczynku 50–100/min; poniżej – bradykardia (normalna np. we śnie i u sportowców), '
          'powyżej – tachykardia (normalna podczas wysiłku, stresu, gorączki).'),
  ParamSpec('pnn50_pct', 'pNN50', '%', digits: 1,
      description: 'Odsetek kolejnych odstępów NN (między prawidłowymi pobudzeniami), które różnią się '
          'o więcej niż 50 ms. Miara zmienności rytmu zależna od nerwu błędnego (układ przywspółczulny) – '
          'wyższa u osób młodych i wypoczętych, niższa przy stresie, zmęczeniu, z wiekiem. Bez normy – '
          'porównuj własne wyniki w czasie.'),
  ParamSpec('pnn200_pct', 'pNN200', '%', min: 0, max: 15, digits: 1,
      hint: 'duża wartość = niemiarowość',
      description: 'Odsetek kolejnych odstępów RR różniących się o więcej niż 200 ms (liczone ze wszystkich '
          'czytelnych pobudzeń). Przy rytmie zatokowym zwykle bliski zera; wysoki sugeruje niemiarowość – '
          'liczne pobudzenia dodatkowe lub migotanie przedsionków.'),
  ParamSpec('qrs_ms', 'QRS', 'ms', min: 60, max: 110,
      hint: '≥ 120 ms: blok odnogi',
      description: 'Czas trwania zespołu QRS – depolaryzacji (pobudzenia) komór. Norma 60–110 ms. '
          '110–120 ms: niepełny blok odnogi, ≥ 120 ms: blok odnogi pęczka Hisa lub rytm komorowy. '
          'Mierzony na uśrednionym zespole od początku Q do punktu J.'),
  ParamSpec('pr_ms', 'PQ (PR)', 'ms', min: 120, max: 200,
      hint: '> 200 ms: blok AV I st.',
      description: 'Czas od początku załamka P do początku QRS – przewodzenie z przedsionków do komór. '
          'Norma 120–200 ms. Dłuższy: blok przedsionkowo-komorowy I stopnia; krótszy: możliwa '
          'dodatkowa droga przewodzenia (np. zespół WPW). Wymaga widocznego załamka P.'),
  ParamSpec('qt_ms', 'QT', 'ms',
      description: 'Czas od początku QRS do końca załamka T – pełny cykl elektryczny komór (pobudzenie '
          'i repolaryzacja). Zależy od tętna, dlatego oceniana jest wartość skorygowana QTc.'),
  ParamSpec('qtc_ms', 'QTc (Bazett)', 'ms', min: 340, max: 460,
      hint: 'jedno odprowadzenie może dawać QT krótsze',
      description: 'QT skorygowany do tętna 60/min wzorem Bazetta: QTc = QT / √RR [s]. Norma ok. 350–450 ms '
          '(mężczyźni) i 360–460 ms (kobiety). Wydłużony QTc (> 470–480 ms) zwiększa ryzyko groźnych '
          'arytmii – bywa skutkiem leków lub zaburzeń elektrolitowych. Wzór Bazetta zawyża QTc przy szybkim tętnie.'),
  ParamSpec('qtcf_ms', 'QTc (Fridericia)', 'ms', min: 340, max: 460,
      description: 'QT skorygowany wzorem Fridericii: QTc = QT / ∛RR [s]. Dokładniejszy niż Bazett przy '
          'tętnie poza zakresem 60–90/min.'),
  ParamSpec('t_pos_pct', 'Załamek T dodatni', '%', min: 90, max: 100,
      description: 'Odsetek prawidłowych pobudzeń z dodatnim (skierowanym w górę) załamkiem T – repolaryzacją '
          'komór. W tym odprowadzeniu T jest zwykle dodatni; ujemne T mogą wynikać z niedokrwienia, '
          'przerostu, zaburzeń elektrolitowych, ale też ze zmiany położenia opaski lub ciała.'),
  ParamSpec('j_uv', 'Punkt J', 'µV', min: -100, max: 150,
      hint: 'względem odcinka PQ',
      description: 'Poziom sygnału w punkcie J (koniec QRS, początek odcinka ST) względem linii izoelektrycznej '
          '(odcinek PQ). Uniesienie lub obniżenie > 100 µV (1 mm) może świadczyć o niedokrwieniu lub '
          'innych zmianach, ale z jednego niestandardowego odprowadzenia nie da się tego ocenić diagnostycznie.'),
  ParamSpec('st60_uv', 'ST (J+60 ms)', 'µV', min: -100, max: 150,
      description: 'Poziom odcinka ST 60 ms po punkcie J względem linii izoelektrycznej – standardowy punkt '
          'oceny obniżenia lub uniesienia ST.'),
  ParamSpec('hf_2_8_pct', 'Energia 2–8 Hz (mean2-8Hz)', '%', min: 0, max: 90, digits: 1,
      description: 'Udział energii sygnału EKG w paśmie 2–8 Hz w całkowitej energii pasma 0,5–40 Hz '
          '(średnio z okien 8 s bez artefaktów, widmo FFT z oknem Hanninga): 100 · E(2–8 Hz) / E(0,5–40 Hz). '
          'Pokazuje, jak duża część sygnału to szybsze zmiany (głównie zespoły QRS i T). Nie odróżnia '
          'zmian fizjologicznych od szumu. Definicja wg Biosignals Solutions (aplikacja „ECG Analysis for Polar H10”).'),
  ParamSpec('systole_uv', 'Potencjał skurczu (meanSystole)', 'µV', min: 60,
      description: 'Średni bezwzględny poziom potencjału elektrycznego w czasie skurczu komór – od początku QRS '
          'do końca T – względem linii izoelektrycznej, na uśrednionym zespole. Niska wartość oznacza słaby '
          'sygnał (np. słaby kontakt elektrod lub niekorzystne położenie opaski). Biosignals Solutions opisuje '
          'meanSystole jedynie jako „poziom potencjału elektrycznego sygnału” – to nasza implementacja tego opisu.'),
  ParamSpec('p_uv', 'Amplituda P', 'µV',
      description: 'Wysokość załamka P (pobudzenie przedsionków) względem linii izoelektrycznej. '
          'Brak załamka P przy niemiarowym rytmie wspiera podejrzenie migotania przedsionków.'),
  ParamSpec('r_uv', 'Amplituda R', 'µV',
      description: 'Wysokość załamka R – zależy od położenia opaski, budowy ciała i pozycji. Użyteczna do '
          'oceny jakości sygnału i porównań między zapisami.'),
  ParamSpec('s_uv', 'Amplituda S', 'µV', description: 'Głębokość załamka S po załamku R.'),
  ParamSpec('t_uv', 'Amplituda T', 'µV',
      description: 'Wysokość załamka T (repolaryzacja komór) względem linii izoelektrycznej; wartość ujemna = T odwrócony.'),
];

/// Pozostałe pojęcia używane w aplikacji (do legendy).
const glossary = [
  ('N – pobudzenie prawidłowe', 'Uderzenie z węzła zatokowego o typowym kształcie i w oczekiwanym czasie.'),
  ('S – pobudzenie nadkomorowe', 'Przedwczesne uderzenie z przedsionków lub łącza AV: prawidłowy (wąski) zespół QRS, '
      'ale za wcześnie, często ze zmienionym lub ukrytym załamkiem P. Pojedyncze są częste i zwykle nieszkodliwe.'),
  ('V – pobudzenie komorowe', 'Uderzenie powstające w komorach: szeroki, zmieniony zespół QRS, zwykle przedwczesny, '
      'często z pauzą wyrównawczą. Pojedyncze bywają u zdrowych; liczne, pary i salwy wymagają konsultacji.'),
  ('Q – nieczytelne', 'Uderzenie w miejscu z artefaktami (ruch, słaby kontakt) – wyłączone z analizy.'),
  ('A – w migotaniu przedsionków', 'Uderzenie w epizodzie podejrzenia migotania przedsionków.'),
  ('Migotanie przedsionków (AF)', 'Chaotyczna praca przedsionków: całkowicie niemiarowe odstępy RR i brak załamków P. '
      'Wykrywane z nieregularności RR (RMSSD, entropia, punkty zwrotne) w oknach 64 uderzeń, epizod ≥ 30 s. '
      'Obciążenie AF = odsetek czasu zapisu w migotaniu.'),
  ('Pauza', 'Przerwa między uderzeniami dłuższa niż 2 s (próg w ustawieniach); > 3 s – istotna.'),
  ('Para / salwa / nsVT', 'Dwa (para) lub ≥ 3 (salwa) kolejne pobudzenia komorowe; salwa szybsza niż 100/min '
      'to nieutrwalony częstoskurcz komorowy (nsVT).'),
  ('Bigeminia / trigeminia', 'Pobudzenie komorowe po każdym (bigeminia) lub co drugim (trigeminia) prawidłowym, ≥ 3 cykle.'),
  ('RR / NN', 'Odstęp między kolejnymi załamkami R [ms]. NN – odstęp między dwoma prawidłowymi pobudzeniami.'),
  ('SDNN', 'Odchylenie standardowe odstępów NN – całkowita zmienność rytmu w zapisie (rośnie z długością zapisu).'),
  ('RMSSD', 'Pierwiastek ze średniego kwadratu różnic kolejnych NN – krótkoterminowa zmienność, aktywność '
      'przywspółczulna. Popularny wskaźnik regeneracji (pomiar poranny).'),
  ('SD1 / SD2', 'Rozrzut punktów wykresu Poincaré w poprzek (SD1, zmienność krótkoterminowa) '
      'i wzdłuż przekątnej (SD2, długoterminowa).'),
  ('Wykres Poincaré', 'Każdy punkt to para kolejnych odstępów (RRₙ, RRₙ₊₁). Rytm zatokowy tworzy wydłużoną chmurę '
      'wzdłuż przekątnej; pobudzenia dodatkowe – osobne skupiska; migotanie – rozproszoną chmurę.'),
  ('Tachogram', 'Odstępy RR w funkcji czasu dla całego zapisu – pozwala szybko znaleźć zmiany rytmu.'),
  ('Jakość sygnału', 'Odsetek czytelnych pobudzeń w ostatnich 30 s. Poniżej 60% popraw opaskę lub zwilż elektrody.'),
];

/// Parametry z zakresami dopasowanymi do płci (QTc: M ≤ 450 ms, K ≤ 460 ms).
List<ParamSpec> paramsFor(String sex) => [
      for (final p in waveformParams)
        if (sex == 'M' && (p.key == 'qtc_ms' || p.key == 'qtcf_ms'))
          ParamSpec(p.key, p.label, p.unit,
              min: p.min, max: 450, digits: p.digits, hint: p.hint, description: p.description)
        else
          p,
    ];

/// Parametry ocenione jako poza zakresem.
List<ParamSpec> outOfRange(Map<String, num?> stats, {String sex = ''}) =>
    [for (final p in paramsFor(sex)) if (p.within(stats[p.key]) == false) p];

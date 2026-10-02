# Polar EKG – kontekst projektu

Prywatna aplikacja Flutter (Android, docelowo też iOS) do rejestracji i analizy EKG z opaski Polar H10.
Użytkownik komunikuje się po polsku; interfejs i komentarze w kodzie są po polsku.
Użytek własny – nie jest to wyrób medyczny (licencja flutter_blue_plus: `License.nonprofit`).

## Struktura
- `lib/ble/` – BLE: protokół PMD (EKG 130 Hz, ACC 25 Hz, także kompresja delta), tętno/RR.
- `lib/recording/` – zapis binarny `ecg.bin`/`acc.bin` (`binary_format.dart`), znaczniki objawów.
- `lib/analysis/` – czysty Dart (działa też na PC): filtry, detektor QRS (Pan-Tompkins), cechy pobudzeń
  (`beat_features.dart`, część `analyzer.dart`), MLP (`mlp.dart`, wagi w `beat_model.g.dart`),
  wykrywanie AF (Dash + COSEn + brak P), zdarzenia, HRV, morfologia (QRS/QT/PR/J/ST, mean2-8Hz, meanSystole),
  profil osobisty (`personal_profile.dart`, k-NN z ręcznych poprawek), analiza na żywo (`live_analyzer.dart`),
  trend/epizody ST (`st_trend.dart`), blok AV II° i trzepotanie (`rhythms.dart`, AFL wyłączone), wiarygodność
  wyniku (`confidence.dart`), grupy morfologii (`beat_clusters.dart`, ekran `ui/viewer/clusters_screen.dart`),
  napady AF z okolicznościami i dziennik (`af_episodes.dart`: tętno w AF, 5 min przed – tętno, S/V, ruch;
  `AfDiary` – obciążenie, pora, wzorzec spoczynek/wysiłek; w summary.json `af_episodes`), rytm przy objawie
  (`rhythm_at.dart`), ocena szybkiego sprawdzenia (`rhythm_check.dart`), ręczne oznaczenia AF (`AfMark`,
  `af_marks.json` w zapisie – potwierdzone/odrzucone/dodane, pierwszeństwo przed automatem; dane do strojenia).
- `lib/report/` PDF (`pdf_report.dart` pojedynczy zapis, `summary_report.dart` raport zbiorczy z wielu zapisów –
  część tej samej biblioteki), `lib/export/` EDF+/CSV, `lib/alarms/`, `lib/settings/`, `lib/ui/`.
- Kopia zapasowa / eksport wielu zapisów: `lib/recording/backup.dart` (ZIP: `recordings/<zapis>/…` pliki źródłowe,
  `profile.json`, `hrv_morning.json`, `settings.json`, `manifest.json`; przywracanie nie nadpisuje istniejących
  zapisów ani profilu), akcje UI w `lib/ui/backup_actions.dart` (też raport zbiorczy).
- Poranny pomiar HRV: `lib/analysis/hrv_session.dart` (RMSSD z RR opaski, odrzucanie artefaktów > 20% od mediany,
  ocena ln RMSSD względem własnej normy: średnia ± max(0.5 SD, 0.05) z 30 dni, ≥ 5 pomiarów),
  historia `<dane aplikacji>/hrv_morning.json`, ekran `lib/ui/hrv_screen.dart` (1 min wyciszenia + 2/3/5 min).
- Sprawdź rytm: `lib/ui/rhythm_check_screen.dart` (1/2 min zapisu z objawem jako znacznik → ocena + PDF),
  dziennik AF w Trendach (`lib/ui/af_diary_card.dart`, otwiera zapis na napadzie), ostrzeżenie o słabym kontakcie
  (`LiveAnalyzer.contactWarning`: czytelność < 60% przez ≥ 1 min; powiadomienie ciche, co ≥ 30 min),
  stan optymalizacji baterii w Ustawieniach.
- Wygląd: `lib/ui/theme/app_theme.dart` – motyw (granat/morski, czerwień EKG), `AppColors` (kolory semantyczne:
  N/S/V/Q, AF, ok/ostrzeżenie/alarm, papier EKG) i wspólne komponenty (`MetricTile`, `MetricGrid`, `StatusPill`,
  `SectionLabel`). Nie wpisywać kolorów na sztywno w ekranach. Nawigacja dolna: Monitor / Zapisy / Trendy / Ustawienia.
- Zrzuty ekranów bez telefonu: `SCREENSHOTS=<katalog> flutter test test/screenshots_test.dart` (Roboto + ikony
  Material, syntetyczne EKG; bez zmiennej test pominięty). Ikony aplikacji (Android legacy/adaptacyjna/
  monochromatyczna, iOS, ekran startowy): `flutter test tool/icons/icon_test.dart`.
- `tool/` – narzędzia PC: `mitbih_eval.dart`, `train_classifier.dart`, `analyze.dart`, `strips_png.dart`,
  `template_png.dart`, `pdf_demo.dart`; walidacja: `af_eval.dart` (afdb/ltafdb), `st_eval.dart` (edb),
  `rhythm_eval.dart` (epizody rytmu z adnotacji), `mit_strips_png.dart` (paski z baz), `h10_compare.dart`
  (zapisy H10: różnice między dwoma zestawami ustawień – używać przed każdą zmianą domyślnych),
  `rec_summary.dart` (zapis z aplikacji: godzinowo N/S/V/Q, zdarzenia), `rec_strips_png.dart` (paski z zapisu,
  czas w s, mm:ss lub hh.mm.ss), `live_replay.dart` (odtworzenie zapisu przez analizę na żywo – alarmy AF).

## Walidacja (obowiązkowo przy zmianach analizy)
1. `flutter test` (testy syntetyczne + formaty + eksport).
2. MIT-BIH Arrhythmia DB (PhysioNet, ODC-By): pobrać
   `https://physionet.org/static/published-projects/mitdb/mit-bih-arrhythmia-database-1.0.0.zip` poza repo.
   `dart run tool/mitbih_eval.dart <katalog> DS1|DS2 [-q] [klucz=wartość]` – stroić TYLKO na DS1, raportować DS2.
   Wyniki v1.1.0 na DS2: QRS 99.7/99.9, VEB Se 85.2 +P 86.8, SVEB 6.1/28.4 (słabo), AF Se 97.3 Sp 94.7.
   Wyniki v1.2.0 (model DS1 + SVDB) na DS2: QRS 99.7/99.9, VEB 86.2/91.1, SVEB 11.6/38.6, AF 97.5/94.9.
   SVEB na DS2 zaniża rekord 232 (1382 z 1837 S; S to większość pobudzeń, więc RR „lokalny” = RR pobudzeń S);
   bez 232 Se ≈ 24%. Walidacja krzyżowa na SVDB (po pacjentach): S Se 77% +P 63%.
   Wyniki v1.3.0 na DS2: QRS 99.7/99.9, VEB 86.3/91.4, SVEB 11.7/58.5, AF 99.9/93.2 (N→Q 2228 -> 1048 dzięki
   odzyskowi uderzeń `rescueCorr` – tylko jako N, bez fałszywych V/S).
   Wyniki v1.6.0 na DS2: QRS 99.7/99.9, VEB 85.7/92.5, SVEB 11.7/59.0, AF 99.9/93.2; afdb ECG1 Se 83.7% +P 96.6%;
   ltafdb czas AF Se 91.6% Sp 93.2%, 7.1 fałszywych epizodów/dobę.
   Wyniki v1.7.0 na DS2: QRS 99.7/99.9, VEB 85.7/92.5, SVEB 11.3/58.4, AF 99.9/93.2; afdb ECG1 Se 83.8% +P 96.4%
   Sp 97.9%, 62 fałszywe epizody (było 56); ltafdb: walidacja afExtend w toku (wariant przed progiem długości: +10% fałszywych epizodów – przeniesiono za próg); SVT ltafdb Se 19.9%, +P 29.6%,
   19.7 fałszywych/dobę (było 18.9% / 18.1% / 37.4).
   physionet.org bywa zablokowany w chmurze – mirror: https://physionet-open.s3.amazonaws.com/<baza>/1.0.0/
   (lista plików: `?list-type=2&prefix=<baza>/1.0.0/`). Inne bazy (pobierać poza repo):
   - AF: strojone na afdb (oba odprowadzenia), test na ltafdb (1961 h): czas AF Se 91.6% Sp 93.2%,
     6.8 fałszywych epizodów/dobę (było 25.5). afdb ECG1: Se 83.9% +P 96.6% Sp 98.0%.
     Uwaga: afdb 07162 ma w ECG1 QRS ~0.2 mV – wynik silnie zależy od odprowadzenia.
   - ST (edb, połowa strojeniowa/testowa: `awk 'NR%2'` z listy rekordów): epizody Se 63% +P 66% (test).
   - SVT (`rhythm_eval … SVTA svt,svRun`): mitdb Se 65% (było 54%); ltafdb Se 19%, 37 fałszywych/dobę (krótkie
     serie u chorych z AF – słabość klasyfikacji S).
   - Blok AV II°: mitdb 231 5/5 epizodów; ltafdb 0.9 fałszywych/dobę. AFL: Se 7% – wyłączone (`aflCorr=2`).
3. Prawdziwe zapisy H10 użytkownika – zmiany strojone pod MIT-BIH dwukrotnie powodowały fałszywe
   pobudzenia na artefaktach ruchowych H10 (próg szumu `noiseIdxLimit` = 0.024 skalibrowany na H10:
   czyste 0.005–0.018, artefakty ≥ 0.027; reguła usuwania artefaktów niezależna od etykiety).
   Przykładowe zapisy H10 nie są w repo (dane zdrowotne) – poproś użytkownika o eksport, jeśli potrzebne.

## Uczenie modelu
`dart run tool/train_classifier.dart <mitdb> <cache_cech.json> [svdb=<katalog_svdb>]` – 4-krotna walidacja
krzyżowa po pacjentach na DS1 (+ cała SVDB, ~12 min), wybór konfiguracji/epok/progów, zapis
`lib/analysis/beat_model.g.dart`. Potem ocena na DS2. Model v1.2.0 uczony z svdb (aktualny).
Opcje: `incart=<katalog>` (odprowadzenia II i V5, foldy po pacjentach), `aug=1` (kopie z zakłóceniami
typowymi dla opaski), `nKeep=0.35`; progi/epoki wybierane na OOF z DS1. Próba DS1+SVDB+INCART+aug (v1.3.0):
DS2 VEB 87.0/86.2, SVEB 16.7/62.6 – odrzucona (więcej fałszywych V: N→V 372 vs 231).

## Budowanie
- Flutter stable (3.47), Android SDK 36, NDK 28.2, desugaring włączony (flutter_local_notifications).
- `android/gradle.properties`: `kotlin.incremental=false` (projekt i pub-cache na różnych dyskach na Windows).
- `flutter build apk --release` (uniwersalny ~57 MB) lub `--split-per-abi --target-platform android-arm64` (~20 MB,
  mieści się w limicie 30 MB przesyłania plików do użytkownika).
- Podpis: stały klucz `android/keystore/polar-ekg.jks` (w repo prywatnym, hasło w `android/app/build.gradle.kts`)
  – ten sam w CI i na PC, aktualizacje bez utraty danych. Od v1.3.0 (wcześniej klucz debug z PC – jednorazowa
  reinstalacja). Nie zmieniać klucza, bo kolejne wersje nie zainstalują się jako aktualizacja.
- GitHub Actions `.github/workflows/android.yml`: push na main/main-5zheht -> analyze, testy, APK arm64 i
  uniwersalny -> Releases (`v<wersja>-b<100+run>`; z gałęzi innych niż main jako pre-release). Użytkownik pobiera
  APK z GitHub Releases na telefonie.

## Zapisy H10 użytkownika (v1.6.0, 4 zapisy, m.in. noc 8 h; dane poza repo: /home/user/data/h10 w sesji)
- Użytkownik ma napadowe AF. Noc: prawdopodobny krótki napad AF na początku (~22:56, ~142/min, ~33 s) –
  EKG w tym czasie zakłócone, wykryty dopiero z RR opaski (`useDeviceRr`, `_afFromDeviceRr`: okna 32 RR, tylko
  gdzie ≥ 25% pobudzeń Q/szum; odrzucenie przy RR < 0.25/> 2.5 s lub > 1 RR poza 0.5–1.7× mediany; Dash i COSEn).
  RR opaski: `rr.csv` (RR grupowane w pakiety BLE; czas = koniec pakietu); start z meta `started_ms`
  (meta `started` to czas lokalny bez strefy!) lub wiersza `start` w events.csv.
- Fałszywe V/nsVT z utraty kontaktu elektrod (pływająca linia): `wanderLimit` = 1.0 (czyste H10 0.18–0.19,
  artefakty mediana 1.46; DS2 V p99 0.87) i `vContext` = 2 (V bez przedwczesności i pauzy przy Q w ±2 → Q);
  fałszywe V w nocy 238 → 120.
- Analiza na żywo: RR opaski (`addDeviceRr`), zgłasza też epizody AF, które zaczęły się i skończyły między
  przeliczeniami. Odtworzenie nocy: 1 alarm AF (z RR), bez RR – brak; brak fałszywych alarmów AF.
- Rejestrator: punkt kontrolny co 1 min (flush + meta) – przerwany zapis nie traci długości.
- v1.7.0: tachykardia zatokowa 23:02–23:05 nie jest już S/SVT (`sGradual` = 0.9: seria S, w której RR pierwszego
  i poprzedniego > 0.9 × wcześniejszy, bez skoków > 10% i bez pauzy po serii → N; noc S 23:00 292 → 17;
  DS1 S Se 70.3 → 69.4 (rekord 209), +P bez zmian). `afExtend`: AF rozszerzane na sąsiednie uderzenia S/Q
  o RR 0.5–1.8× mediany epizodu (koniec: V lub 3 kolejne N) – napad 22:56 obejmuje teraz 22:56:00–22:56:46
  (wcześniej pierwsze 13 s jako SVT). AF z RR opaski liczy też uderzenia S jako „niepewne EKG”.

## Następne kroki (otwarte)
- Więcej zapisów H10 z potwierdzonymi/oznaczonymi napadami AF; potwierdzić epizod 22:56 z użytkownikiem.
- Personalizacja AF z oznaczeń użytkownika (`af_marks.json`, potwierdzone/odrzucone napady) – gdy będzie ich
  kilka-kilkanaście: progi Dash/COSEn/afPCorr pod użytkownika; bramka szumu (DS2: bez progu szumu VEB Se 94%
  przy tej samej +P) – kalibrować tylko na H10 (`h10_compare.dart`).
- Pobudzenia S: nadal słabo (DS2 Se 12%); niemiarowość zatokowa vs S do sprawdzenia na H10.
- Testy na telefonie użytkownika: połączenie w wersji release, akcelerometr (aktywność/pozycja),
  alarm testowy (pokazuje komunikat, gdy powiadomienia wyłączone), polskie znaki w PDF (Roboto w assets/fonts).
- Budowanie APK w sesji chmurowej Claude wymaga dl.google.com (zablokowane) – używać GitHub Actions.
- iOS: budowanie przez Codemagic (brak Maca), sideload.

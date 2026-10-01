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
  profil osobisty (`personal_profile.dart`, k-NN z ręcznych poprawek), analiza na żywo (`live_analyzer.dart`).
- `lib/report/` PDF, `lib/export/` EDF+/CSV, `lib/alarms/`, `lib/settings/`, `lib/ui/`.
- `tool/` – narzędzia PC: `mitbih_eval.dart`, `train_classifier.dart`, `analyze.dart`, `strips_png.dart`,
  `template_png.dart`, `pdf_demo.dart`.

## Walidacja (obowiązkowo przy zmianach analizy)
1. `flutter test` (testy syntetyczne + formaty + eksport).
2. MIT-BIH Arrhythmia DB (PhysioNet, ODC-By): pobrać
   `https://physionet.org/static/published-projects/mitdb/mit-bih-arrhythmia-database-1.0.0.zip` poza repo.
   `dart run tool/mitbih_eval.dart <katalog> DS1|DS2 [-q] [klucz=wartość]` – stroić TYLKO na DS1, raportować DS2.
   Wyniki v1.1.0 na DS2: QRS 99.7/99.9, VEB Se 85.2 +P 86.8, SVEB 6.1/28.4 (słabo), AF Se 97.3 Sp 94.7.
   Wyniki v1.2.0 (model DS1 + SVDB) na DS2: QRS 99.7/99.9, VEB 86.2/91.1, SVEB 11.6/38.6, AF 97.5/94.9.
   SVEB na DS2 zaniża rekord 232 (1382 z 1837 S; S to większość pobudzeń, więc RR „lokalny” = RR pobudzeń S);
   bez 232 Se ≈ 24%. Walidacja krzyżowa na SVDB (po pacjentach): S Se 77% +P 63%.
   physionet.org bywa zablokowany w chmurze – mirror: https://physionet-open.s3.amazonaws.com/{mitdb,svdb}/1.0.0/
3. Prawdziwe zapisy H10 użytkownika – zmiany strojone pod MIT-BIH dwukrotnie powodowały fałszywe
   pobudzenia na artefaktach ruchowych H10 (próg szumu `noiseIdxLimit` = 0.024 skalibrowany na H10:
   czyste 0.005–0.018, artefakty ≥ 0.027; reguła usuwania artefaktów niezależna od etykiety).
   Przykładowe zapisy H10 nie są w repo (dane zdrowotne) – poproś użytkownika o eksport, jeśli potrzebne.

## Uczenie modelu
`dart run tool/train_classifier.dart <mitdb> <cache_cech.json> [svdb=<katalog_svdb>]` – 4-krotna walidacja
krzyżowa po pacjentach na DS1 (+ cała SVDB, ~12 min), wybór konfiguracji/epok/progów, zapis
`lib/analysis/beat_model.g.dart`. Potem ocena na DS2. Model v1.2.0 uczony z svdb.

## Budowanie
- Flutter stable (3.47), Android SDK 36, NDK 28.2, desugaring włączony (flutter_local_notifications).
- `android/gradle.properties`: `kotlin.incremental=false` (projekt i pub-cache na różnych dyskach na Windows).
- `flutter build apk --release` (uniwersalny ~57 MB) lub `--split-per-abi --target-platform android-arm64` (~20 MB,
  mieści się w limicie 30 MB przesyłania plików do użytkownika). Podpis kluczem debug (użytek własny).

## Następne kroki (otwarte)
- Pobudzenia S: model douczony na svdb (v1.2.0) – sprawdzić na prawdziwych zapisach H10, czy niemiarowość
  zatokowa nie daje fałszywych S (N→S na DS2: 0.6%). Dalej: INCART DB (incartdb, 257 Hz) jako kolejne dane.
- Testy na telefonie użytkownika: połączenie w wersji release, akcelerometr (aktywność/pozycja),
  alarm testowy (pokazuje komunikat, gdy powiadomienia wyłączone), polskie znaki w PDF (Roboto w assets/fonts).
- Budowanie APK w chmurze wymaga dostępu do dl.google.com (Android SDK) w ustawieniach sieci środowiska.
- iOS: budowanie przez Codemagic (brak Maca), sideload.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Profil osobisty użytkownika: wzorce własnych prawidłowych pobudzeń (z dobrych zapisów)
/// i biblioteka pobudzeń oznaczonych ręcznie. Używany przez analizę do:
///  - zastępczego wzorca, gdy w zapisie jest za mało regularnych pobudzeń,
///  - nadpisania etykiety metodą k najbliższych sąsiadów (k-NN) dla pobudzeń
///    bardzo podobnych do oznaczonych przez użytkownika.
class PersonalProfile {
  static const fileName = 'profile.json';
  static const maxExamples = 3000;
  static const maxTemplates = 8;

  final List<Float64List> qrsTemplates; // najnowszy na końcu
  final List<Float64List> wideTemplates;
  final List<Float64List> exampleFeatures;
  final List<int> exampleLabels; // BeatType
  final List<String> exampleSources; // katalog zapisu (do usuwania przy ponownej korekcie)

  PersonalProfile({
    List<Float64List>? qrsTemplates,
    List<Float64List>? wideTemplates,
    List<Float64List>? exampleFeatures,
    List<int>? exampleLabels,
    List<String>? exampleSources,
  })  : qrsTemplates = qrsTemplates ?? [],
        wideTemplates = wideTemplates ?? [],
        exampleFeatures = exampleFeatures ?? [],
        exampleLabels = exampleLabels ?? [],
        exampleSources = exampleSources ?? [];

  bool get hasTemplate => qrsTemplates.isNotEmpty && wideTemplates.isNotEmpty;
  int get examples => exampleLabels.length;

  static File fileIn(Directory docs) => File('${docs.path}/$fileName');

  /// Profil dla katalogu zapisu (`…/recordings/ZAPIS` → `…/profile.json`).
  static Future<PersonalProfile?> loadForRecording(String recordingPath) async {
    final docs = Directory(recordingPath).parent.parent;
    return load(fileIn(docs));
  }

  static Future<PersonalProfile?> load(File f) async {
    if (!await f.exists()) return null;
    try {
      return PersonalProfile.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(File f) async {
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(toJson()));
  }

  void addTemplates(Float64List qrs, Float64List wide) {
    qrsTemplates.add(qrs);
    wideTemplates.add(wide);
    while (qrsTemplates.length > maxTemplates) {
      qrsTemplates.removeAt(0);
      wideTemplates.removeAt(0);
    }
  }

  /// Zastępuje przykłady z danego zapisu nowymi (po ponownej weryfikacji).
  void setExamples(String source, List<Float64List> features, List<int> labels) {
    for (var i = exampleSources.length - 1; i >= 0; i--) {
      if (exampleSources[i] == source) {
        exampleSources.removeAt(i);
        exampleFeatures.removeAt(i);
        exampleLabels.removeAt(i);
      }
    }
    exampleFeatures.addAll(features);
    exampleLabels.addAll(labels);
    exampleSources.addAll(List.filled(labels.length, source));
    while (exampleLabels.length > maxExamples) {
      exampleFeatures.removeAt(0);
      exampleLabels.removeAt(0);
      exampleSources.removeAt(0);
    }
  }

  /// Wzorzec z profilu najbardziej podobny do [probe] (korelacja), lub najnowszy.
  int bestTemplateFor(Float64List? probe) {
    if (probe == null || qrsTemplates.length == 1) return qrsTemplates.length - 1;
    var best = qrsTemplates.length - 1;
    var bestC = -2.0;
    for (var k = 0; k < qrsTemplates.length; k++) {
      final t = qrsTemplates[k];
      if (t.length != probe.length) continue;
      final c = _pearson(t, probe);
      if (c > bestC) {
        bestC = c;
        best = k;
      }
    }
    return best;
  }

  /// k-NN w przestrzeni standaryzowanych cech. Zwraca etykietę, gdy ≥ 4 z 5 najbliższych
  /// sąsiadów ją mają i są bliżej niż [maxDist]; inaczej null.
  int? knnLabel(List<double> x, Float64List mean, Float64List std, {int k = 5, double maxDist = 2.0}) {
    if (exampleLabels.length < k) return null;
    final best = <(double, int)>[];
    for (var e = 0; e < exampleFeatures.length; e++) {
      final f = exampleFeatures[e];
      var d = 0.0;
      for (var i = 0; i < x.length && i < f.length; i++) {
        final z = (x[i] - f[i]) / std[i];
        d += z * z;
        if (best.length == k && d >= best.last.$1) break;
      }
      if (best.length < k || d < best.last.$1) {
        best.add((d, exampleLabels[e]));
        best.sort((a, b) => a.$1.compareTo(b.$1));
        if (best.length > k) best.removeLast();
      }
    }
    final votes = <int, int>{};
    for (final (d, l) in best) {
      if (sqrt(d / x.length) <= maxDist) votes.update(l, (v) => v + 1, ifAbsent: () => 1);
    }
    for (final e in votes.entries) {
      if (e.value >= (k * 0.8).ceil()) return e.key;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'qrs': [for (final t in qrsTemplates) t.map((v) => v.round()).toList()],
        'wide': [for (final t in wideTemplates) t.map((v) => v.round()).toList()],
        'ex_f': [for (final f in exampleFeatures) f.map((v) => double.parse(v.toStringAsPrecision(4))).toList()],
        'ex_l': exampleLabels,
        'ex_s': exampleSources,
      };

  factory PersonalProfile.fromJson(Map<String, dynamic> j) {
    Float64List f(dynamic v) => Float64List.fromList([for (final x in v as List) (x as num).toDouble()]);
    return PersonalProfile(
      qrsTemplates: [for (final t in j['qrs'] as List? ?? []) f(t)],
      wideTemplates: [for (final t in j['wide'] as List? ?? []) f(t)],
      exampleFeatures: [for (final t in j['ex_f'] as List? ?? []) f(t)],
      exampleLabels: (j['ex_l'] as List? ?? []).cast<int>(),
      exampleSources: (j['ex_s'] as List? ?? []).cast<String>(),
    );
  }

  static double _pearson(Float64List a, Float64List b) {
    final n = a.length;
    var ma = 0.0, mb = 0.0;
    for (var i = 0; i < n; i++) {
      ma += a[i];
      mb += b[i];
    }
    ma /= n;
    mb /= n;
    var sab = 0.0, saa = 0.0, sbb = 0.0;
    for (var i = 0; i < n; i++) {
      sab += (a[i] - ma) * (b[i] - mb);
      saa += (a[i] - ma) * (a[i] - ma);
      sbb += (b[i] - mb) * (b[i] - mb);
    }
    return saa == 0 || sbb == 0 ? 0 : sab / sqrt(saa * sbb);
  }
}

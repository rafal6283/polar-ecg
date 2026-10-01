import 'dart:io';
import 'dart:typed_data';

/// Binarny format zapisu (ok. 12× mniejszy niż CSV, szybkie wczytywanie).
///
/// Nagłówek 16 B: magia (4 B: 'PECG' lub 'PACC'), wersja (u8), kanały (u8),
/// częstotliwość [Hz] (u16), parametr (u16: rozdzielczość EKG lub zakres ACC w g), 6 B zarezerwowane.
/// Ramki: znacznik czasu ostatniej próbki z zegara opaski [ns] (u64),
/// liczba próbek (u16), próbki int16 LE (przeplatane kanały) – EKG w µV, ACC w mG.
class BinaryStreamWriter {
  final IOSink _sink;
  final int channels;

  BinaryStreamWriter._(this._sink, this.channels);

  static BinaryStreamWriter create(File f, String magic, {required int fs, required int channels, int param = 0}) {
    final sink = f.openWrite();
    final h = ByteData(16);
    for (var i = 0; i < 4; i++) {
      h.setUint8(i, magic.codeUnitAt(i));
    }
    h.setUint8(4, 1);
    h.setUint8(5, channels);
    h.setUint16(6, fs, Endian.little);
    h.setUint16(8, param, Endian.little);
    sink.add(h.buffer.asUint8List());
    return BinaryStreamWriter._(sink, channels);
  }

  void addFrame(int timestampNs, List<int> samples) {
    final count = samples.length ~/ channels;
    final b = ByteData(10 + samples.length * 2);
    b.setUint64(0, timestampNs, Endian.little);
    b.setUint16(8, count, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      b.setInt16(10 + 2 * i, samples[i].clamp(-32768, 32767), Endian.little);
    }
    _sink.add(b.buffer.asUint8List());
  }

  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }
}

class BinaryFrame {
  final int timestampNs;
  final Int16List samples;
  BinaryFrame(this.timestampNs, this.samples);
}

class BinaryStream {
  final String magic;
  final int channels, fs, param;
  final List<BinaryFrame> frames;
  BinaryStream(this.magic, this.channels, this.fs, this.param, this.frames);

  static Future<BinaryStream?> read(File f) async {
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    if (bytes.length < 16) return null;
    final d = ByteData.sublistView(bytes);
    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    final channels = d.getUint8(5), fs = d.getUint16(6, Endian.little), param = d.getUint16(8, Endian.little);
    final frames = <BinaryFrame>[];
    var off = 16;
    while (off + 10 <= bytes.length) {
      final ts = d.getUint64(off, Endian.little);
      final count = d.getUint16(off + 8, Endian.little);
      final n = count * channels;
      if (off + 10 + 2 * n > bytes.length) break; // urwana ostatnia ramka (np. awaria)
      final s = Int16List(n);
      for (var i = 0; i < n; i++) {
        s[i] = d.getInt16(off + 10 + 2 * i, Endian.little);
      }
      frames.add(BinaryFrame(ts, s));
      off += 10 + 2 * n;
    }
    return BinaryStream(magic, channels, fs, param, frames);
  }
}

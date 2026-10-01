// Minimalny zapis PNG bez zależności (do narzędzi diagnostycznych).
import 'dart:io';
import 'dart:typed_data';

class Img {
  final int w, h;
  final Uint8List px;

  Img(this.w, this.h) : px = Uint8List(w * h * 3)..fillRange(0, w * h * 3, 255);

  void set(int x, int y, List<int> c) {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    final o = (y * w + x) * 3;
    px[o] = c[0];
    px[o + 1] = c[1];
    px[o + 2] = c[2];
  }

  void vline(int x, int y1, int y2, List<int> c) {
    for (var y = y1; y <= y2; y++) {
      set(x, y, c);
    }
  }

  void hline(int x1, int x2, int y, List<int> c) {
    for (var x = x1; x <= x2; x++) {
      set(x, y, c);
    }
  }

  void line(int x1, int y1, int x2, int y2, List<int> c) {
    final dx = (x2 - x1).abs(), dy = (y2 - y1).abs();
    final steps = dx > dy ? dx : dy;
    for (var i = 0; i <= steps; i++) {
      final t = steps == 0 ? 0.0 : i / steps;
      final x = (x1 + (x2 - x1) * t).round(), y = (y1 + (y2 - y1) * t).round();
      set(x, y, c);
      set(x, y + 1, c);
    }
  }

  List<int> png() {
    final raw = BytesBuilder();
    for (var y = 0; y < h; y++) {
      raw.addByte(0);
      raw.add(Uint8List.sublistView(px, y * w * 3, (y + 1) * w * 3));
    }
    final out = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
    void chunk(String type, List<int> data) {
      final body = [...type.codeUnits, ...data];
      out.add(_u32(data.length));
      out.add(body);
      out.add(_u32(_crc(body)));
    }

    chunk('IHDR', [..._u32(w), ..._u32(h), 8, 2, 0, 0, 0]);
    chunk('IDAT', ZLibEncoder().convert(raw.takeBytes()));
    chunk('IEND', []);
    return out.takeBytes();
  }

  static List<int> _u32(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];

  static int _crc(List<int> data) {
    var c = 0xFFFFFFFF;
    for (final b in data) {
      c ^= b;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
    }
    return c ^ 0xFFFFFFFF;
  }
}

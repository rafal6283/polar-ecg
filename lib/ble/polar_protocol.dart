// Parsowanie danych z Polar H10.
//
// EKG: usługa Polar Measurement Data (PMD).
//   Control point FB005C81: komendy start/stop, odpowiedzi przez indikacje.
//   Data FB005C82: ramki z próbkami.
// Ramka danych EKG:
//   [0]     typ pomiaru (0x00 = ECG)
//   [1..8]  timestamp uint64 LE, ns, czas OSTATNIEJ próbki w ramce
//   [9]     typ ramki (0x00 = surowe próbki 3-bajtowe)
//   [10..]  próbki int24 LE w mikrowoltach, 130 Hz
//
// Tętno/RR: standardowa usługa Heart Rate (0x180D / 0x2A37),
// RR w jednostkach 1/1024 s.

import 'dart:typed_data';

const int ecgSampleRate = 130;

class EcgFrame {
  final int sensorTimestampNs; // czas ostatniej próbki
  final List<int> samplesUv;
  final DateTime received;

  EcgFrame(this.sensorTimestampNs, this.samplesUv, this.received);
}

class HrMeasurement {
  final int bpm;
  final List<double> rrMs;
  final bool? skinContact; // null = czujnik nie raportuje
  final DateTime received;

  HrMeasurement(this.bpm, this.rrMs, this.skinContact, this.received);
}

EcgFrame? parseEcgFrame(List<int> data) {
  if (data.length < 10 || data[0] != 0x00) return null;
  final bytes = Uint8List.fromList(data);
  final ts = ByteData.sublistView(bytes).getUint64(1, Endian.little);
  final frameType = bytes[9];
  if (frameType != 0x00) return null; // H10 wysyła EKG tylko jako typ 0
  final samples = <int>[];
  for (var i = 10; i + 2 < bytes.length; i += 3) {
    var v = bytes[i] | (bytes[i + 1] << 8) | (bytes[i + 2] << 16);
    if (v & 0x800000 != 0) v -= 0x1000000;
    samples.add(v);
  }
  return EcgFrame(ts, samples, DateTime.now());
}

HrMeasurement? parseHrMeasurement(List<int> d) {
  if (d.length < 2) return null;
  final flags = d[0];
  var i = 1;
  int bpm;
  if (flags & 0x01 != 0) {
    bpm = d[i] | (d[i + 1] << 8);
    i += 2;
  } else {
    bpm = d[i];
    i += 1;
  }
  bool? contact;
  if (flags & 0x04 != 0) contact = flags & 0x02 != 0;
  if (flags & 0x08 != 0) i += 2; // energy expended
  final rr = <double>[];
  if (flags & 0x10 != 0) {
    while (i + 1 < d.length) {
      rr.add((d[i] | (d[i + 1] << 8)) * 1000.0 / 1024.0);
      i += 2;
    }
  }
  return HrMeasurement(bpm, rr, contact, DateTime.now());
}

/// Start EKG: 130 Hz (0x0082), rozdzielczość 14 bit (0x000E).
const List<int> pmdStartEcg = [0x02, 0x00, 0x00, 0x01, 0x82, 0x00, 0x01, 0x01, 0x0E, 0x00];
const List<int> pmdStopEcg = [0x03, 0x00];

/// Start akcelerometru: 25 Hz, 16 bit, zakres ±8 g.
const int accSampleRate = 25;
const List<int> pmdStartAcc = [
  0x02, 0x02, //
  0x00, 0x01, accSampleRate, 0x00, // częstotliwość
  0x01, 0x01, 0x10, 0x00, // rozdzielczość 16 bit
  0x02, 0x01, 0x08, 0x00, // zakres 8 g
];
const List<int> pmdStopAcc = [0x03, 0x02];

/// Ramka akcelerometru: próbki x,y,z w mG (tysięcznych g).
class AccFrame {
  final int sensorTimestampNs; // czas ostatniej próbki
  final List<int> xyz; // przeplatane x0,y0,z0,x1,...
  final DateTime received;

  AccFrame(this.sensorTimestampNs, this.xyz, this.received);

  int get count => xyz.length ~/ 3;
}

/// Ramka ACC: [0]=0x02, [1..8] znacznik czasu, [9] typ ramki
/// (bit 7 = kompresja delta; 0/1/2 = 1/2/3 bajty na oś), dalej próbki.
AccFrame? parseAccFrame(List<int> data) {
  if (data.length < 10 || data[0] != 0x02) return null;
  final bytes = Uint8List.fromList(data);
  final ts = ByteData.sublistView(bytes).getUint64(1, Endian.little);
  final frameType = bytes[9];
  final compressed = frameType & 0x80 != 0;
  final width = (frameType & 0x7F) + 1; // bajty na oś
  final out = <int>[];
  int readSigned(int off, int nBytes) {
    var v = 0;
    for (var k = 0; k < nBytes; k++) {
      v |= bytes[off + k] << (8 * k);
    }
    final bits = 8 * nBytes;
    if (v & (1 << (bits - 1)) != 0) v -= 1 << bits;
    return v;
  }

  if (!compressed) {
    for (var i = 10; i + 3 * width <= bytes.length; i += 3 * width) {
      for (var c = 0; c < 3; c++) {
        out.add(readSigned(i + c * width, width));
      }
    }
    return AccFrame(ts, out, DateTime.now());
  }

  // Kompresja delta (jak w Polar BLE SDK): próbka odniesienia (16 bit/oś),
  // potem bloki [szerokość delty w bitach][liczba próbek][dane bitowe LSB-first].
  var off = 10;
  if (off + 6 > bytes.length) return null;
  final ref = [for (var c = 0; c < 3; c++) readSigned(off + 2 * c, 2)];
  off += 6;
  out.addAll(ref);
  final cur = [...ref];
  while (off + 2 <= bytes.length) {
    final deltaBits = bytes[off], count = bytes[off + 1];
    off += 2;
    if (deltaBits == 0 || count == 0) break;
    final totalBits = deltaBits * 3 * count;
    final nBytes = (totalBits + 7) ~/ 8;
    if (off + nBytes > bytes.length) break;
    var bitPos = 0;
    int readBits() {
      var v = 0;
      for (var b = 0; b < deltaBits; b++) {
        final byte = bytes[off + ((bitPos + b) >> 3)];
        if ((byte >> ((bitPos + b) & 7)) & 1 == 1) v |= 1 << b;
      }
      bitPos += deltaBits;
      if (v & (1 << (deltaBits - 1)) != 0) v -= 1 << deltaBits;
      return v;
    }

    for (var s = 0; s < count; s++) {
      for (var c = 0; c < 3; c++) {
        cur[c] += readBits();
        out.add(cur[c]);
      }
    }
    off += nBytes;
  }
  return AccFrame(ts, out, DateTime.now());
}

String pmdErrorText(int code) {
  const errors = {
    0: 'OK',
    1: 'nieprawidłowy kod operacji',
    2: 'nieprawidłowy typ pomiaru',
    3: 'pomiar nieobsługiwany',
    4: 'nieprawidłowa długość',
    5: 'nieprawidłowy parametr',
    6: 'pomiar już trwa',
    7: 'nieprawidłowa rozdzielczość',
    8: 'nieprawidłowa częstotliwość',
    9: 'nieprawidłowy zakres',
    10: 'nieprawidłowe MTU',
    11: 'nieprawidłowa liczba kanałów',
    12: 'nieprawidłowy stan',
    13: 'urządzenie się ładuje',
  };
  return errors[code] ?? 'błąd $code';
}

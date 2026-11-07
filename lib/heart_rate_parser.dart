/// Parser for the Bluetooth SIG Heart Rate Measurement characteristic (0x2A37).
library;

import 'dart:typed_data';

enum SensorContact { notSupported, notDetected, detected }

class HeartRateSample {
  const HeartRateSample({
    required this.bpm,
    required this.contact,
    this.energyKj,
    this.rrMs = const [],
  });

  final int bpm;
  final SensorContact contact;
  final int? energyKj;

  /// Intervals between beats, in milliseconds.
  final List<double> rrMs;
}

/// Layout: a flags byte, then heart rate, then optional energy and RR intervals.
///
/// Flags: bit 0 selects a 16-bit heart rate, bit 2 says contact detection is
/// supported, bit 1 says contact is detected, bit 3 adds energy expended, and
/// bit 4 adds RR intervals in units of 1/1024 second.
HeartRateSample parseHeartRateMeasurement(List<int> value) {
  if (value.length < 2) {
    throw FormatException('Measurement too short: ${value.length} bytes');
  }
  final data = ByteData.sublistView(Uint8List.fromList(value));
  final flags = data.getUint8(0);
  var offset = 1;

  final int bpm;
  if (flags & 0x01 != 0) {
    if (value.length < offset + 2) {
      throw const FormatException('Missing 16-bit heart rate');
    }
    bpm = data.getUint16(offset, Endian.little);
    offset += 2;
  } else {
    bpm = data.getUint8(offset);
    offset += 1;
  }

  final SensorContact contact;
  if (flags & 0x04 == 0) {
    contact = SensorContact.notSupported;
  } else {
    contact = flags & 0x02 != 0 ? SensorContact.detected : SensorContact.notDetected;
  }

  int? energy;
  if (flags & 0x08 != 0) {
    if (value.length < offset + 2) {
      throw const FormatException('Missing energy expended field');
    }
    energy = data.getUint16(offset, Endian.little);
    offset += 2;
  }

  final rr = <double>[];
  if (flags & 0x10 != 0) {
    if ((value.length - offset).isOdd) {
      throw const FormatException('RR interval field has an odd length');
    }
    for (; offset < value.length; offset += 2) {
      rr.add(data.getUint16(offset, Endian.little) * 1000.0 / 1024.0);
    }
  }
  return HeartRateSample(bpm: bpm, contact: contact, energyKj: energy, rrMs: rr);
}

import 'package:flutter_test/flutter_test.dart';
import 'package:heart_monitor/heart_rate_parser.dart';
import 'package:heart_monitor/session.dart';
import 'package:heart_monitor/sources.dart';

void main() {
  group('Heart Rate Measurement parser', () {
    test('8-bit heart rate', () {
      final s = parseHeartRateMeasurement([0x00, 72]);
      expect(s.bpm, 72);
      expect(s.contact, SensorContact.notSupported);
      expect(s.rrMs, isEmpty);
      expect(s.energyKj, isNull);
    });

    test('16-bit heart rate is little endian', () {
      expect(parseHeartRateMeasurement([0x01, 0x2C, 0x01]).bpm, 300);
    });

    test('contact bits', () {
      expect(parseHeartRateMeasurement([0x06, 70]).contact, SensorContact.detected);
      expect(parseHeartRateMeasurement([0x04, 70]).contact, SensorContact.notDetected);
      expect(parseHeartRateMeasurement([0x02, 70]).contact, SensorContact.notSupported);
    });

    test('energy expended', () {
      expect(parseHeartRateMeasurement([0x08, 70, 0x10, 0x01]).energyKj, 272);
    });

    test('RR intervals use units of 1/1024 second', () {
      final s = parseHeartRateMeasurement([0x10, 80, 0x00, 0x04, 0x00, 0x02]);
      expect(s.rrMs, [1000.0, 500.0]);
    });

    test('all fields together, in spec order', () {
      final s = parseHeartRateMeasurement([0x1F, 0x50, 0x00, 0x05, 0x00, 0x00, 0x04]);
      expect(s.bpm, 80);
      expect(s.contact, SensorContact.detected);
      expect(s.energyKj, 5);
      expect(s.rrMs, [1000.0]);
    });

    test('malformed frames raise instead of returning garbage', () {
      expect(() => parseHeartRateMeasurement([0x00]), throwsFormatException);
      expect(() => parseHeartRateMeasurement([0x01, 70]), throwsFormatException);
      expect(() => parseHeartRateMeasurement([0x08, 70, 1]), throwsFormatException);
      expect(() => parseHeartRateMeasurement([0x10, 70, 1, 2, 3]), throwsFormatException);
    });
  });

  group('Session', () {
    final t0 = DateTime(2026);
    HeartRateSample hr(int bpm, {List<double> rr = const [], SensorContact c = SensorContact.detected}) => HeartRateSample(bpm: bpm, contact: c, rrMs: rr);

    test('min, max and average', () {
      final s = HeartRateSession(maxHeartRate: 200);
      for (final (i, bpm) in [100, 120, 140].indexed) {
        s.add(hr(bpm), t0.add(Duration(seconds: i)));
      }
      expect((s.minimum, s.maximum, s.average, s.current), (100, 140, 120, 140));
    });

    test('readings without skin contact are ignored', () {
      final s = HeartRateSession(maxHeartRate: 200);
      s.add(hr(0), t0);
      s.add(hr(90, c: SensorContact.notDetected), t0);
      expect(s.samples, 0);
    });

    test('zones follow the share of maximum heart rate', () {
      final s = HeartRateSession(maxHeartRate: 200);
      expect(s.zoneFor(99), isNull);
      expect(s.zoneFor(100), 0);
      expect(s.zoneFor(130), 1);
      expect(s.zoneFor(150), 2);
      expect(s.zoneFor(170), 3);
      expect(s.zoneFor(180), 4);
      expect(s.zoneFor(220), 4);
    });

    test('time across a dropped connection does not count toward a zone', () {
      final s = HeartRateSession(maxHeartRate: 200);
      s.add(hr(150), t0);
      s.add(hr(150), t0.add(const Duration(seconds: 1)));
      s.add(hr(150), t0.add(const Duration(minutes: 5)));
      expect(s.zoneTime[2], const Duration(seconds: 1));
    });

    test('RMSSD on known intervals, with artefacts removed', () {
      final s = HeartRateSession(maxHeartRate: 200);
      s.add(hr(70, rr: [800, 810, 800, 3000, 100, 810]), t0);
      expect(s.rmssd, closeTo(10, 1e-9));
      expect(s.rejectedRr, 2);
    });

    test('signal is lost after the timeout and comes back with data', () {
      final s = HeartRateSession(maxHeartRate: 200);
      expect(s.isSignalLost(t0), isFalse);
      s.add(hr(90), t0);
      expect(s.isSignalLost(t0.add(const Duration(seconds: 3))), isFalse);
      expect(s.isSignalLost(t0.add(const Duration(seconds: 6))), isTrue);
    });
  });

  test('the simulator emits frames the real parser accepts, with plausible values', () {
    final source = SimulatedSource();
    final samples = source.history(1800);
    expect(samples.length, 1800);
    for (final s in samples) {
      expect(s.bpm, inInclusiveRange(60, 180));
      expect(s.contact, SensorContact.detected);
      expect(s.rrMs.single, inInclusiveRange(300, 1100));
    }
  });
}

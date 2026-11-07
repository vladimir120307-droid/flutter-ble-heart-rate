import 'dart:math';

import 'heart_rate_parser.dart';

/// Rolling statistics for one workout. Pure Dart, so it is fully unit tested.
class HeartRateSession {
  HeartRateSession({required this.maxHeartRate, this.staleAfter = const Duration(seconds: 5)});

  final int maxHeartRate;
  final Duration staleAfter;

  final List<int> bpmHistory = [];
  final List<double> _rr = [];
  final List<Duration> zoneTime = List.filled(5, Duration.zero);
  DateTime? _last;
  int _min = 0, _max = 0, _sum = 0;
  int rejectedRr = 0;

  int get samples => bpmHistory.length;
  int get current => bpmHistory.isEmpty ? 0 : bpmHistory.last;
  int get minimum => _min;
  int get maximum => _max;
  int get average => samples == 0 ? 0 : (_sum / samples).round();

  void add(HeartRateSample sample, DateTime at) {
    // Sensors send 0 while they look for skin contact, and that is not a heart rate.
    if (sample.bpm <= 0 || sample.contact == SensorContact.notDetected) {
      return;
    }
    if (_last != null) {
      final gap = at.difference(_last!);
      // Time across a dropped connection doesn't count toward any zone.
      if (gap > Duration.zero && gap <= staleAfter) {
        final zone = zoneFor(sample.bpm);
        if (zone != null) zoneTime[zone] += gap;
      }
    }
    _last = at;
    bpmHistory.add(sample.bpm);
    _sum += sample.bpm;
    _min = samples == 1 ? sample.bpm : min(_min, sample.bpm);
    _max = max(_max, sample.bpm);
    for (final rr in sample.rrMs) {
      // A beat outside 30 to 220 bpm is a sensor artefact.
      if (rr < 272 || rr > 2000) {
        rejectedRr++;
      } else {
        _rr.add(rr);
      }
    }
    if (_rr.length > 300) _rr.removeRange(0, _rr.length - 300);
  }

  /// Zones by share of maximum heart rate: 50-60, 60-70, 70-80, 80-90 and 90 up.
  int? zoneFor(int bpm) {
    final share = bpm / maxHeartRate;
    if (share < 0.5) return null;
    return min(((share - 0.5) * 10).floor(), 4);
  }

  /// Short-term heart rate variability from the stored beat intervals.
  double? get rmssd {
    if (_rr.length < 2) return null;
    var sum = 0.0;
    for (var i = 1; i < _rr.length; i++) {
      final diff = _rr[i] - _rr[i - 1];
      sum += diff * diff;
    }
    return sqrt(sum / (_rr.length - 1));
  }

  bool isSignalLost(DateTime now) => _last != null && now.difference(_last!) > staleAfter;
}

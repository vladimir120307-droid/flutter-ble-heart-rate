import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'heart_rate_parser.dart';
import 'session.dart';
import 'sources.dart';

/// Flutter builds use the simulator unless started with --dart-define=SENSOR=ble.
const useBle = String.fromEnvironment('SENSOR') == 'ble';

void main() => runApp(const HeartMonitorApp());

const zoneColours = [Color(0xFF7FA6C9), Color(0xFF4F9D7E), Color(0xFFE0B13F), Color(0xFFE07F3F), Color(0xFFCF3F3F)];
const zoneNames = ['Very light', 'Light', 'Moderate', 'Hard', 'Maximum'];

class HeartMonitorApp extends StatelessWidget {
  const HeartMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Heart Rate Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFFCF3F3F), useMaterial3: true),
      home: const MonitorScreen(),
    );
  }
}

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key, this.source});

  final HeartRateSource? source;

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  late final HeartRateSource _source;
  final _session = HeartRateSession(maxHeartRate: 190);
  StreamSubscription<HeartRateSample>? _samples;
  StreamSubscription<LinkState>? _link;
  Timer? _clock;
  LinkState _state = LinkState.searching;

  @override
  void initState() {
    super.initState();
    _source = widget.source ?? (useBle ? BleSource() : SimulatedSource());
    final source = _source;
    if (source is SimulatedSource) {
      final start = DateTime.now().subtract(const Duration(seconds: 720));
      final past = source.history(720);
      for (var i = 0; i < past.length; i++) {
        _session.add(past[i], start.add(Duration(seconds: i)));
      }
    }
    _samples = _source.samples.listen((s) => setState(() => _session.add(s, DateTime.now())));
    _link = _source.state.listen((s) => setState(() => _state = s));
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    _source.start();
  }

  @override
  void dispose() {
    _samples?.cancel();
    _link?.cancel();
    _clock?.cancel();
    _source.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lost = _session.isSignalLost(DateTime.now());
    return Scaffold(
      backgroundColor: const Color(0xFFF4F4F1),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _Header(label: _source.label, state: _state, lost: lost),
                const SizedBox(height: 12),
                _Reading(session: _session, lost: lost),
                const SizedBox(height: 12),
                _Panel(title: 'Last 10 minutes', child: SizedBox(height: 170, child: _Chart(_session))),
                const SizedBox(height: 12),
                _Panel(title: 'Time in zones', child: _Zones(_session)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.label, required this.state, required this.lost});

  final String label;
  final LinkState state;
  final bool lost;

  @override
  Widget build(BuildContext context) {
    final text = lost ? 'Signal lost' : switch (state) {
      LinkState.searching => 'Searching',
      LinkState.connecting => 'Connecting',
      LinkState.connected => 'Connected',
      LinkState.reconnecting => 'Reconnecting',
    };
    final good = !lost && state == LinkState.connected;
    return Row(
      children: [
        const Expanded(child: Text('Heart Rate', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
        Chip(
          avatar: Icon(good ? Icons.bluetooth_connected : Icons.bluetooth_searching, size: 18, color: good ? const Color(0xFF14713D) : const Color(0xFFB3341F)),
          label: Text('$label: $text'),
        ),
      ],
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading({required this.session, required this.lost});

  final HeartRateSession session;
  final bool lost;

  @override
  Widget build(BuildContext context) {
    final zone = session.zoneFor(session.current);
    final rmssd = session.rmssd;
    return _Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(lost ? '--' : '${session.current}',
              key: const Key('bpm'),
              style: TextStyle(fontSize: 76, height: 1, fontWeight: FontWeight.w700, color: zone == null ? Colors.black87 : zoneColours[zone])),
          const Padding(padding: EdgeInsets.only(left: 6, bottom: 8), child: Text('bpm', style: TextStyle(fontSize: 18, color: Colors.black54))),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _Stat('Average', '${session.average}'),
              _Stat('Min / Max', '${session.minimum} / ${session.maximum}'),
              _Stat('HRV (RMSSD)', rmssd == null ? '-' : '${rmssd.toStringAsFixed(0)} ms'),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.name, this.value);

  final String name, value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$name  ', style: const TextStyle(color: Colors.black54, fontSize: 13)),
          TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        ])),
      );
}

class _Panel extends StatelessWidget {
  const _Panel({this.title, required this.child});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFE1E0D9))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(title!, style: const TextStyle(fontWeight: FontWeight.w600))),
            child,
          ],
        ),
      );
}

class _Zones extends StatelessWidget {
  const _Zones(this.session);

  final HeartRateSession session;

  @override
  Widget build(BuildContext context) {
    final longest = session.zoneTime.map((d) => d.inSeconds).reduce(max);
    return Column(
      children: [
        for (var i = 4; i >= 0; i--)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(width: 78, child: Text(zoneNames[i], style: const TextStyle(fontSize: 13))),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: longest == 0 ? 0 : session.zoneTime[i].inSeconds / longest,
                      minHeight: 12,
                      backgroundColor: const Color(0xFFEFEEE8),
                      valueColor: AlwaysStoppedAnimation(zoneColours[i]),
                    ),
                  ),
                ),
                SizedBox(width: 56, child: Text(_clock(session.zoneTime[i]), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
              ],
            ),
          ),
      ],
    );
  }

  String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _Chart extends StatelessWidget {
  const _Chart(this.session);

  final HeartRateSession session;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _ChartPainter(session), size: Size.infinite);
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.session);

  final HeartRateSession session;

  @override
  void paint(Canvas canvas, Size size) {
    final history = session.bpmHistory;
    if (history.length < 2) return;
    final points = history.sublist(max(0, history.length - 600));
    const lo = 50.0, hi = 190.0;
    double y(num bpm) => size.height - (bpm - lo) / (hi - lo) * size.height;
    final grid = Paint()..color = const Color(0xFFEDECE6);
    for (var bpm = 60; bpm <= 180; bpm += 40) {
      canvas.drawLine(Offset(28, y(bpm)), Offset(size.width, y(bpm)), grid);
      TextPainter(text: TextSpan(text: '$bpm', style: const TextStyle(color: Colors.black54, fontSize: 11)), textDirection: TextDirection.ltr)
        ..layout()
        ..paint(canvas, Offset(0, y(bpm) - 7));
    }
    final path = Path();
    final step = (size.width - 28) / (points.length - 1);
    for (var i = 0; i < points.length; i++) {
      final dx = 28 + i * step;
      i == 0 ? path.moveTo(dx, y(points[i])) : path.lineTo(dx, y(points[i]));
    }
    canvas.drawPath(path, Paint()
      ..color = const Color(0xFFCF3F3F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

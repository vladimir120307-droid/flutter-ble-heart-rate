import 'dart:async';
import 'dart:math';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'heart_rate_parser.dart';

enum LinkState { searching, connecting, connected, reconnecting }

abstract class HeartRateSource {
  Stream<HeartRateSample> get samples;
  Stream<LinkState> get state;
  String get label;
  Future<void> start();
  Future<void> stop();
}

/// Builds the same bytes a real chest strap sends, so the demo runs through the real parser.
class SimulatedSource implements HeartRateSource {
  SimulatedSource({int seed = 7, this.period = const Duration(seconds: 1)}) : _rng = Random(seed);

  final Random _rng;
  final Duration period;
  final _samples = StreamController<HeartRateSample>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  Timer? _timer;
  int _second = 0;

  @override
  Stream<HeartRateSample> get samples => _samples.stream;
  @override
  Stream<LinkState> get state => _state.stream;
  @override
  String get label => 'Simulated sensor';

  /// Warm-up, then intervals, then cool-down, repeating every 30 minutes.
  double targetBpm(int second) {
    final t = second % 1800;
    if (t < 300) return 72 + 70 * t / 300;
    if (t < 1500) return 142 + 26 * sin((t - 300) / 120 * pi);
    return 142 - 62 * (t - 1500) / 300;
  }

  List<int> frame(int second) {
    final bpm = (targetBpm(second) + _rng.nextDouble() * 3 - 1.5).round();
    final beat = 60000.0 / bpm;
    final rr = ((beat + _rng.nextDouble() * 24 - 12) * 1024 / 1000).round();
    return [0x16, bpm & 0xFF, rr & 0xFF, (rr >> 8) & 0xFF];
  }

  /// A warm start, so the screen isn't empty on launch.
  List<HeartRateSample> history(int seconds) {
    final out = [for (var i = 0; i < seconds; i++) parseHeartRateMeasurement(frame(i))];
    _second = seconds;
    return out;
  }

  @override
  Future<void> start() async {
    _state.add(LinkState.connected);
    _timer = Timer.periodic(period, (_) => _samples.add(parseHeartRateMeasurement(frame(_second++))));
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    await _samples.close();
    await _state.close();
  }
}

/// A real sensor over BLE: finds the Heart Rate service, subscribes and reconnects after a drop.
class BleSource implements HeartRateSource {
  static final Guid _service = Guid('180D');
  static final Guid _measurement = Guid('2A37');

  final _samples = StreamController<HeartRateSample>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  StreamSubscription<List<ScanResult>>? _scan;
  StreamSubscription<BluetoothConnectionState>? _connection;
  StreamSubscription<List<int>>? _values;
  BluetoothDevice? _device;
  bool _stopped = false;
  int _attempt = 0;

  @override
  Stream<HeartRateSample> get samples => _samples.stream;
  @override
  Stream<LinkState> get state => _state.stream;
  @override
  String get label => 'BLE sensor';

  @override
  Future<void> start() async {
    _state.add(LinkState.searching);
    _scan = FlutterBluePlus.onScanResults.listen((results) async {
      if (results.isEmpty || _device != null) return;
      _device = results.first.device;
      await FlutterBluePlus.stopScan();
      await _connect();
    });
    await FlutterBluePlus.startScan(withServices: [_service]);
  }

  Future<void> _connect() async {
    final device = _device;
    if (device == null || _stopped) return;
    _state.add(_attempt == 0 ? LinkState.connecting : LinkState.reconnecting);
    await _connection?.cancel();
    _connection = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && _attempt >= 0 && !_stopped) {
        _retry();
      }
    });
    try {
      // The package's license terms depend on the organisation. Pick the right one for production.
      await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 15));
      for (final service in await device.discoverServices()) {
        if (service.uuid != _service) continue;
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid != _measurement) continue;
          await _values?.cancel();
          _values = characteristic.onValueReceived.listen(_onValue);
          await characteristic.setNotifyValue(true);
          _attempt = 0;
          _state.add(LinkState.connected);
          return;
        }
      }
    } on FlutterBluePlusException {
      _retry();
    }
  }

  void _onValue(List<int> value) {
    try {
      _samples.add(parseHeartRateMeasurement(value));
    } on FormatException {
      // One corrupt notification must not end the session.
    }
  }

  void _retry() {
    _attempt++;
    final delay = Duration(seconds: min(30, 1 << min(_attempt, 5)));
    Timer(delay, _connect);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    await FlutterBluePlus.stopScan();
    await _scan?.cancel();
    await _values?.cancel();
    await _connection?.cancel();
    await _device?.disconnect();
    await _samples.close();
    await _state.close();
  }
}

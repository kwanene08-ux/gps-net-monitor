import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'gps_freshness.dart';

@pragma('vm:entry-point')
void startCallback() =>
    FlutterForegroundTask.setTaskHandler(GpsMonitorTaskHandler());

class GpsMonitorTaskHandler extends TaskHandler {
  Position? _lastAccepted;
  DateTime? _lastNetRead;
  DateTime? _lastGpsStartAttempt;
  String _network = 'N/A';
  DateTime? _lastAlert;
  StreamSubscription<Position>? _gpsSubscription;
  bool _gpsStarting = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _startGpsStream();
    await _publish(null);
  }

  Future<void> _startGpsStream() async {
    if (_gpsSubscription != null || _gpsStarting) return;

    final now = DateTime.now();
    if (_lastGpsStartAttempt != null &&
        now.difference(_lastGpsStartAttempt!) <
            const Duration(seconds: 5)) {
      return;
    }

    _lastGpsStartAttempt = now;
    _gpsStarting = true;

    try {
      final stream = Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 2),
        ),
      );

      _gpsSubscription = stream.listen(
        (Position position) {
          unawaited(_handleStreamPosition(position));
        },
        onError: (Object error) {
          unawaited(_handleGpsStreamError());
        },
        onDone: () {
          unawaited(_handleGpsStreamError());
        },
      );
    } catch (_) {
      _gpsSubscription = null;
    } finally {
      _gpsStarting = false;
    }
  }

  Future<void> _handleStreamPosition(Position position) async {
    final accepted = await _acceptPosition(position);
    if (accepted != null) {
      await _publish(accepted);
    }
  }

  Future<void> _handleGpsStreamError() async {
    final subscription = _gpsSubscription;
    if (subscription == null) return;

    _gpsSubscription = null;
    await subscription.cancel();
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // ถ้า Stream หยุด ให้ลองเริ่มใหม่โดยเว้นระยะอย่างน้อย 5 วินาที
    if (_gpsSubscription == null) {
      await _startGpsStream();
    }

    // ตรวจเครือข่ายแยกจาก GPS ทุกประมาณ 3 วินาที
    if (_lastNetRead == null ||
        timestamp.difference(_lastNetRead!) >=
            const Duration(seconds: 3)) {
      try {
        final result = await Connectivity().checkConnectivity();
        _network = result.map((item) => item.name).join(', ');
        if (_network.isEmpty) _network = 'none';
      } catch (_) {
        _network = 'N/A';
      }
      _lastNetRead = DateTime.now();
    }

    // ส่งข้อมูลล่าสุดพร้อมอายุจริง ไม่สร้างตำแหน่งใหม่จากข้อมูลเก่า
    await _publish(_lastAccepted);
  }

  Future<Position?> _acceptPosition(Position? position) async {
    if (position == null ||
        !position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude < -90 ||
        position.latitude > 90 ||
        position.longitude < -180 ||
        position.longitude > 180 ||
        !position.accuracy.isFinite ||
        position.accuracy < 0) {
      return null;
    }

    final last = _lastAccepted;

    if (last != null) {
      final seconds =
          position.timestamp.difference(last.timestamp).inMilliseconds /
              1000.0;

      if (seconds <= 0) return null;

      // ปฏิเสธการกระโดดเฉพาะเมื่อทั้งตำแหน่งเดิมและใหม่แม่นยำ <= 10 เมตร
      // ตำแหน่งที่ Accuracy แย่ยังแสดงได้ แต่ไม่เชื่อถือสำหรับความเร็ว
      if (last.accuracy <= 10 && position.accuracy <= 10) {
        final distance = Geolocator.distanceBetween(
          last.latitude,
          last.longitude,
          position.latitude,
          position.longitude,
        );

        if (distance / seconds > 60) {
          await _alertOnce('GPS jump rejected');
          return null;
        }
      }
    }

    _lastAccepted = position;
    return position;
  }

  Future<void> _publish(Position? position) async {
    final now = DateTime.now();
    final fixTime = position?.timestamp;
    final ageSeconds = GpsFreshness.ageSeconds(fixTime, now);
    final isFresh = GpsFreshness.isFresh(ageSeconds);

    final speedIsReliable =
        GpsFreshness.canUseSpeed(ageSeconds) &&
        position != null &&
        position.accuracy.isFinite &&
        position.accuracy <= 10 &&
        position.speed.isFinite &&
        position.speed >= 0 &&
        position.speedAccuracy.isFinite &&
        position.speedAccuracy <= 1.5;

    final speedKmh = speedIsReliable
        ? (position.speed < 0.55 ? 0.0 : position.speed * 3.6)
        : null;

    final data = <String, dynamic>{
      'accuracy': position?.accuracy,
      'latitude': position?.latitude,
      'longitude': position?.longitude,
      'speedKmh': speedKmh,
      'provider': 'Android Location API',
      'network': _network,
      'timestamp': now.toIso8601String(),
      'fixTimestamp': fixTime?.toIso8601String(),
      'ageSeconds': ageSeconds,
      'gpsFresh': isFresh,
      'gpsStatus': GpsFreshness.status(
        ageSeconds: ageSeconds,
        accuracy: position?.accuracy,
      ),
    };

    FlutterForegroundTask.sendDataToMain(data);

    final accuracyText = position == null
        ? 'N/A'
        : '±${position.accuracy.toStringAsFixed(1)} ม.';
    final ageText = ageSeconds == null
        ? 'ไม่มีข้อมูล'
        : '${ageSeconds.toStringAsFixed(1)}s';

    await FlutterForegroundTask.updateService(
      notificationTitle: 'GPS Net Monitor',
      notificationText:
          'GPS $accuracyText | อายุข้อมูล $ageText | $_network',
    );
  }

  Future<void> _alertOnce(String message) async {
    final now = DateTime.now();

    if (_lastAlert != null &&
        now.difference(_lastAlert!) < const Duration(seconds: 30)) {
      return;
    }

    _lastAlert = now;

    FlutterForegroundTask.sendDataToMain({
      'event': 'gps_jump_rejected',
      'message': message,
      'timestamp': now.toIso8601String(),
    });
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    final subscription = _gpsSubscription;
    _gpsSubscription = null;
    await subscription?.cancel();

    FlutterForegroundTask.sendDataToMain({
      'event': 'service_destroyed',
    });
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      FlutterForegroundTask.stopService();
    }
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }
}

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

@pragma('vm:entry-point')
void startCallback() =>
    FlutterForegroundTask.setTaskHandler(GpsMonitorTaskHandler());

class GpsMonitorTaskHandler extends TaskHandler {
  Position? _lastAccepted;
  DateTime? _lastNetRead;
  String _network = 'N/A';
  DateTime? _lastAlert;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _publish(null);
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    Position? p;

    try {
      p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        forceAndroidLocationManager: true,
        timeLimit: const Duration(seconds: 5),
      );
    } catch (_) {
      // หากอ่าน GPS ไม่สำเร็จ ให้ใช้พิกัดเดิมได้
      // แต่จะระบุอายุข้อมูลและไม่แสดงความเร็วเสมือนเป็นข้อมูลสด
    }

    if (p != null && p.accuracy <= 100) {
      final last = _lastAccepted;

      if (last != null) {
        final seconds =
            p.timestamp.difference(last.timestamp).inMilliseconds / 1000.0;

        final distance = Geolocator.distanceBetween(
          last.latitude,
          last.longitude,
          p.latitude,
          p.longitude,
        );

        // ตรวจเฉพาะเมื่อเวลาของตำแหน่งเพิ่มขึ้นจริง
        if (seconds > 0 && distance / seconds > 60) {
          await _alertOnce('GPS jump rejected');
          p = null;
        } else if (seconds <= 0) {
          p = null;
        }
      }

      if (p != null) {
        _lastAccepted = p;
      }
    } else {
      p = null;
    }

    if (_lastNetRead == null ||
        timestamp.difference(_lastNetRead!) >=
            const Duration(seconds: 3)) {
      try {
        final c = await Connectivity().checkConnectivity();
        _network = c.map((e) => e.name).join(', ');
        if (_network.isEmpty) _network = 'none';
      } catch (_) {
        _network = 'N/A';
      }
      _lastNetRead = timestamp;
    }

    await _publish(p ?? _lastAccepted);
  }

  Future<void> _publish(Position? p) async {
    final now = DateTime.now();
    final fixTime = p?.timestamp;
    final ageSeconds = fixTime == null
        ? null
        : math.max(0, now.difference(fixTime).inSeconds);

    final isFresh = ageSeconds != null && ageSeconds <= 10;

    final data = <String, dynamic>{
      'accuracy': p?.accuracy,
      'latitude': p?.latitude,
      'longitude': p?.longitude,
      'speedKmh': isFresh && p != null
          ? math.max(0, p.speed * 3.6)
          : null,
      'provider': 'gps',
      'network': _network,
      'timestamp': now.toIso8601String(),
      'fixTimestamp': fixTime?.toIso8601String(),
      'ageSeconds': ageSeconds,
      'gpsFresh': isFresh,
      'gpsStatus': p == null
          ? 'ไม่มีข้อมูล GPS'
          : isFresh
              ? 'ข้อมูล GPS ล่าสุด'
              : 'ข้อมูล GPS เก่า',
    };

    FlutterForegroundTask.sendDataToMain(data);

    final acc = p == null
        ? 'N/A'
        : '±${p.accuracy.toStringAsFixed(1)}ม.';
    final age = ageSeconds == null ? 'ไม่มีข้อมูล' : '${ageSeconds}s';

    await FlutterForegroundTask.updateService(
      notificationTitle: 'GPS Net Monitor',
      notificationText: 'GPS $acc | อายุข้อมูล $age | $_network',
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
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') FlutterForegroundTask.stopService();
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }
}

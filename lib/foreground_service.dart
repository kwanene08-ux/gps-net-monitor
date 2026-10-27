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
  StreamSubscription<Position>? _gpsSubscription;
  bool _gpsLocked = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _sendGpsLockStatus('โหมดล็อก GPS ปิด');
    await _publish(null);
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // In lock mode the continuous stream owns location requests. Otherwise use
    // the original periodic one-shot request to keep the normal mode lighter.
    if (!_gpsLocked) {
      Position? p;
      try {
        p = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
          forceAndroidLocationManager: true,
          timeLimit: const Duration(seconds: 5),
        );
      } catch (_) {
        // Use the last accepted fix but continue to report its true age.
      }
      await _acceptPosition(p);
    }

    if (_lastNetRead == null ||
        timestamp.difference(_lastNetRead!) >= const Duration(seconds: 3)) {
      try {
        final c = await Connectivity().checkConnectivity();
        _network = c.map((e) => e.name).join(', ');
        if (_network.isEmpty) _network = 'none';
      } catch (_) {
        _network = 'N/A';
      }
      _lastNetRead = timestamp;
    }

    await _publish(_lastAccepted);
  }

  Future<Position?> _acceptPosition(Position? p) async {
    if (p == null || !p.accuracy.isFinite || p.accuracy > 100) return null;
    final last = _lastAccepted;
    if (last != null) {
      final seconds = p.timestamp.difference(last.timestamp).inMilliseconds / 1000.0;
      final distance = Geolocator.distanceBetween(
        last.latitude, last.longitude, p.latitude, p.longitude,
      );
      if (seconds > 0 && distance / seconds > 60) {
        await _alertOnce('GPS jump rejected');
        return null;
      }
      if (seconds <= 0) return null;
    }
    _lastAccepted = p;
    return p;
  }

  Future<void> _handleLockedPosition(Position p) async {
    if (!_gpsLocked) return;
    final accepted = await _acceptPosition(p);
    if (accepted != null) await _publish(accepted);
  }

  void _sendGpsLockStatus(String status) {
    FlutterForegroundTask.sendDataToMain({
      'event': 'gps_lock_status',
      'locked': _gpsLocked,
      'status': status,
    });
  }

  Future<void> _setGpsLock(bool enabled) async {
    if (enabled == _gpsLocked) {
      _sendGpsLockStatus(_gpsLocked
          ? 'ล็อก GPS อยู่: รับตำแหน่งต่อเนื่อง'
          : 'โหมดล็อก GPS ปิด');
      return;
    }

    if (enabled) {
      try {
        _gpsSubscription = Geolocator.getPositionStream(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 0,
            forceLocationManager: true,
            intervalDuration: const Duration(seconds: 1),
          ),
        ).listen(
          (Position position) => unawaited(_handleLockedPosition(position)),
          onError: (Object error) => unawaited(_handleGpsStreamError()),
        );
        _gpsLocked = true;
        _sendGpsLockStatus('ล็อก GPS อยู่: รับตำแหน่งต่อเนื่อง');
      } catch (_) {
        _gpsLocked = false;
        _gpsSubscription = null;
        _sendGpsLockStatus('เปิดโหมดล็อก GPS ไม่สำเร็จ');
        return;
      }
    } else {
      _gpsLocked = false;
      await _gpsSubscription?.cancel();
      _gpsSubscription = null;
      _sendGpsLockStatus('ปลดล็อก GPS แล้ว: กลับไปอ่านตามรอบปกติ');
    }

    await FlutterForegroundTask.updateService(
      notificationTitle: _gpsLocked ? 'GPS Net Monitor — 🔒 ล็อก GPS' : 'GPS Net Monitor',
      notificationText: _gpsLocked
          ? 'ล็อก GPS ต่อเนื่อง | กำลังรับตำแหน่ง…'
          : 'GPS ตรวจตามรอบปกติ | $_network',
    );
  }

  Future<void> _handleGpsStreamError() async {
    if (!_gpsLocked) return;
    _gpsLocked = false;
    await _gpsSubscription?.cancel();
    _gpsSubscription = null;
    _sendGpsLockStatus('โหมดล็อก GPS หยุด: รับข้อมูลต่อเนื่องไม่ได้');
    await FlutterForegroundTask.updateService(
      notificationTitle: 'GPS Net Monitor',
      notificationText: 'โหมดล็อก GPS หยุด | $_network',
    );
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
      notificationTitle: _gpsLocked ? 'GPS Net Monitor — 🔒 ล็อก GPS' : 'GPS Net Monitor',
      notificationText: _gpsLocked
          ? '🔒 GPS $acc | อายุข้อมูล $age | $_network'
          : 'GPS $acc | อายุข้อมูล $age | $_network',
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
    FlutterForegroundTask.sendDataToMain({'event': 'service_destroyed'});
    _gpsLocked = false;
    await _gpsSubscription?.cancel();
    _gpsSubscription = null;
    _sendGpsLockStatus('GPS Lock ปิด: บริการติดตามหยุดแล้ว');
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    if (data['action'] == 'gps_lock_status_request') {
      _sendGpsLockStatus(_gpsLocked
          ? 'ล็อก GPS อยู่: รับตำแหน่งต่อเนื่อง'
          : 'โหมดล็อก GPS ปิด');
      return;
    }
    if (data['action'] == 'gps_lock' && data['enabled'] is bool) {
      unawaited(_setGpsLock(data['enabled'] as bool));
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') FlutterForegroundTask.stopService();
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }
}

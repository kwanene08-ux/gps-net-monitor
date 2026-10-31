import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'gps_freshness.dart';
import 'gps_anti_jump_filter.dart';
@pragma('vm:entry-point')
void startCallback() =>
    FlutterForegroundTask.setTaskHandler(GpsMonitorTaskHandler());

class GpsMonitorTaskHandler extends TaskHandler {
  Position? _lastAccepted;
  final GpsAntiJumpFilter _antiJumpFilter = GpsAntiJumpFilter();
  static const int _gpsIntervalSeconds = 2;
  DateTime? _lastNetRead;
  DateTime? _lastGpsStartAttempt;
  DateTime? _lastStaleRecovery;
  bool _gpsReconfiguring = false;
  bool _isDestroying = false;
  String _network = 'N/A';
  DateTime? _lastAlert;
  StreamSubscription<Position>? _gpsSubscription;
  bool _gpsStarting = false;
  DateTime? _lastNotificationUpdate;
  String? _lastNotificationText;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _startGpsStream();
    await _publish(null);
  }

  Future<void> _startGpsStream({bool force = false}) async {
    if (_isDestroying ||
        _gpsSubscription != null ||
        _gpsStarting ||
        (_gpsReconfiguring && !force)) {
      return;
    }

    final now = DateTime.now();

    if (!force &&
        _lastGpsStartAttempt != null &&
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
          intervalDuration: const Duration(
            seconds: _gpsIntervalSeconds,
          ),
        ),
      );

      late final StreamSubscription<Position> subscription;
      subscription = stream.listen(
        (Position position) {
          unawaited(_handleStreamPosition(position));
        },
        onError: (Object error) {
          unawaited(_handleGpsStreamError(subscription));
        },
        onDone: () {
          unawaited(_handleGpsStreamError(subscription));
        },
      );
      _gpsSubscription = subscription;
    } catch (_) {
      _gpsSubscription = null;
    } finally {
      _gpsStarting = false;
    }
  }

  Future<void> _handleStreamPosition(Position position) async {
    if (_isDestroying) return;

    final accepted = await _acceptPosition(position);
    if (_isDestroying) return;

    if (accepted == null) {
      await _publish(_lastAccepted);
      return;
    }

    await _publish(accepted);
  }

  Future<void> _maybeRecoverStaleGps() async {
    final last = _lastAccepted;

    // ไม่รีสตาร์ตวนในช่วงเริ่มต้นที่ยังไม่เคยได้รับ GPS fix
    if (last == null ||
        _gpsSubscription == null ||
        _gpsStarting ||
        _gpsReconfiguring) {
      return;
    }

    final now = DateTime.now();
    final age = now.difference(last.timestamp);

    if (age < const Duration(seconds: 30)) return;

    if (_lastStaleRecovery != null &&
        now.difference(_lastStaleRecovery!) <
            const Duration(seconds: 60)) {
      return;
    }

    _gpsReconfiguring = true;

    try {
      final oldSubscription = _gpsSubscription;
      _gpsSubscription = null;

      await oldSubscription?.cancel();

      _lastStaleRecovery = DateTime.now();

      // เริ่มใหม่เฉพาะ GPS stream ของแอปนี้
      await _startGpsStream(force: true);
    } finally {
      _gpsReconfiguring = false;
    }
  }

  Future<void> _handleGpsStreamError(
    StreamSubscription<Position> source,
  ) async {
    if (!identical(_gpsSubscription, source)) return;

    _gpsSubscription = null;
    await source.cancel();
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    if (_isDestroying) return;

    if (_isDestroying) return;

    // ถ้า Stream หยุด ให้ลองเริ่มใหม่โดยเว้นระยะอย่างน้อย 5 วินาที
    if (_gpsSubscription == null) {
      await _startGpsStream();
    }

    // ตรวจเครือข่ายแยกจาก GPS ทุกประมาณ 10 วินาที
    if (_lastNetRead == null ||
        timestamp.difference(_lastNetRead!) >=
            const Duration(seconds: 10)) {
      try {
        final result = await Connectivity().checkConnectivity();
        _network = result.map((item) => item.name).join(', ');
        if (_network.isEmpty) _network = 'none';
      } catch (_) {
        _network = 'N/A';
      }
      _lastNetRead = DateTime.now();
    }

    // ตรวจ GPS ค้างและเริ่ม Stream ใหม่เมื่อจำเป็น
    await _maybeRecoverStaleGps();

    // ส่งข้อมูลล่าสุดพร้อมอายุจริง ไม่สร้างตำแหน่งใหม่จากข้อมูลเก่า
    await _publish(_lastAccepted);
  }

  Future<Position?> _acceptPosition(Position? position) async {
    if (position == null) return null;

    final decision = _antiJumpFilter.evaluate(
      GpsFixSample(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        timestamp: position.timestamp,
        speedMetersPerSecond: position.speed,
        speedAccuracyMetersPerSecond: position.speedAccuracy,
      ),
    );

    if (!decision.accepted) {
      if (decision.jumpDetected) {
        await _alertOnce('GPS jump rejected; waiting for confirmation');
      }
      return null;
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
      'gpsFilterStatus': _antiJumpFilter.status,
      'gpsJumpPending': _antiJumpFilter.isPending,
      'gpsJumpConfirmations': _antiJumpFilter.confirmationCount,
      'gpsJumpRejectedCount': _antiJumpFilter.rejectedCount,
      'gpsJumpDistanceMeters': _antiJumpFilter.lastDistanceMeters,
      'gpsJumpAllowedMeters': _antiJumpFilter.lastAllowedDistanceMeters,
      'gpsJumpReason': _antiJumpFilter.lastReason,
      'gpsJumpRequiredConfirmations': _antiJumpFilter.requiredConfirmations,
      'gpsIntervalSeconds': _gpsIntervalSeconds,
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

    final notificationText =
        'GPS $accuracyText | อายุข้อมูล $ageText | $_network';
    final lastNotificationUpdate = _lastNotificationUpdate;
    final shouldUpdateNotification =
        _lastNotificationText != notificationText &&
        (lastNotificationUpdate == null ||
            now.difference(lastNotificationUpdate) >=
                const Duration(seconds: 10));

    if (shouldUpdateNotification) {
      _lastNotificationUpdate = now;
      _lastNotificationText = notificationText;
      await FlutterForegroundTask.updateService(
        notificationTitle: 'GPS Net Monitor',
        notificationText: notificationText,
      );
    }
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
    _isDestroying = true;

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

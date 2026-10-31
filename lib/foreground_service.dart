import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'gps_freshness.dart';
import 'gps_ai_manager.dart';

@pragma('vm:entry-point')
void startCallback() =>
    FlutterForegroundTask.setTaskHandler(GpsMonitorTaskHandler());

class GpsMonitorTaskHandler extends TaskHandler {
  Position? _lastAccepted;
  DateTime? _lastNetRead;
  DateTime? _lastGpsStartAttempt;
  final GpsAiManager _aiManager = GpsAiManager();
  int _activeGpsIntervalSeconds = GpsAiManager.movingIntervalSeconds;
  DateTime? _lastAdaptiveRestart;
  DateTime? _lastStaleRecovery;
  DateTime? _lastHistorySave;
  Future<void>? _historySaveFuture;
  bool _historyDirty = false;
  bool _historyForceRequested = false;
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
    try {
      final saved = await FlutterForegroundTask.getData<String>(
        key: GpsAiManager.storageKey,
      );

      _aiManager.restoreHistory(saved);
      _activeGpsIntervalSeconds =
          _aiManager.requestedIntervalSeconds;
    } catch (_) {
      // หากประวัติอ่านไม่ได้ ให้เริ่ม GPS ด้วยค่าเริ่มต้น
    }

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
          intervalDuration: Duration(
            seconds: _activeGpsIntervalSeconds,
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

    if (_isDestroying || accepted == null) return;

    _recordAiPosition(accepted);
    await _publish(accepted);
    await _maybeApplyAdaptiveInterval();
  }

  void _recordAiPosition(Position position) {
    final now = DateTime.now();
    final ageSeconds =
        now.difference(position.timestamp).inMilliseconds / 1000.0;

    double? trustedSpeedKmh;

    final speedIsReliable =
        ageSeconds >= 0 &&
        ageSeconds <= 5 &&
        position.accuracy.isFinite &&
        position.accuracy <= 10 &&
        position.speed.isFinite &&
        position.speed >= 0 &&
        position.speedAccuracy.isFinite &&
        position.speedAccuracy <= 1.5;

    if (speedIsReliable) {
      trustedSpeedKmh = position.speed < 0.55
          ? 0.0
          : position.speed * 3.6;
    }

    final previousTimestamp = _aiManager.latestTimestampMs;

    _aiManager.observe(
      now: now,
      fixTime: position.timestamp,
      accuracy: position.accuracy,
      speedKmh: trustedSpeedKmh,
    );

    if (_aiManager.latestTimestampMs != previousTimestamp) {
      unawaited(_saveAiHistory());
    }
  }

  Future<void> _saveAiHistory({bool force = false}) async {
    _historyDirty = true;
    if (force) _historyForceRequested = true;

    final pending = _historySaveFuture;
    if (pending != null) {
      await pending;

      // ตรวจซ้ำหลังงานเดิมเสร็จ ป้องกันคำขอ force ตกหล่น
      if (_historyDirty) {
        await _saveAiHistory(
          force: force || _historyForceRequested,
        );
      }
      return;
    }

    final operation = () async {
      while (_historyDirty) {
        final forceNow = _historyForceRequested;
        final now = DateTime.now();

        if (!forceNow &&
            _lastHistorySave != null &&
            now.difference(_lastHistorySave!) <
                const Duration(seconds: 10)) {
          return;
        }

        _historyForceRequested = false;
        _historyDirty = false;

        bool success;
        try {
          success = await FlutterForegroundTask.saveData(
            key: GpsAiManager.storageKey,
            value: _aiManager.encodeHistory(),
          );
        } catch (_) {
          success = false;
        }

        if (success) {
          _lastHistorySave = DateTime.now();
        } else {
          _historyDirty = true;

          // ลองซ้ำเมื่อมีคำขอ force เข้ามาระหว่างบันทึก
          if (!_historyForceRequested) return;
        }

        // หากมีข้อมูลใหม่หรือคำขอ force ระหว่างบันทึก
        // จะวนตรวจอีกครั้งก่อนจบงาน
      }
    }();

    late final Future<void> tracked;
    tracked = operation.whenComplete(() {
      if (identical(_historySaveFuture, tracked)) {
        _historySaveFuture = null;
      }
    });
    _historySaveFuture = tracked;

    await tracked;
  }

  Future<void> _maybeApplyAdaptiveInterval() async {
    final desired = _aiManager.requestedIntervalSeconds;

    if (desired == _activeGpsIntervalSeconds ||
        _gpsSubscription == null ||
        _gpsStarting ||
        _gpsReconfiguring) {
      return;
    }

    final now = DateTime.now();

    if (_lastAdaptiveRestart != null &&
        now.difference(_lastAdaptiveRestart!) <
            const Duration(seconds: 30)) {
      return;
    }

    _gpsReconfiguring = true;

    try {
      final oldSubscription = _gpsSubscription;
      _gpsSubscription = null;

      await oldSubscription?.cancel();

      _activeGpsIntervalSeconds = desired;
      _lastAdaptiveRestart = DateTime.now();

      await _startGpsStream(force: true);
    } finally {
      _gpsReconfiguring = false;
    }
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

    // บันทึกประวัติที่ค้าง เมื่อถึงรอบตรวจสอบถัดไป
    if (_historyDirty) {
      await _saveAiHistory();
    }

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

    // ตรวจข้อมูลเก่าค้าง และปรับช่วงเวลา GPS ตามโหมด AI
    await _maybeRecoverStaleGps();
    await _maybeApplyAdaptiveInterval();

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
      ..._aiManager.dashboardData(),
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

    await _saveAiHistory(force: true);

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

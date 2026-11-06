import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:gps_provider/gps_provider.dart';
import 'gps_freshness.dart';
import 'gps_anti_jump_filter.dart';
import 'ipv4_network_monitor.dart';
@pragma('vm:entry-point')
void startCallback() =>
    FlutterForegroundTask.setTaskHandler(GpsMonitorTaskHandler());

class GpsMonitorTaskHandler extends TaskHandler {
  Position? _lastAccepted;
  final GpsAntiJumpFilter _antiJumpFilter = GpsAntiJumpFilter();
  static const int _gpsIntervalSeconds = 1;
  DateTime? _lastNetRead;
  DateTime? _lastGpsStartAttempt;
  DateTime? _gpsStreamStartedAt;
  DateTime? _lastRawGpsEventAt;
  DateTime? _lastStaleRecovery;
  bool _gpsReconfiguring = false;
  bool _isDestroying = false;
  String _network = 'N/A';
  final Ipv4NetworkMonitor _ipv4Monitor = Ipv4NetworkMonitor();
  DateTime? _lastIpv4Check;
  bool _ipv4CheckRunning = false;
  String _gpsStreamStatus = 'กำลังค้นหาดาวเทียมจาก GPS_PROVIDER';
  bool _gpsHasReceivedFix = false;
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
      final stream = GpsProvider.getPositionStream()
          .map(_positionFromGpsProvider);

      late final StreamSubscription<Position> subscription;
      subscription = stream.listen(
        (Position position) {
          unawaited(_handleStreamPosition(position));
        },
        onError: (Object error) {
          if (identical(_gpsSubscription, subscription)) {
            _gpsStreamStatus = 'GPS_PROVIDER ขัดข้อง: $error';
          }
          unawaited(_handleGpsStreamError(subscription));
        },
        onDone: () {
          if (identical(_gpsSubscription, subscription)) {
            _gpsStreamStatus = 'GPS_PROVIDER stream ปิด';
          }
          unawaited(_handleGpsStreamError(subscription));
        },
      );
      _gpsSubscription = subscription;
      _gpsStreamStartedAt = DateTime.now();
      _lastRawGpsEventAt = null;
    } catch (error) {
      _gpsSubscription = null;
      _gpsStreamStatus = 'เริ่ม GPS_PROVIDER ไม่สำเร็จ: $error';
    } finally {
      _gpsStarting = false;
    }
  }

  Position _positionFromGpsProvider(Map<String, dynamic> data) {
    if (data['provider'] != 'gps') {
      throw const FormatException(
        'ข้อมูลมาจาก Provider ที่ไม่ใช่ GPS_PROVIDER',
      );
    }

    final latitudeValue = data['latitude'];
    final longitudeValue = data['longitude'];
    final accuracyValue = data['accuracy'];
    final timestampValue = data['timestamp'];

    if (latitudeValue is! num ||
        longitudeValue is! num ||
        accuracyValue is! num ||
        timestampValue is! num) {
      throw const FormatException('ข้อมูล GPS_PROVIDER ไม่ครบ');
    }

    final latitude = latitudeValue.toDouble();
    final longitude = longitudeValue.toDouble();
    final accuracy = accuracyValue.toDouble();
    final timestampMs = timestampValue.toDouble();

    if (!latitude.isFinite ||
        !longitude.isFinite ||
        !accuracy.isFinite ||
        !timestampMs.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180 ||
        accuracy < 0 ||
        timestampMs <= 0 ||
        timestampMs > 8640000000000000 ||
        timestampMs != timestampMs.roundToDouble()) {
      throw const FormatException('ค่าพิกัดหรือเวลา GPS_PROVIDER ไม่ถูกต้อง');
    }

    double readNumber(String key, double fallback) {
      final value = data[key];
      if (value is num && value.isFinite) {
        return value.toDouble();
      }
      return fallback;
    }

    return Position(
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs.toInt()),
      accuracy: accuracy,
      altitude: readNumber('altitude', 0.0),
      altitudeAccuracy: readNumber('altitudeAccuracy', 0.0),
      heading: readNumber('heading', 0.0),
      headingAccuracy: readNumber('headingAccuracy', 999.0),
      speed: readNumber('speed', 0.0),
      speedAccuracy: readNumber('speedAccuracy', 999.0),
      isMocked: data['isMocked'] == true,
    );
  }
  Future<void> _handleStreamPosition(Position position) async {
    if (_isDestroying) return;
    _lastRawGpsEventAt = DateTime.now();
    _gpsHasReceivedFix = true;
    _gpsStreamStatus = 'ได้รับข้อมูลดิบจาก GPS_PROVIDER แล้ว';

    final accepted = await _acceptPosition(position);
    if (_isDestroying) return;

    if (accepted == null) {
      await _publish(_lastAccepted);
      return;
    }

    await _publish(accepted);
  }

  Future<void> _maybeRecoverStaleGps() async {
    if (_isDestroying ||
        _gpsSubscription == null ||
        _gpsStarting ||
        _gpsReconfiguring) {
      return;
    }

    final now = DateTime.now();
    final lastRaw = _lastRawGpsEventAt;
    final reference = lastRaw ?? _gpsStreamStartedAt;

    if (reference == null) return;

    // รอข้อมูล GPS ครั้งแรก 60 วินาที
    // หลังได้รับข้อมูลแล้ว ตรวจเมื่อ Stream เงียบ 30 วินาที
    final timeout = lastRaw == null
        ? const Duration(seconds: 60)
        : const Duration(seconds: 30);

    if (now.difference(reference) < timeout) return;

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
      _lastRawGpsEventAt = null;
      _gpsStreamStartedAt = null;

      _gpsStreamStatus =
          'GPS_PROVIDER เงียบเกินกำหนด กำลังเริ่ม Stream ใหม่';

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

    // ตรวจ IPv4 แยกจาก GPS และไม่รอผลตรวจในรอบนี้
    if (_lastIpv4Check == null ||
        timestamp.difference(_lastIpv4Check!) >=
            const Duration(seconds: 10)) {
      _lastIpv4Check = timestamp;
      unawaited(_checkIpv4Network());
    }

    // ตรวจ GPS ค้างและเริ่ม Stream ใหม่เมื่อจำเป็น
    await _maybeRecoverStaleGps();

    // ส่งข้อมูลล่าสุดพร้อมอายุจริง ไม่สร้างตำแหน่งใหม่จากข้อมูลเก่า
    await _publish(_lastAccepted);
  }

  Future<void> _checkIpv4Network() async {
    if (_isDestroying || _ipv4CheckRunning) return;

    _ipv4CheckRunning = true;
    try {
      final result = await _ipv4Monitor.check();
      if (result != null && !_isDestroying) {
        FlutterForegroundTask.sendDataToMain(result);
      }
    } catch (_) {
      // ความผิดพลาดของการตรวจเน็ตต้องไม่หยุด GPS
    } finally {
      _ipv4CheckRunning = false;
    }
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
      'provider': _gpsHasReceivedFix
          ? 'GPS_PROVIDER (ได้รับ GNSS fix แล้ว)'
          : 'GPS_PROVIDER (กำลังรอ GNSS fix)',
      'gpsSourceStatus': _gpsStreamStatus,
      'gpsAcceptedStatus': _lastAccepted == null
          ? 'ยังไม่มีพิกัดผ่านตัวกรอง'
          : 'พิกัดล่าสุดเคยผ่านตัวกรองแล้ว',
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

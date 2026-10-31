import 'dart:math' as math;

/// ข้อมูล GPS ที่ใช้ตรวจสอบการกระโดดของตำแหน่ง
class GpsFixSample {
  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime timestamp;

  const GpsFixSample({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
  });

  bool get isValid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      accuracy.isFinite &&
      accuracy >= 0;
}

class GpsAntiJumpDecision {
  final bool accepted;
  final bool jumpDetected;
  final bool reacquired;

  const GpsAntiJumpDecision({
    required this.accepted,
    this.jumpDetected = false,
    this.reacquired = false,
  });
}

/// กรอง GPS Fix ที่เคลื่อนที่ผิดปกติ
///
/// จุดที่ผิดปกติจะไม่ถูกส่งไปแสดงทันที
/// ต้องมี Fix ถัดไปที่สอดคล้องกับจุดต้องสงสัยก่อน จึงยืนยันตำแหน่งใหม่
class GpsAntiJumpFilter {
  static const double maxSpeedMetersPerSecond = 35.0;
  static const int requiredConsistentFixes = 2;

  static const double _earthRadiusMeters = 6371000.0;
  static const double _minAccuracyMarginMeters = 8.0;
  static const double _maxAccuracyMarginMeters = 30.0;

  GpsFixSample? _anchor;
  GpsFixSample? _pending;
  DateTime? _lastInputTimestamp;

  int _rejectedCount = 0;
  String _status = 'รอข้อมูล GPS';

  String get status => _status;
  bool get isPending => _pending != null;
  int get confirmationCount => _pending == null ? 0 : 1;
  int get rejectedCount => _rejectedCount;

  GpsAntiJumpDecision evaluate(GpsFixSample sample) {
    if (!sample.isValid) {
      _status = 'GPS Fix ไม่ถูกต้อง';
      return const GpsAntiJumpDecision(accepted: false);
    }

    final previousInputTime = _lastInputTimestamp;
    if (previousInputTime != null &&
        !sample.timestamp.isAfter(previousInputTime)) {
      _status = 'ละเว้น GPS Fix ซ้ำหรือย้อนหลัง';
      return const GpsAntiJumpDecision(accepted: false);
    }

    _lastInputTimestamp = sample.timestamp;

    final anchor = _anchor;
    if (anchor == null) {
      _anchor = sample;
      _status = 'ติดตาม GPS ปกติ';
      return const GpsAntiJumpDecision(accepted: true);
    }

    final seconds =
        sample.timestamp.difference(anchor.timestamp).inMilliseconds /
            1000.0;

    if (!seconds.isFinite || seconds <= 0) {
      _status = 'ละเว้นเวลา GPS ที่ผิดปกติ';
      return const GpsAntiJumpDecision(accepted: false);
    }

    final distance = _distanceMeters(anchor, sample);
    final maximumDistance = _maximumPlausibleDistance(
      anchor,
      sample,
      seconds,
    );

    // จุดใหม่ยังต่อเนื่องกับตำแหน่งเดิม:
    // รับตำแหน่งและยกเลิกจุดต้องสงสัยที่ค้างอยู่
    if (distance <= maximumDistance) {
      final wasPending = _pending != null;
      _anchor = sample;
      _pending = null;
      _status = wasPending
          ? 'กลับสู่ตำแหน่งเดิม ยกเลิกจุดกระโดด'
          : 'ติดตาม GPS ปกติ';

      return const GpsAntiJumpDecision(accepted: true);
    }

    // ตำแหน่งกระโดดจาก Anchor เดิม:
    // ตรวจว่ามี Fix ใหม่ที่เคลื่อนต่อเนื่องจากจุดต้องสงสัยหรือไม่
    final pending = _pending;
    if (pending != null) {
      final pendingSeconds =
          sample.timestamp.difference(pending.timestamp).inMilliseconds /
              1000.0;

      if (pendingSeconds > 0 && pendingSeconds.isFinite) {
        final pendingDistance = _distanceMeters(pending, sample);
        final pendingMaximum = _maximumPlausibleDistance(
          pending,
          sample,
          pendingSeconds,
        );

        if (pendingDistance <= pendingMaximum) {
          _anchor = sample;
          _pending = null;
          _status = 'ยืนยันตำแหน่งใหม่แล้ว';

          return const GpsAntiJumpDecision(
            accepted: true,
            reacquired: true,
          );
        }
      }
    }

    // ยังไม่มี Fix ที่ยืนยันได้:
    // พักจุดนี้ไว้ ไม่ส่งเป็นตำแหน่งที่ยอมรับ
    _rejectedCount++;
    _pending = sample;
    _status = 'พบ GPS กระโดด กำลังรอยืนยัน 2 จุด';

    return const GpsAntiJumpDecision(
      accepted: false,
      jumpDetected: true,
    );
  }

  double _maximumPlausibleDistance(
    GpsFixSample first,
    GpsFixSample second,
    double seconds,
  ) {
    final accuracyMargin = (
      (first.accuracy + second.accuracy) * 1.5
    ).clamp(
      _minAccuracyMarginMeters,
      _maxAccuracyMarginMeters,
    ).toDouble();

    return maxSpeedMetersPerSecond * seconds + accuracyMargin;
  }

  double _distanceMeters(GpsFixSample first, GpsFixSample second) {
    final lat1 = _toRadians(first.latitude);
    final lat2 = _toRadians(second.latitude);
    final deltaLat = _toRadians(second.latitude - first.latitude);
    final deltaLon = _toRadians(second.longitude - first.longitude);

    final sinLat = math.sin(deltaLat / 2);
    final sinLon = math.sin(deltaLon / 2);

    final value = sinLat * sinLat +
        math.cos(lat1) *
            math.cos(lat2) *
            sinLon *
            sinLon;

    final bounded = value.clamp(0.0, 1.0).toDouble();

    return 2 *
        _earthRadiusMeters *
        math.asin(math.sqrt(bounded));
  }

  double _toRadians(double degrees) => degrees * math.pi / 180.0;
}

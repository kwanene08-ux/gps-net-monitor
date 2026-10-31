import 'dart:math' as math;

/// ข้อมูล GPS ที่ใช้ตรวจสอบการกระโดดของตำแหน่ง
class GpsFixSample {
  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime timestamp;
  final double? speedMetersPerSecond;
  final double? speedAccuracyMetersPerSecond;

  const GpsFixSample({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
    this.speedMetersPerSecond,
    this.speedAccuracyMetersPerSecond,
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
  final double? distanceMeters;
  final double? allowedDistanceMeters;
  final int requiredConfirmations;
  final int confirmationCount;
  final String reason;

  const GpsAntiJumpDecision({
    required this.accepted,
    this.jumpDetected = false,
    this.reacquired = false,
    this.distanceMeters,
    this.allowedDistanceMeters,
    this.requiredConfirmations = 2,
    this.confirmationCount = 0,
    this.reason = '',
  });
}

/// ตัวกรอง GPS กระโดดแบบยืนยันหลาย Fix
/// ไม่สร้างพิกัดใหม่ ไม่เฉลี่ยพิกัด และไม่ทำ Road snapping
class GpsAntiJumpFilter {
  static const double maxSpeedMetersPerSecond = 35.0;
  static const int candidateTimeoutSeconds = 8;

  static const double _earthRadiusMeters = 6371000.0;
  static const double _minAccuracyMarginMeters = 8.0;
  static const double _maxAccuracyMarginMeters = 30.0;

  GpsFixSample? _anchor;
  GpsFixSample? _pending;
  DateTime? _lastInputTimestamp;

  int _pendingConfirmations = 0;
  int _pendingRequired = 2;
  int _rejectedCount = 0;

  String _status = 'รอข้อมูล GPS';
  String _reason = 'รอ GPS Fix';
  double? _lastDistance;
  double? _lastAllowedDistance;

  String get status => _status;
  bool get isPending => _pending != null;
  int get confirmationCount => _pendingConfirmations;
  int get requiredConfirmations => _pendingRequired;
  int get rejectedCount => _rejectedCount;
  double? get lastDistanceMeters => _lastDistance;
  double? get lastAllowedDistanceMeters => _lastAllowedDistance;
  String get lastReason => _reason;

  GpsAntiJumpDecision evaluate(GpsFixSample sample) {
    if (!sample.isValid) {
      _status = 'GPS Fix ไม่ถูกต้อง';
      _reason = 'พิกัดหรือ Accuracy ไม่ถูกต้อง';
      return _decision(false, reason: _reason);
    }

    final previousInputTime = _lastInputTimestamp;
    if (previousInputTime != null &&
        !sample.timestamp.isAfter(previousInputTime)) {
      _status = 'ละเว้น GPS Fix ซ้ำหรือย้อนหลัง';
      _reason = 'เวลา GPS ซ้ำหรือย้อนหลัง';
      return _decision(false, reason: _reason);
    }
    _lastInputTimestamp = sample.timestamp;

    final anchor = _anchor;
    if (anchor == null) {
      _anchor = sample;
      _clearPending();
      _status = 'ติดตาม GPS ปกติ';
      _reason = 'รับ GPS Fix แรก';
      return _decision(true, reason: _reason);
    }

    final seconds =
        sample.timestamp.difference(anchor.timestamp).inMilliseconds / 1000.0;
    if (!seconds.isFinite || seconds <= 0) {
      _status = 'ละเว้นเวลา GPS ที่ผิดปกติ';
      _reason = 'ช่วงเวลา GPS ไม่ถูกต้อง';
      return _decision(false, reason: _reason);
    }

    final distance = _distanceMeters(anchor, sample);
    final allowed = _maximumPlausibleDistance(anchor, sample, seconds);
    _lastDistance = distance;
    _lastAllowedDistance = allowed;

    // ถ้าตำแหน่งกลับมาอยู่ในระยะที่เป็นไปได้จาก Anchor เดิม
    // ให้ยกเลิก Candidate ที่ค้างไว้
    if (distance <= allowed) {
      final hadPending = isPending;
      _anchor = sample;
      _clearPending();
      _status = hadPending
          ? 'กลับสู่ตำแหน่งเดิม ยกเลิกจุดกระโดด'
          : 'ติดตาม GPS ปกติ';
      _reason = hadPending
          ? 'ตำแหน่งกลับมาเชื่อมต่อกับจุดเดิม'
          : 'ระยะเคลื่อนที่อยู่ในเกณฑ์';
      return _decision(
        true,
        distance: distance,
        allowed: allowed,
        reason: _reason,
      );
    }

    final pending = _pending;
    if (pending != null) {
      final pendingAge =
          sample.timestamp.difference(pending.timestamp).inMilliseconds /
              1000.0;

      if (pendingAge > candidateTimeoutSeconds || pendingAge <= 0) {
        _clearPending();
        _reason = 'Candidate เดิมหมดเวลา ต้องเริ่มยืนยันใหม่';
      } else {
        final pendingDistance = _distanceMeters(pending, sample);
        final pendingAllowed =
            _maximumPlausibleDistance(pending, sample, pendingAge);

        if (pendingDistance <= pendingAllowed) {
          _pendingConfirmations++;
          _pendingRequired = _requiredFor(sample, pending);

          if (_pendingConfirmations >= _pendingRequired) {
            _anchor = sample;
            _clearPending();
            _status = 'ยืนยันตำแหน่งใหม่แล้ว';
            _reason = 'GPS Fix ต่อเนื่องครบจำนวนที่กำหนด';
            return _decision(
              true,
              reacquired: true,
              distance: distance,
              allowed: allowed,
              reason: _reason,
            );
          }

          _pending = sample;
          _status = 'กำลังยืนยันตำแหน่งใหม่';
          _reason = 'Fix สอดคล้องกัน แต่ยังยืนยันไม่ครบ';
          _lastDistance = pendingDistance;
          _lastAllowedDistance = pendingAllowed;
          return _decision(
            false,
            jump: true,
            distance: pendingDistance,
            allowed: pendingAllowed,
            reason: _reason,
          );
        }
      }
    }

    _pending = sample;
    _pendingConfirmations = 1;
    _pendingRequired = _requiredFor(sample, anchor);
    _rejectedCount++;
    _status = 'พบ GPS กระโดด กำลังรอยืนยัน';
    _reason = 'ระยะจากจุดเดิมเกินขีดจำกัด';

    return _decision(
      false,
      jump: true,
      distance: distance,
      allowed: allowed,
      reason: _reason,
    );
  }

  int _requiredFor(GpsFixSample current, GpsFixSample previous) {
    final speed = current.speedMetersPerSecond;
    final speedAccuracy = current.speedAccuracyMetersPerSecond;

    final reliableSpeed = speed != null &&
        speed.isFinite &&
        speed >= 0 &&
        speedAccuracy != null &&
        speedAccuracy.isFinite &&
        speedAccuracy >= 0 &&
        speedAccuracy <= 1.5;

    final stationaryEvidence = reliableSpeed &&
        speed <= 0.7 &&
        current.accuracy <= 10 &&
        previous.accuracy <= 10;

    // Fix คุณภาพต่ำหรือมีหลักฐานว่าอยู่นิ่ง ต้องยืนยัน 3 จุด
    if (current.accuracy > 10 ||
        previous.accuracy > 10 ||
        stationaryEvidence) {
      return 3;
    }

    // ความเร็วเป็นข้อมูลประกอบ ไม่ใช้ปฏิเสธ GPS โดยลำพัง
    return 2;
  }

  double _maximumPlausibleDistance(
    GpsFixSample first,
    GpsFixSample second,
    double seconds,
  ) {
    final accuracyMargin =
        ((first.accuracy + second.accuracy) * 1.5)
            .clamp(_minAccuracyMarginMeters, _maxAccuracyMarginMeters)
            .toDouble();

    return maxSpeedMetersPerSecond * seconds + accuracyMargin;
  }

  GpsAntiJumpDecision _decision(
    bool accepted, {
    bool jump = false,
    bool reacquired = false,
    double? distance,
    double? allowed,
    required String reason,
  }) {
    return GpsAntiJumpDecision(
      accepted: accepted,
      jumpDetected: jump,
      reacquired: reacquired,
      distanceMeters: distance,
      allowedDistanceMeters: allowed,
      requiredConfirmations: _pendingRequired,
      confirmationCount: _pendingConfirmations,
      reason: reason,
    );
  }

  void _clearPending() {
    _pending = null;
    _pendingConfirmations = 0;
    _pendingRequired = 2;
  }

  double _distanceMeters(GpsFixSample first, GpsFixSample second) {
    final lat1 = _toRadians(first.latitude);
    final lat2 = _toRadians(second.latitude);
    final deltaLat = _toRadians(second.latitude - first.latitude);
    final deltaLon = _toRadians(second.longitude - first.longitude);

    final sinLat = math.sin(deltaLat / 2);
    final sinLon = math.sin(deltaLon / 2);
    final value = sinLat * sinLat +
        math.cos(lat1) * math.cos(lat2) * sinLon * sinLon;
    final bounded = value.clamp(0.0, 1.0).toDouble();

    return 2 * _earthRadiusMeters * math.asin(math.sqrt(bounded));
  }

  double _toRadians(double degrees) => degrees * math.pi / 180.0;
}

import 'dart:math' as math;

/// ข้อมูล GPS สำหรับตรวจสอบความต่อเนื่องของตำแหน่ง
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

/// GPS Anti-Jump v1.5.0
///
/// - ไม่สร้างพิกัดจำลอง
/// - ไม่เฉลี่ยพิกัด
/// - ไม่ทำ Road snapping
/// - ตรึง Anchor เมื่อมีหลักฐานว่าจอดนิ่ง
/// - จำกัดระยะที่อนุญาตเมื่อ GPS ขาดช่วง
/// - ยืนยันตำแหน่งใหม่จาก Fix ต่อเนื่อง
class GpsAntiJumpFilter {
  static const double maxSpeedMetersPerSecond = 28.0;
  static const int candidateTimeoutSeconds = 10;

  static const double _earthRadiusMeters = 6371000.0;
  static const double _minAccuracyMarginMeters = 6.0;
  static const double _maxAccuracyMarginMeters = 18.0;
  static const double _maxMovementSeconds = 4.0;
  static const double _stationarySpeedThreshold = 0.8;
  static const double _movingSpeedThreshold = 1.5;

  GpsFixSample? _anchor;
  GpsFixSample? _stationaryAnchor;
  GpsFixSample? _pending;
  DateTime? _lastInputTimestamp;

  int _pendingConfirmations = 0;
  int _pendingRequired = 2;
  int _rejectedCount = 0;
  int _stationaryEvidence = 0;
  int _movingEvidence = 0;

  bool _isStationary = false;

  String _status = 'รอข้อมูล GPS';
  String _reason = 'รอ GPS Fix';
  double? _lastDistance;
  double? _lastAllowedDistance;

  String get status => _status;
  bool get isPending => _pending != null;
  bool get isStationary => _isStationary;
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
      _updateMotionState(sample);
      _status = 'ติดตาม GPS ปกติ';
      _reason = 'รับ GPS Fix แรก';
      return _decision(true, reason: _reason);
    }

    _updateMotionState(sample);

    final seconds =
        sample.timestamp.difference(anchor.timestamp).inMilliseconds /
            1000.0;

    if (!seconds.isFinite || seconds <= 0) {
      _status = 'ละเว้นเวลา GPS ที่ผิดปกติ';
      _reason = 'ช่วงเวลา GPS ไม่ถูกต้อง';
      return _decision(false, reason: _reason);
    }

    final distanceAnchor = _isStationary
        ? (_stationaryAnchor ?? anchor)
        : anchor;
    final distance = _distanceMeters(distanceAnchor, sample);

    // เมื่อจอดนิ่งให้วัดจาก Anchor เดิมเสมอ
    // ไม่เลื่อน Anchor ตาม GPS drift ทีละเล็กทีละน้อย
    if (_isStationary) {
      final stationaryAllowed =
          _stationaryRadius(distanceAnchor, sample);
      _lastDistance = distance;
      _lastAllowedDistance = stationaryAllowed;

      if (distance <= stationaryAllowed) {
        _clearPending();
        _status = 'ตรวจพบการจอดนิ่ง ตรึงจุดอ้างอิง GPS';
        _reason = 'ตำแหน่งยังอยู่ในรัศมีการจอดนิ่ง';
        return _decision(
          true,
          distance: distance,
          allowed: stationaryAllowed,
          reason: _reason,
        );
      }
    }

    final allowed = _maximumPlausibleDistance(
      anchor,
      sample,
      seconds,
    );

    _lastDistance = distance;
    _lastAllowedDistance = allowed;

    // เมื่อขาด GPS เกิน 6 วินาที ต้องตรวจ Fix ต่อเนื่อง
    // ไม่อนุญาตให้ระยะเวลาที่ขาดช่วงขยายขีดจำกัดไม่สิ้นสุด
    final gapNeedsConfirmation = seconds > 6.0;

    if (!_isStationary &&
        !gapNeedsConfirmation &&
        distance <= allowed) {
      final hadPending = isPending;
      _anchor = sample;
      _clearPending();
      _status = 'ติดตาม GPS ปกติ';
      _reason = hadPending
          ? 'ตำแหน่งกลับเข้าเกณฑ์จาก Anchor เดิม'
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

      if (pendingAge > candidateTimeoutSeconds ||
          pendingAge <= 0) {
        _clearPending();
      } else {
        final pendingDistance = _distanceMeters(pending, sample);
        final pendingAllowed =
            _maximumPlausibleDistance(
          pending,
          sample,
          pendingAge,
        );

        if (pendingDistance <= pendingAllowed) {
          _pendingConfirmations++;
          _pendingRequired = _requiredFor(sample);

          if (_pendingConfirmations >= _pendingRequired) {
            _anchor = sample;
            _isStationary = false;
            _stationaryAnchor = null;
            _stationaryEvidence = 0;
            _movingEvidence = 0;
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
          _reason = 'Fix ต่อเนื่อง แต่ยังยืนยันไม่ครบ';
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

        _clearPending();
      }
    }

    _pending = sample;
    _pendingConfirmations = 1;
    _pendingRequired = _requiredFor(sample);
    _rejectedCount++;
    _status = 'พบ GPS กระโดด กำลังรอยืนยัน';
    _reason = gapNeedsConfirmation
        ? 'GPS ขาดช่วง ต้องยืนยันตำแหน่งต่อเนื่อง'
        : 'ตำแหน่งเกินระยะที่อนุญาต';

    return _decision(
      false,
      jump: true,
      distance: distance,
      allowed: allowed,
      reason: _reason,
    );
  }

  bool _hasReliableSpeed(GpsFixSample sample) {
    final speed = sample.speedMetersPerSecond;
    final speedAccuracy = sample.speedAccuracyMetersPerSecond;

    return speed != null &&
        speed.isFinite &&
        speed >= 0 &&
        speedAccuracy != null &&
        speedAccuracy.isFinite &&
        speedAccuracy >= 0 &&
        speedAccuracy <= 1.5 &&
        sample.accuracy <= 10;
  }

  void _updateMotionState(GpsFixSample sample) {
    if (!_hasReliableSpeed(sample)) return;

    final speed = sample.speedMetersPerSecond!;

    if (speed <= _stationarySpeedThreshold) {
      _stationaryEvidence++;
      _movingEvidence = 0;

      if (_stationaryEvidence >= 2 && !_isStationary) {
        _isStationary = true;
        _stationaryAnchor = _anchor ?? sample;
      }
    } else if (speed >= _movingSpeedThreshold) {
      _movingEvidence++;
      _stationaryEvidence = 0;

      if (_movingEvidence >= 2 && _isStationary) {
        _isStationary = false;
        _stationaryAnchor = null;
      }
    }
  }

  int _requiredFor(GpsFixSample sample) {
    if (_hasReliableSpeed(sample) &&
        sample.speedMetersPerSecond! >= 2.0) {
      return 2;
    }
    return 3;
  }

  double _stationaryRadius(
    GpsFixSample first,
    GpsFixSample second,
  ) {
    return ((first.accuracy + second.accuracy) * 1.0)
        .clamp(8.0, 12.0)
        .toDouble();
  }

  double _maximumPlausibleDistance(
    GpsFixSample first,
    GpsFixSample second,
    double seconds,
  ) {
    final accuracyMargin =
        ((first.accuracy + second.accuracy) * 0.75)
            .clamp(
              _minAccuracyMarginMeters,
              _maxAccuracyMarginMeters,
            )
            .toDouble();

    final boundedSeconds =
        seconds.clamp(0.0, _maxMovementSeconds).toDouble();

    return maxSpeedMetersPerSecond * boundedSeconds +
        accuracyMargin;
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

import 'dart:math' as math;

import 'gps_anti_jump_filter.dart';

/// ลดการสั่นของตำแหน่งเฉพาะช่วงที่ตรวจพบว่าจอดนิ่ง
/// ไม่แก้ค่า accuracy และไม่หน่วง GPS Fix ขณะเคลื่อนที่
class GpsStationarySmoother {
  static const double _maxAccuracyMeters = 8.0;
  static const double _stationarySpeed = 0.8;
  static const double _movingSpeed = 1.5;
  static const double _maxSpeedAccuracy = 3.0;
  static const double _movementReleaseMeters = 6.5;
  static const int _requiredStationaryFixes = 3;
  static const int _windowSize = 5;

  final List<GpsFixSample> _window = <GpsFixSample>[];

  GpsFixSample? _stationaryAnchor;
  DateTime? _lastTimestamp;
  int _stationaryEvidence = 0;

  bool isStationary = false;

  GpsFixSample process(GpsFixSample sample) {
    if (!sample.isValid) {
      _reset();
      return sample;
    }

    final previousTime = _lastTimestamp;
    if (previousTime != null &&
        !sample.timestamp.isAfter(previousTime)) {
      _reset();
      _lastTimestamp = sample.timestamp;
      return sample;
    }

    _lastTimestamp = sample.timestamp;

    if (sample.accuracy > _maxAccuracyMeters) {
      _reset();
      _lastTimestamp = sample.timestamp;
      return sample;
    }

    final speed = sample.speedMetersPerSecond;
    final speedAccuracy = sample.speedAccuracyMetersPerSecond;

    if (speed != null &&
        speed.isFinite &&
        speed >= _movingSpeed) {
      _reset();
      _lastTimestamp = sample.timestamp;
      return sample;
    }

    final anchor = _stationaryAnchor;
    if (isStationary && anchor != null) {
      final displacement = _distanceMeters(anchor, sample);
      if (displacement > _movementReleaseMeters) {
        _reset();
        _lastTimestamp = sample.timestamp;
        return sample;
      }
    }

    final reliableLowSpeed = speed != null &&
        speed.isFinite &&
        speed >= 0 &&
        speed <= _stationarySpeed &&
        speedAccuracy != null &&
        speedAccuracy.isFinite &&
        speedAccuracy >= 0 &&
        speedAccuracy <= _maxSpeedAccuracy;

    if (!reliableLowSpeed) {
      if (!isStationary) {
        _stationaryEvidence = 0;
        _window.clear();
      }
      return sample;
    }

    _stationaryEvidence++;

    _window.add(sample);
    if (_window.length > _windowSize) {
      _window.removeAt(0);
    }

    if (_stationaryEvidence < _requiredStationaryFixes) {
      return sample;
    }

    if (!isStationary) {
      _stationaryAnchor = _window.first;
    }
    isStationary = true;

    return _medianFix(sample);
  }

  GpsFixSample _medianFix(GpsFixSample raw) {
    final latitudes = _window.map((fix) => fix.latitude).toList()
      ..sort();
    final longitudes = _window.map((fix) => fix.longitude).toList()
      ..sort();

    return GpsFixSample(
      latitude: _median(latitudes),
      longitude: _median(longitudes),
      accuracy: raw.accuracy,
      timestamp: raw.timestamp,
      speedMetersPerSecond: raw.speedMetersPerSecond,
      speedAccuracyMetersPerSecond: raw.speedAccuracyMetersPerSecond,
    );
  }

  double _median(List<double> values) {
    final middle = values.length ~/ 2;
    if (values.length.isOdd) return values[middle];
    return (values[middle - 1] + values[middle]) / 2.0;
  }

  double _distanceMeters(GpsFixSample first, GpsFixSample second) {
    const metersPerDegree = 111195.0;
    final meanLatitude = (first.latitude + second.latitude) / 2.0;
    final deltaLatitude =
        (second.latitude - first.latitude) * metersPerDegree;
    final deltaLongitude = (second.longitude - first.longitude) *
        metersPerDegree *
        math.cos(meanLatitude * math.pi / 180.0);

    return math.sqrt(
      deltaLatitude * deltaLatitude +
          deltaLongitude * deltaLongitude,
    );
  }

  void _reset() {
    isStationary = false;
    _stationaryEvidence = 0;
    _window.clear();
    _stationaryAnchor = null;
    _lastTimestamp = null;
  }
}

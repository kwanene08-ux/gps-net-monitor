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

  GpsFixSample? _lastRaw;
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
      return sample;
    }

    _lastTimestamp = sample.timestamp;

    if (sample.accuracy > _maxAccuracyMeters) {
      _reset();
      _lastRaw = sample;
      _lastTimestamp = sample.timestamp;
      return sample;
    }

    final speed = sample.speedMetersPerSecond;
    final speedAccuracy = sample.speedAccuracyMetersPerSecond;

    if (speed != null &&
        speed.isFinite &&
        speed >= _movingSpeed) {
      _reset();
      _lastRaw = sample;
      _lastTimestamp = sample.timestamp;
      return sample;
    }

    final previousRaw = _lastRaw;
    if (isStationary && previousRaw != null) {
      final displacement = _distanceMeters(previousRaw, sample);
      if (displacement > _movementReleaseMeters) {
        _reset();
        _lastRaw = sample;
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
      _lastRaw = sample;
      return sample;
    }

    _stationaryEvidence++;
    _lastRaw = sample;

    _window.add(sample);
    if (_window.length > _windowSize) {
      _window.removeAt(0);
    }

    if (_stationaryEvidence < _requiredStationaryFixes) {
      return sample;
    }

    isStationary = true;
    return _medianFix(sample);
  }

  GpsFixSample _medianFix(GpsFixSample raw) {
    final latitudes = _window
        .map((fix) => fix.latitude)
        .toList()
      ..sort();

    final longitudes = _window
        .map((fix) => fix.longitude)
        .toList()
      ..sort();

    return GpsFixSample(
      latitude: _median(latitudes),
      longitude: _median(longitudes),
      accuracy: raw.accuracy,
      timestamp: raw.timestamp,
      speedMetersPerSecond: raw.speedMetersPerSecond,
      speedAccuracyMetersPerSecond:
          raw.speedAccuracyMetersPerSecond,
    );
  }

  double _median(List<double> values) {
    final middle = values.length ~/ 2;
    if (values.length.isOdd) {
      return values[middle];
    }
    return (values[middle - 1] + values[middle]) / 2.0;
  }

  double _distanceMeters(
    GpsFixSample first,
    GpsFixSample second,
  ) {
    const metersPerDegree = 111195.0;

    final meanLatitude =
        (first.latitude + second.latitude) / 2.0;

    final deltaLatitude =
        (second.latitude - first.latitude) * metersPerDegree;

    final deltaLongitude =
        (second.longitude - first.longitude) *
        metersPerDegree *
        _cosDegrees(meanLatitude);

    return _sqrt(
      deltaLatitude * deltaLatitude +
      deltaLongitude * deltaLongitude,
    );
  }

  double _cosDegrees(double degrees) {
    return _cos(degrees * 3.141592653589793 / 180.0);
  }

  double _sqrt(double value) {
    if (value <= 0) return 0;
    return _sqrtNewton(value);
  }

  double _sqrtNewton(double value) {
    var estimate = value > 1 ? value : 1.0;
    for (var i = 0; i < 20; i++) {
      estimate = (estimate + value / estimate) / 2.0;
    }
    return estimate;
  }

  double _cos(double value) {
    // Taylor approximation is sufficient for local GPS displacement.
    final x = value % (2.0 * 3.141592653589793);
    final x2 = x * x;
    return 1.0 -
        x2 / 2.0 +
        x2 * x2 / 24.0 -
        x2 * x2 * x2 / 720.0 +
        x2 * x2 * x2 * x2 / 40320.0;
  }

  void _reset() {
    isStationary = false;
    _stationaryEvidence = 0;
    _window.clear();
    _lastRaw = null;
    _lastTimestamp = null;
  }
}

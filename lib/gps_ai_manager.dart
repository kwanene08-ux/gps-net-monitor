
import 'dart:convert';

class GpsAiHistorySample {
  final int timestampMs;
  final double accuracy;
  final double ageSeconds;
  final double? speedKmh;
  final String motionMode;

  const GpsAiHistorySample({
    required this.timestampMs,
    required this.accuracy,
    required this.ageSeconds,
    required this.speedKmh,
    required this.motionMode,
  });

  Map<String, dynamic> toJson() => {
        't': timestampMs,
        'a': accuracy,
        'age': ageSeconds,
        'speed': speedKmh,
        'motion': motionMode,
      };

  static GpsAiHistorySample? fromJson(dynamic value) {
    if (value is! Map) return null;

    final timestamp = value['t'];
    final rawAccuracy = value['a'];
    final rawAge = value['age'];
    final rawSpeed = value['speed'];
    final rawMotion = value['motion'];

    if (timestamp is! int ||
        timestamp <= 0 ||
        rawAccuracy is! num ||
        rawAge is! num ||
        rawMotion is! String) {
      return null;
    }

    final accuracy = rawAccuracy.toDouble();
    final ageSeconds = rawAge.toDouble();
    final speedKmh =
        rawSpeed is num ? rawSpeed.toDouble() : null;

    if (!accuracy.isFinite ||
        accuracy < 0 ||
        !ageSeconds.isFinite ||
        ageSeconds < 0 ||
        (speedKmh != null &&
            (!speedKmh.isFinite || speedKmh < 0))) {
      return null;
    }

    const allowedModes = {
      'กำลังประเมิน',
      'กำลังเคลื่อนที่',
      'จอด/หยุด',
    };

    if (!allowedModes.contains(rawMotion)) return null;

    return GpsAiHistorySample(
      timestampMs: timestamp,
      accuracy: accuracy,
      ageSeconds: ageSeconds,
      speedKmh: speedKmh,
      motionMode: rawMotion,
    );
  }
}

/// วิเคราะห์รูปแบบการเคลื่อนที่และคุณภาพ GPS ภายในเครื่อง
/// ไม่บันทึก Latitude หรือ Longitude
class GpsAiManager {
  static const String storageKey = 'gps_ai_history_v130';
  static const int maxHistorySamples = 720;
  static const int movingIntervalSeconds = 2;
  static const int parkedIntervalSeconds = 5;

  final List<GpsAiHistorySample> _history = [];

  String _motionMode = 'กำลังประเมิน';
  int _requestedIntervalSeconds = movingIntervalSeconds;
  int _movingCount = 0;
  int _stationaryCount = 0;
  int? _lastObservedTimestampMs;

  int get historyCount => _history.length;

  int? get latestTimestampMs =>
      _history.isEmpty ? null : _history.last.timestampMs;

  String get motionMode => _motionMode;

  int get requestedIntervalSeconds => _requestedIntervalSeconds;

  double? get averageAccuracy {
    if (_history.isEmpty) return null;

    final samples = _history.length <= 20
        ? _history
        : _history.sublist(_history.length - 20);

    final total = samples.fold<double>(
      0,
      (sum, sample) => sum + sample.accuracy,
    );

    return total / samples.length;
  }

  String get accuracyTrend {
    if (_history.length < 6) return 'ข้อมูลยังไม่เพียงพอ';

    final recent = _history.length <= 20
        ? _history
        : _history.sublist(_history.length - 20);

    final half = recent.length ~/ 2;
    if (half < 3) return 'ข้อมูลยังไม่เพียงพอ';

    final olderAverage = recent
            .take(half)
            .fold<double>(
              0,
              (sum, sample) => sum + sample.accuracy,
            ) /
        half;

    final newer = recent.skip(half).toList();

    final newerAverage = newer.fold<double>(
          0,
          (sum, sample) => sum + sample.accuracy,
        ) /
        newer.length;

    if (newerAverage < olderAverage - 1) {
      return 'Accuracy ดีขึ้น';
    }

    if (newerAverage > olderAverage + 1) {
      return 'Accuracy แย่ลง';
    }

    return 'Accuracy ค่อนข้างคงที่';
  }

  String get qualityStatus {
    final average = averageAccuracy;

    if (average == null) return 'กำลังเรียนรู้ข้อมูล GPS';
    if (average > 20) return 'ความแม่นยำ GPS ต่ำ';
    if (average > 10) return 'GPS ยังไม่นิ่ง';

    return 'GPS มีแนวโน้มเสถียร';
  }

  void _resetMotionCounters() {
    _movingCount = 0;
    _stationaryCount = 0;
  }

  /// รับเฉพาะ GPS fix ใหม่ตาม timestamp
  ///
  /// ใช้ความเร็วประกอบการวิเคราะห์เมื่อ:
  /// - อายุข้อมูลไม่เกิน 5 วินาที
  /// - Accuracy ไม่เกิน 10 เมตร
  /// - ความเร็วเป็นค่าที่ถูกต้องและไม่ติดลบ
  ///
  /// คืน true เมื่อช่วงเวลาที่ร้องขอ GPS เปลี่ยน
  bool observe({
    required DateTime now,
    required DateTime fixTime,
    required double accuracy,
    required double? speedKmh,
  }) {
    final timestamp = fixTime.millisecondsSinceEpoch;

    // ป้องกันการนับ GPS fix ซ้ำหรือข้อมูลย้อนเวลา
    if (timestamp <= 0 ||
        (_lastObservedTimestampMs != null &&
            timestamp <= _lastObservedTimestampMs!)) {
      return false;
    }

    _lastObservedTimestampMs = timestamp;

    final oldInterval = _requestedIntervalSeconds;
    final age =
        now.difference(fixTime).inMilliseconds / 1000.0;

    final validTime =
        age.isFinite && age >= 0 && age <= 60;

    final validAccuracy =
        accuracy.isFinite && accuracy >= 0;

    if (!validTime || !validAccuracy) {
      _resetMotionCounters();
      return false;
    }

    double? trustedSpeed;

    if (age <= 5 &&
        accuracy <= 10 &&
        speedKmh != null &&
        speedKmh.isFinite &&
        speedKmh >= 0) {
      trustedSpeed = speedKmh;
    }

    if (trustedSpeed == null) {
      // ข้อมูลที่ไม่น่าเชื่อถือต้องไม่ต่อจำนวนตัวอย่างเดิม
      _resetMotionCounters();
    } else if (trustedSpeed >= 5) {
      _movingCount++;
      _stationaryCount = 0;

      if (_movingCount >= 3) {
        _motionMode = 'กำลังเคลื่อนที่';
        _requestedIntervalSeconds = movingIntervalSeconds;
      }
    } else if (trustedSpeed <= 2) {
      _stationaryCount++;
      _movingCount = 0;

      if (_stationaryCount >= 4) {
        _motionMode = 'จอด/หยุด';
        _requestedIntervalSeconds = parkedIntervalSeconds;
      }
    } else {
      // ช่วงความเร็วมากกว่า 2 แต่ต่ำกว่า 5 กม./ชม.
      _resetMotionCounters();
    }

    // ไม่บันทึกความเร็วที่ไม่ผ่านเกณฑ์
    _history.add(
      GpsAiHistorySample(
        timestampMs: timestamp,
        accuracy: accuracy,
        ageSeconds: age,
        speedKmh: trustedSpeed,
        motionMode: _motionMode,
      ),
    );

    if (_history.length > maxHistorySamples) {
      _history.removeRange(
        0,
        _history.length - maxHistorySamples,
      );
    }

    return oldInterval != _requestedIntervalSeconds;
  }

  Map<String, dynamic> dashboardData() => {
        'aiMotionMode': _motionMode,
        'aiRequestedIntervalSeconds': _requestedIntervalSeconds,
        'aiHistoryCount': historyCount,
        'aiAverageAccuracy': averageAccuracy,
        'aiAccuracyTrend': accuracyTrend,
        'aiQualityStatus': qualityStatus,
      };

  String encodeHistory() {
    return jsonEncode({
      'version': 1,
      'motionMode': _motionMode,
      'samples': _history.map((sample) => sample.toJson()).toList(),
    });
  }

  /// คืน false เมื่อข้อมูลเดิมเสียหายหรืออ่านไม่ได้
  bool restoreHistory(String? encoded) {
    if (encoded == null || encoded.isEmpty) return false;

    try {
      final decoded = jsonDecode(encoded);

      if (decoded is! Map || decoded['version'] != 1) {
        return false;
      }

      final rawSamples = decoded['samples'];
      if (rawSamples is! List) return false;

      final restored = <GpsAiHistorySample>[];

      for (final item in rawSamples) {
        final sample = GpsAiHistorySample.fromJson(item);
        if (sample != null) restored.add(sample);
      }

      restored.sort(
        (a, b) => a.timestampMs.compareTo(b.timestampMs),
      );

      final unique = <GpsAiHistorySample>[];

      for (final sample in restored) {
        if (unique.isEmpty ||
            sample.timestampMs > unique.last.timestampMs) {
          unique.add(sample);
        }
      }

      final bounded = unique.length > maxHistorySamples
          ? unique.sublist(unique.length - maxHistorySamples)
          : unique;

      _history
        ..clear()
        ..addAll(bounded);

      final mode = decoded['motionMode'];

      if (mode is String &&
          (mode == 'กำลังเคลื่อนที่' ||
              mode == 'จอด/หยุด' ||
              mode == 'กำลังประเมิน')) {
        _motionMode = mode;
      } else {
        _motionMode = 'กำลังประเมิน';
      }

      _requestedIntervalSeconds =
          _motionMode == 'จอด/หยุด'
              ? parkedIntervalSeconds
              : movingIntervalSeconds;

      _lastObservedTimestampMs = latestTimestampMs;

      // เริ่มนับความต่อเนื่องใหม่หลัง Restore
      _resetMotionCounters();

      return true;
    } catch (_) {
      return false;
    }
  }
}

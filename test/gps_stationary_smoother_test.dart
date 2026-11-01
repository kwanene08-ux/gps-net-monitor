import 'package:flutter_test/flutter_test.dart';
import 'package:gps_net_monitor/gps_anti_jump_filter.dart';
import 'package:gps_net_monitor/gps_stationary_smoother.dart';

void main() {
  final start = DateTime.utc(2026, 1, 1, 12);

  GpsFixSample fix(
    double meters,
    int seconds, {
    double accuracy = 3,
    double speed = 0.2,
    double speedAccuracy = 2.1,
  }) {
    return GpsFixSample(
      latitude: 0,
      longitude: meters / 111195.0,
      accuracy: accuracy,
      timestamp: start.add(Duration(seconds: seconds)),
      speedMetersPerSecond: speed,
      speedAccuracyMetersPerSecond: speedAccuracy,
    );
  }

  group('GpsStationarySmoother', () {
    test('ลดการสั่นของพิกัดขณะจอดนิ่ง', () {
      final smoother = GpsStationarySmoother();
      smoother.process(fix(0, 0));
      smoother.process(fix(4, 2));
      smoother.process(fix(-3, 4));
      final result = smoother.process(fix(3, 6));

      expect(smoother.isStationary, isTrue);
      expect(result.longitude * 111195.0, closeTo(1.5, 0.15));
    });

    test('ไม่กรองเมื่อ Accuracy แย่เกินเกณฑ์', () {
      final smoother = GpsStationarySmoother();
      smoother.process(fix(0, 0));
      smoother.process(fix(4, 2, accuracy: 12));
      smoother.process(fix(-3, 4));
      final result = smoother.process(fix(3, 6));

      expect(result.longitude * 111195.0, closeTo(3, 0.15));
    });

    test('ปลดการกรองทันทีเมื่อความเร็วแสดงว่าเริ่มเคลื่อนที่', () {
      final smoother = GpsStationarySmoother();
      smoother.process(fix(0, 0));
      smoother.process(fix(1, 2));
      smoother.process(fix(0, 4));
      smoother.process(fix(1, 6));

      final moving = smoother.process(
        fix(12, 8, speed: 4.0, speedAccuracy: 2.1),
      );

      expect(smoother.isStationary, isFalse);
      expect(moving.longitude * 111195.0, closeTo(12, 0.15));
    });

    test('ปลดการกรองเมื่อเคลื่อนที่แม้ Speed ไม่น่าเชื่อถือ', () {
      final smoother = GpsStationarySmoother();
      smoother.process(fix(0, 0));
      smoother.process(fix(1, 2));
      smoother.process(fix(0, 4));
      smoother.process(fix(1, 6));

      final moving = smoother.process(
        fix(8, 8, speed: 0.2, speedAccuracy: 5.0),
      );

      expect(smoother.isStationary, isFalse);
      expect(moving.longitude * 111195.0, closeTo(8, 0.15));
    });
  });
}

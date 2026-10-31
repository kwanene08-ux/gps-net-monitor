import 'package:flutter_test/flutter_test.dart';
import 'package:gps_net_monitor/gps_anti_jump_filter.dart';

void main() {
  final start = DateTime.utc(2026, 1, 1, 12);

  GpsFixSample fix(
    double meters,
    int seconds, {
    double accuracy = 3,
    double? speed,
    double? speedAccuracy,
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

  group('GpsAntiJumpFilter v1.4.0', () {
    test('รับ GPS Fix แรก', () {
      final filter = GpsAntiJumpFilter();
      expect(filter.evaluate(fix(0, 0)).accepted, isTrue);
    });

    test('รับการเคลื่อนที่ปกติ', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));
      expect(filter.evaluate(fix(30, 2)).accepted, isTrue);
    });

    test('พักจุดกระโดดและนับ Candidate แรก', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));
      final result = filter.evaluate(fix(200, 2));

      expect(result.accepted, isFalse);
      expect(result.jumpDetected, isTrue);
      expect(filter.isPending, isTrue);
      expect(filter.confirmationCount, 1);
      expect(filter.rejectedCount, 1);
      expect(result.distanceMeters, isNotNull);
      expect(result.allowedDistanceMeters, isNotNull);
    });

    test('ยืนยันตำแหน่งใหม่เมื่อ Fix คุณภาพดีต่อเนื่อง 2 จุด', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));
      filter.evaluate(fix(200, 2));
      final result = filter.evaluate(fix(260, 4));

      expect(result.accepted, isTrue);
      expect(result.reacquired, isTrue);
      expect(filter.isPending, isFalse);
      expect(filter.status, 'ยืนยันตำแหน่งใหม่แล้ว');
    });

    test('Fix accuracy ต่ำต้องยืนยัน 3 จุด', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));
      final first = filter.evaluate(fix(200, 2, accuracy: 15));
      final second = filter.evaluate(fix(260, 4, accuracy: 15));
      final third = filter.evaluate(fix(320, 6, accuracy: 15));

      expect(first.accepted, isFalse);
      expect(first.requiredConfirmations, 3);
      expect(second.accepted, isFalse);
      expect(second.confirmationCount, 2);
      expect(third.accepted, isTrue);
      expect(third.reacquired, isTrue);
    });

    test('ความเร็วต่ำและ Accuracy ดี ต้องยืนยัน 3 จุด', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));
      final first = filter.evaluate(
        fix(200, 2, speed: 0.2, speedAccuracy: 0.5),
      );
      expect(first.requiredConfirmations, 3);
    });

    test('Candidate หมดอายุแล้วเริ่มนับใหม่', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));
      filter.evaluate(fix(200, 2));
      final result = filter.evaluate(fix(600, 12));

      expect(result.accepted, isFalse);
      expect(filter.confirmationCount, 1);
      expect(filter.isPending, isTrue);
    });

    test('กลับใกล้ Anchor เดิมแล้วยกเลิก Candidate', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));
      filter.evaluate(fix(200, 2));
      final result = filter.evaluate(fix(8, 4));

      expect(result.accepted, isTrue);
      expect(filter.isPending, isFalse);
      expect(filter.status, contains('กลับสู่ตำแหน่งเดิม'));
    });

    test('Candidate ที่ไม่ต่อเนื่องเริ่มนับใหม่', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));
      filter.evaluate(fix(200, 2));
      final result = filter.evaluate(fix(500, 4));

      expect(result.accepted, isFalse);
      expect(filter.confirmationCount, 1);
    });

    test('ปฏิเสธเวลา GPS ซ้ำหรือย้อนหลัง', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 2));
      expect(filter.evaluate(fix(1, 2)).accepted, isFalse);
      expect(filter.evaluate(fix(1, 1)).accepted, isFalse);
    });

    test('ปฏิเสธพิกัดผิดช่วง', () {
      final filter = GpsAntiJumpFilter();
      final result = filter.evaluate(
        GpsFixSample(
          latitude: 91,
          longitude: 0,
          accuracy: 3,
          timestamp: start,
        ),
      );
      expect(result.accepted, isFalse);
    });

    test('ปฏิเสธ Accuracy ที่ไม่ใช่ตัวเลข', () {
      final filter = GpsAntiJumpFilter();
      final result = filter.evaluate(
        GpsFixSample(
          latitude: 0,
          longitude: 0,
          accuracy: double.nan,
          timestamp: start,
        ),
      );
      expect(result.accepted, isFalse);
    });
  });
}

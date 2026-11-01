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

  group('GpsAntiJumpFilter v1.5.0', () {
    test('รับ GPS Fix แรก', () {
      final filter = GpsAntiJumpFilter();
      expect(filter.evaluate(fix(0, 0)).accepted, isTrue);
    });

    test('รับการเคลื่อนที่ปกติ', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));
      expect(filter.evaluate(fix(30, 2)).accepted, isTrue);
    });

    test('ปฏิเสธจุดที่กระโดด 200 เมตรใน 2 วินาที', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));

      final result = filter.evaluate(fix(200, 2));

      expect(result.accepted, isFalse);
      expect(result.jumpDetected, isTrue);
      expect(result.allowedDistanceMeters, lessThan(70));
      expect(filter.isPending, isTrue);
    });

    test('ไม่มีความเร็วที่เชื่อถือได้ ต้องยืนยัน 3 Fix', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));

      final first = filter.evaluate(fix(200, 2));
      final second = filter.evaluate(fix(260, 4));
      final third = filter.evaluate(fix(320, 6));

      expect(first.accepted, isFalse);
      expect(first.requiredConfirmations, 3);
      expect(second.accepted, isFalse);
      expect(second.confirmationCount, 2);
      expect(third.accepted, isTrue);
      expect(third.reacquired, isTrue);
    });

    test('ความเร็วที่เชื่อถือได้ขณะเคลื่อนที่ ยืนยันได้ใน 2 Fix', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));

      final first = filter.evaluate(
        fix(200, 2, speed: 20, speedAccuracy: 0.5),
      );
      final second = filter.evaluate(
        fix(260, 4, speed: 20, speedAccuracy: 0.5),
      );

      expect(first.accepted, isFalse);
      expect(first.requiredConfirmations, 2);
      expect(second.accepted, isTrue);
      expect(second.reacquired, isTrue);
    });

    test('Fix Accuracy ต่ำต้องยืนยัน 3 จุด', () {
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
    });

    test('จอดนิ่งแล้วตรึง Anchor ไม่ให้ GPS drift สะสม', () {
      final filter = GpsAntiJumpFilter();

      filter.evaluate(
        fix(0, 0, speed: 0.2, speedAccuracy: 0.5),
      );
      final stationary = filter.evaluate(
        fix(0, 2, speed: 0.2, speedAccuracy: 0.5),
      );
      final withinRadius = filter.evaluate(
        fix(7, 4, speed: 0.2, speedAccuracy: 0.5),
      );
      final outsideRadius = filter.evaluate(
        fix(14, 6, speed: 0.2, speedAccuracy: 0.5),
      );

      expect(stationary.accepted, isTrue);
      expect(filter.isStationary, isTrue);
      expect(withinRadius.accepted, isTrue);
      expect(outsideRadius.accepted, isFalse);
      expect(outsideRadius.jumpDetected, isTrue);
    });

    test('ความเร็วเคลื่อนที่ต่อเนื่องปลดสถานะจอดนิ่ง', () {
      final filter = GpsAntiJumpFilter();

      filter.evaluate(
        fix(0, 0, speed: 0.2, speedAccuracy: 0.5),
      );
      filter.evaluate(
        fix(0, 2, speed: 0.2, speedAccuracy: 0.5),
      );
      expect(filter.isStationary, isTrue);

      filter.evaluate(
        fix(10, 4, speed: 5, speedAccuracy: 0.5),
      );
      final moving = filter.evaluate(
        fix(20, 6, speed: 5, speedAccuracy: 0.5),
      );

      expect(filter.isStationary, isFalse);
      expect(moving.accepted, isTrue);
    });

    test('GPS ขาดช่วงต้องยืนยัน Fix ต่อเนื่องก่อนรับตำแหน่ง', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));

      final first = filter.evaluate(fix(50, 10));
      final second = filter.evaluate(fix(60, 12));
      final third = filter.evaluate(fix(70, 14));

      expect(first.accepted, isFalse);
      expect(first.requiredConfirmations, 3);
      expect(second.accepted, isFalse);
      expect(second.confirmationCount, 2);
      expect(third.accepted, isTrue);
      expect(third.reacquired, isTrue);
    });

    test('Candidate หมดอายุแล้วเริ่มนับใหม่', () {
      final filter = GpsAntiJumpFilter();
      filter.evaluate(fix(0, 0));
      filter.evaluate(fix(200, 2));

      final result = filter.evaluate(fix(600, 13));

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

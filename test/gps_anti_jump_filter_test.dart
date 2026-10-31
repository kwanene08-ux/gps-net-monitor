import 'package:flutter_test/flutter_test.dart';
import 'package:gps_net_monitor/gps_anti_jump_filter.dart';

void main() {
  final start = DateTime.utc(2026, 1, 1, 12);

  GpsFixSample fix(double meters, int seconds) {
    return GpsFixSample(
      latitude: 0,
      longitude: meters / 111195.0,
      accuracy: 3,
      timestamp: start.add(Duration(seconds: seconds)),
    );
  }

  group('GpsAntiJumpFilter', () {
    test('accepts the first valid GPS fix', () {
      final filter = GpsAntiJumpFilter();

      final result = filter.evaluate(fix(0, 0));

      expect(result.accepted, isTrue);
      expect(filter.isPending, isFalse);
    });

    test('accepts plausible normal movement', () {
      final filter = GpsAntiJumpFilter();

      filter.evaluate(fix(0, 0));
      final result = filter.evaluate(fix(30, 2));

      expect(result.accepted, isTrue);
      expect(result.jumpDetected, isFalse);
      expect(filter.isPending, isFalse);
    });

    test('holds an isolated GPS jump instead of accepting it', () {
      final filter = GpsAntiJumpFilter();

      filter.evaluate(fix(0, 0));
      final result = filter.evaluate(fix(200, 2));

      expect(result.accepted, isFalse);
      expect(result.jumpDetected, isTrue);
      expect(filter.isPending, isTrue);
      expect(filter.confirmationCount, 1);
      expect(filter.rejectedCount, 1);
    });

    test('reacquires after two consecutive consistent fixes', () {
      final filter = GpsAntiJumpFilter();

      filter.evaluate(fix(0, 0));
      final first = filter.evaluate(fix(200, 2));
      final second = filter.evaluate(fix(260, 4));

      expect(first.accepted, isFalse);
      expect(second.accepted, isTrue);
      expect(second.reacquired, isTrue);
      expect(filter.rejectedCount, 1);
      expect(filter.isPending, isFalse);
      expect(filter.status, 'ยืนยันตำแหน่งใหม่แล้ว');
    });

    test('cancels a jump when GPS returns near the old position', () {
      final filter = GpsAntiJumpFilter();

      filter.evaluate(fix(0, 0));
      filter.evaluate(fix(200, 2));
      final result = filter.evaluate(fix(8, 4));

      expect(result.accepted, isTrue);
      expect(result.reacquired, isFalse);
      expect(filter.isPending, isFalse);
      expect(filter.status, contains('กลับสู่ตำแหน่งเดิม'));
    });

    test('rejects duplicate and older timestamps', () {
      final filter = GpsAntiJumpFilter();

      filter.evaluate(fix(0, 2));
      final duplicate = filter.evaluate(fix(1, 2));
      final older = filter.evaluate(fix(1, 1));

      expect(duplicate.accepted, isFalse);
      expect(older.accepted, isFalse);
    });

    test('rejects invalid coordinates', () {
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
      expect(filter.status, 'GPS Fix ไม่ถูกต้อง');
    });

    test('rejects invalid accuracy', () {
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

import 'package:flutter_test/flutter_test.dart';
import 'package:gps_net_monitor/gps_freshness.dart';

void main() {
  group('GpsFreshness.ageSeconds', () {
    test('returns null without a fix', () {
      expect(GpsFreshness.ageSeconds(null, DateTime.now()), isNull);
    });

    test('reports fractional seconds', () {
      final now = DateTime.utc(2026, 1, 1, 12);
      final fix = now.subtract(const Duration(milliseconds: 2400));
      expect(GpsFreshness.ageSeconds(fix, now), closeTo(2.4, 0.0001));
    });

    test('clamps future timestamps to zero', () {
      final now = DateTime.utc(2026, 1, 1, 12);
      expect(
        GpsFreshness.ageSeconds(now.add(const Duration(seconds: 1)), now),
        0.0,
      );
    });
  });

  group('GpsFreshness thresholds', () {
    test('fresh only through 3 seconds', () {
      expect(GpsFreshness.isFresh(3.0), isTrue);
      expect(GpsFreshness.isFresh(3.1), isFalse);
    });

    test('speed data is allowed only through 5 seconds', () {
      expect(GpsFreshness.canUseSpeed(5.0), isTrue);
      expect(GpsFreshness.canUseSpeed(5.1), isFalse);
      expect(GpsFreshness.canUseSpeed(null), isFalse);
    });

    test('reports delayed and stale data accurately', () {
      expect(
        GpsFreshness.status(ageSeconds: 4.0, accuracy: 5.0),
        'GPS เริ่มล่าช้า',
      );
      expect(
        GpsFreshness.status(ageSeconds: 8.0, accuracy: 5.0),
        'GPS ล่าช้า',
      );
      expect(
        GpsFreshness.status(ageSeconds: 10.1, accuracy: 5.0),
        'ข้อมูล GPS เก่า',
      );
    });

    test('fresh data with poor accuracy is not reported as good', () {
      expect(
        GpsFreshness.status(ageSeconds: 1.0, accuracy: 15.0),
        'GPS คลาดเคลื่อน',
      );
    });

    test('rejects invalid age and accuracy', () {
      expect(
        GpsFreshness.status(ageSeconds: null, accuracy: 2.0),
        'ไม่มีข้อมูล GPS',
      );
      expect(
        GpsFreshness.status(ageSeconds: 1.0, accuracy: -1.0),
        'Accuracy ใช้ไม่ได้',
      );
    });
  });
}


import 'package:flutter_test/flutter_test.dart';
import 'package:gps_net_monitor/gps_ai_manager.dart';

void main() {
  final start = DateTime(2026, 1, 1, 12);

  group('GpsAiManager motion detection', () {
    test('ต้องพบความเร็วสูงต่อเนื่อง 3 GPS fixes ก่อนเป็นโหมดเคลื่อนที่', () {
      final manager = GpsAiManager();

      for (var i = 0; i < 2; i++) {
        final time = start.add(Duration(seconds: i * 2));

        manager.observe(
          now: time,
          fixTime: time,
          accuracy: 5,
          speedKmh: 15,
        );
      }

      expect(manager.motionMode, 'กำลังประเมิน');

      final third = start.add(const Duration(seconds: 4));

      manager.observe(
        now: third,
        fixTime: third,
        accuracy: 5,
        speedKmh: 15,
      );

      expect(manager.motionMode, 'กำลังเคลื่อนที่');
      expect(manager.requestedIntervalSeconds, 2);
    });

    test('ต้องพบความเร็วต่ำต่อเนื่อง 4 GPS fixes ก่อนเป็นโหมดจอด', () {
      final manager = GpsAiManager();

      for (var i = 0; i < 3; i++) {
        final time = start.add(Duration(seconds: i * 2));

        manager.observe(
          now: time,
          fixTime: time,
          accuracy: 4,
          speedKmh: 0,
        );
      }

      expect(manager.motionMode, 'กำลังประเมิน');

      final fourth = start.add(const Duration(seconds: 6));

      manager.observe(
        now: fourth,
        fixTime: fourth,
        accuracy: 4,
        speedKmh: 0,
      );

      expect(manager.motionMode, 'จอด/หยุด');
      expect(manager.requestedIntervalSeconds, 5);
    });

    test('GPS fix timestamp เดิมต้องไม่นับซ้ำ', () {
      final manager = GpsAiManager();

      final first = start;
      final second = start.add(const Duration(seconds: 2));

      manager.observe(
        now: first,
        fixTime: first,
        accuracy: 5,
        speedKmh: 20,
      );

      manager.observe(
        now: second,
        fixTime: second,
        accuracy: 5,
        speedKmh: 20,
      );

      // ส่ง timestamp ที่สองซ้ำ ต้องไม่กลายเป็นตัวอย่างที่สาม
      manager.observe(
        now: start.add(const Duration(seconds: 4)),
        fixTime: second,
        accuracy: 5,
        speedKmh: 20,
      );

      expect(manager.motionMode, 'กำลังประเมิน');

      final third = start.add(const Duration(seconds: 4));

      manager.observe(
        now: third,
        fixTime: third,
        accuracy: 5,
        speedKmh: 20,
      );

      expect(manager.motionMode, 'กำลังเคลื่อนที่');
    });

    test('ข้อมูล Accuracy แย่ต้องรีเซ็ตตัวนับความเร็ว', () {
      final manager = GpsAiManager();

      for (var i = 0; i < 2; i++) {
        final time = start.add(Duration(seconds: i * 2));

        manager.observe(
          now: time,
          fixTime: time,
          accuracy: 5,
          speedKmh: 40,
        );
      }

      final poorFix = start.add(const Duration(seconds: 4));

      manager.observe(
        now: poorFix,
        fixTime: poorFix,
        accuracy: 25,
        speedKmh: 40,
      );

      final nextFix = start.add(const Duration(seconds: 6));

      manager.observe(
        now: nextFix,
        fixTime: nextFix,
        accuracy: 5,
        speedKmh: 40,
      );

      expect(manager.motionMode, 'กำลังประเมิน');
    });

    test('ข้อมูลเก่าเกิน 5 วินาทีต้องไม่ใช้วิเคราะห์ความเร็ว', () {
      final manager = GpsAiManager();

      for (var i = 0; i < 2; i++) {
        final time = start.add(Duration(seconds: i * 2));

        manager.observe(
          now: time,
          fixTime: time,
          accuracy: 5,
          speedKmh: 30,
        );
      }

      final staleFix = start.add(const Duration(seconds: 4));

      manager.observe(
        now: staleFix.add(const Duration(seconds: 8)),
        fixTime: staleFix,
        accuracy: 5,
        speedKmh: 30,
      );

      final nextFix = start.add(const Duration(seconds: 14));

      manager.observe(
        now: nextFix,
        fixTime: nextFix,
        accuracy: 5,
        speedKmh: 30,
      );

      expect(manager.motionMode, 'กำลังประเมิน');
    });
  });

  group('GpsAiManager history', () {
    test('เก็บ Accuracy แต่ไม่บันทึกพิกัด Latitude/Longitude', () {
      final manager = GpsAiManager();

      manager.observe(
        now: start,
        fixTime: start,
        accuracy: 4.5,
        speedKmh: 10,
      );

      final encoded = manager.encodeHistory();

      expect(encoded, isNot(contains('"accuracy"')));
      expect(encoded, contains('"a":4.5'));
      expect(encoded, isNot(contains('latitude')));
      expect(encoded, isNot(contains('longitude')));
      expect(manager.historyCount, 1);
    });

    test('ไม่บันทึกความเร็วเมื่อ Accuracy ไม่ผ่านเกณฑ์', () {
      final manager = GpsAiManager();

      manager.observe(
        now: start,
        fixTime: start,
        accuracy: 20,
        speedKmh: 50,
      );

      expect(encodedSpeedIsNull(manager.encodeHistory()), isTrue);
    });

    test('ไม่บันทึก timestamp เดิมซ้ำ', () {
      final manager = GpsAiManager();

      for (var i = 0; i < 3; i++) {
        manager.observe(
          now: start,
          fixTime: start,
          accuracy: 5,
          speedKmh: 1,
        );
      }

      expect(manager.historyCount, 1);
    });

    test('กู้คืนประวัติจาก JSON ได้', () {
      final original = GpsAiManager();

      for (var i = 0; i < 5; i++) {
        final time = start.add(Duration(seconds: i + 1));

        original.observe(
          now: time,
          fixTime: time,
          accuracy: 4 + i.toDouble(),
          speedKmh: 0,
        );
      }

      final restored = GpsAiManager();

      final success =
          restored.restoreHistory(original.encodeHistory());

      expect(success, isTrue);
      expect(restored.historyCount, 5);
      expect(restored.motionMode, original.motionMode);

      expect(
        restored.averageAccuracy,
        closeTo(original.averageAccuracy!, 0.0001),
      );
    });

    test('ปฏิเสธ JSON ที่เสียหาย', () {
      final manager = GpsAiManager();

      expect(manager.restoreHistory('{broken json'), isFalse);
      expect(manager.historyCount, 0);
    });

    test('จำกัดประวัติไม่เกิน 720 จุด', () {
      final manager = GpsAiManager();

      for (var i = 0; i < 730; i++) {
        final time = start.add(Duration(seconds: i + 1));

        manager.observe(
          now: time,
          fixTime: time,
          accuracy: 5,
          speedKmh: null,
        );
      }

      expect(manager.historyCount, 720);
    });

    test('Restore เรียง timestamp ตัดข้อมูลซ้ำและข้ามรายการเสีย', () {
      final manager = GpsAiManager();

      const encoded = '''
{"version":1,"motionMode":"กำลังประเมิน","samples":[
{"t":3000,"a":5,"age":0,"speed":null,"motion":"กำลังประเมิน"},
{"t":1000,"a":4,"age":0,"speed":null,"motion":"กำลังประเมิน"},
{"t":3000,"a":7,"age":0,"speed":null,"motion":"กำลังประเมิน"},
{"invalid":true}
]}''';

      expect(manager.restoreHistory(encoded), isTrue);
      expect(manager.historyCount, 2);

      final restored = manager.encodeHistory();
      final first = restored.indexOf('"t":1000');
      final second = restored.indexOf('"t":3000');

      expect(first, greaterThanOrEqualTo(0));
      expect(second, greaterThan(first));
    });

  });
}

bool encodedSpeedIsNull(String encoded) {
  return encoded.contains('"speed":null');
}

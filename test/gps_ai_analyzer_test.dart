import 'package:flutter_test/flutter_test.dart';
import 'package:gps_net_monitor/gps_ai_analyzer.dart';

void main() {
  group('GpsAiAnalyzer', () {
    final now = DateTime(2026, 1, 1, 12);

    test('รอข้อมูลเมื่อยังไม่มี GPS fix', () {
      final analyzer = GpsAiAnalyzer();
      final result = analyzer.analyze(
        now: now,
        fixTime: null,
        accuracy: null,
      );

      expect(result.status, 'กำลังรอข้อมูล GPS');
      expect(result.sampleCount, 0);
    });

    test('ประเมินว่า GPS เสถียรเมื่อ Accuracy เฉลี่ยไม่เกิน 10 เมตร', () {
      final analyzer = GpsAiAnalyzer();

      for (var i = 0; i < 3; i++) {
        analyzer.analyze(
          now: now,
          fixTime: now.subtract(Duration(seconds: 3 - i)),
          accuracy: 5,
        );
      }

      final result = analyzer.analyze(
        now: now,
        fixTime: now.subtract(const Duration(seconds: 1)),
        accuracy: 5,
      );

      expect(result.status, 'GPS มีแนวโน้มเสถียร');
      expect(result.sampleCount, 3);
    });

    test('แจ้ง GPS ยังไม่นิ่งเมื่อ Accuracy เฉลี่ยเกิน 10 เมตร', () {
      final analyzer = GpsAiAnalyzer();
      final result = analyzer.analyze(
        now: now,
        fixTime: now.subtract(const Duration(seconds: 1)),
        accuracy: 15,
      );

      expect(result.status, 'GPS ยังไม่นิ่ง');
    });

    test('แจ้งความแม่นยำต่ำเมื่อ Accuracy เกิน 20 เมตร', () {
      final analyzer = GpsAiAnalyzer();
      final result = analyzer.analyze(
        now: now,
        fixTime: now.subtract(const Duration(seconds: 1)),
        accuracy: 25,
      );

      expect(result.status, 'ความแม่นยำ GPS ต่ำ');
    });

    test('แจ้ง GPS ขาดช่วงเมื่อไม่มี fix เกิน 10 วินาที', () {
      final analyzer = GpsAiAnalyzer();
      final result = analyzer.analyze(
        now: now,
        fixTime: now.subtract(const Duration(seconds: 11)),
        accuracy: 5,
      );

      expect(result.status, 'GPS ขาดช่วง');
    });

    test('ไม่นับ timestamp เดิมซ้ำ', () {
      final analyzer = GpsAiAnalyzer();
      final fixTime = now.subtract(const Duration(seconds: 1));

      analyzer.analyze(
        now: now,
        fixTime: fixTime,
        accuracy: 5,
      );

      final result = analyzer.analyze(
        now: now,
        fixTime: fixTime,
        accuracy: 6,
      );

      expect(result.sampleCount, 1);
    });

    test('ไม่รับ Accuracy ที่เป็นค่าลบหรือไม่ใช่ค่าจริง', () {
      final analyzer = GpsAiAnalyzer();
      final result = analyzer.analyze(
        now: now,
        fixTime: now.subtract(const Duration(seconds: 1)),
        accuracy: double.nan,
      );

      expect(result.sampleCount, 0);
      expect(result.status, 'กำลังเรียนรู้ข้อมูล GPS');
    });

    test('เก็บข้อมูลไม่เกิน 20 จุด', () {
      final analyzer = GpsAiAnalyzer();

      for (var i = 20; i >= 1; i--) {
        analyzer.analyze(
          now: now,
          fixTime: now.subtract(Duration(seconds: i)),
          accuracy: 5,
        );
      }

      final result = analyzer.analyze(
        now: now,
        fixTime: now.subtract(const Duration(seconds: 1)),
        accuracy: 5,
      );

      expect(result.sampleCount, 20);
    });
  });
}

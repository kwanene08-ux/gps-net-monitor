class GpsAiReport {
  final String status;
  final String detail;
  final int sampleCount;

  const GpsAiReport({
    required this.status,
    required this.detail,
    required this.sampleCount,
  });
}

/// วิเคราะห์คุณภาพ GPS ภายในเครื่องด้วยกฎและสถิติ
/// ไม่ส่งพิกัดออกเครือข่าย และไม่เปลี่ยนการตั้งค่า Android
class GpsAiAnalyzer {
  static const int maxSamples = 20;
  static const double unstableThreshold = 10.0;
  static const double poorThreshold = 20.0;
  static const double staleSeconds = 10.0;

  final List<double> _samples = <double>[];
  DateTime? _lastSampleTime;

  GpsAiReport analyze({
    required DateTime now,
    required DateTime? fixTime,
    required double? accuracy,
  }) {
    if (fixTime != null &&
        accuracy != null &&
        accuracy.isFinite &&
        accuracy >= 0) {
      final previous = _lastSampleTime;

      // เก็บเฉพาะตำแหน่งใหม่ ไม่เก็บซ้ำระหว่าง Dashboard refresh
      if (previous == null || fixTime.isAfter(previous)) {
        _samples.add(accuracy);
        _lastSampleTime = fixTime;

        if (_samples.length > maxSamples) {
          _samples.removeAt(0);
        }
      }
    }

    if (fixTime == null) {
      return GpsAiReport(
        status: 'กำลังรอข้อมูล GPS',
        detail: 'ยังไม่มีเวลาของตำแหน่ง GPS ล่าสุด',
        sampleCount: _samples.length,
      );
    }

    final age = now.difference(fixTime).inMilliseconds / 1000.0;

    if (!age.isFinite || age < -5) {
      return GpsAiReport(
        status: 'เวลา GPS ผิดปกติ',
        detail: 'เวลาของตำแหน่ง GPS ไม่สอดคล้องกับเวลาปัจจุบัน',
        sampleCount: _samples.length,
      );
    }

    if (age > staleSeconds) {
      return GpsAiReport(
        status: 'GPS ขาดช่วง',
        detail: 'ไม่มีตำแหน่งใหม่เกิน 10 วินาที',
        sampleCount: _samples.length,
      );
    }

    if (_samples.isEmpty) {
      return const GpsAiReport(
        status: 'กำลังเรียนรู้ข้อมูล GPS',
        detail: 'รอข้อมูล Accuracy ที่ถูกต้อง',
        sampleCount: 0,
      );
    }

    final average =
        _samples.reduce((a, b) => a + b) / _samples.length;

    final averageText = average.toStringAsFixed(1);

    if (average > poorThreshold) {
      return GpsAiReport(
        status: 'ความแม่นยำ GPS ต่ำ',
        detail: 'Accuracy เฉลี่ย ±$averageText เมตร',
        sampleCount: _samples.length,
      );
    }

    if (average > unstableThreshold) {
      return GpsAiReport(
        status: 'GPS ยังไม่นิ่ง',
        detail: 'Accuracy เฉลี่ย ±$averageText เมตร',
        sampleCount: _samples.length,
      );
    }

    return GpsAiReport(
      status: 'GPS มีแนวโน้มเสถียร',
      detail: 'Accuracy เฉลี่ย ±$averageText เมตร',
      sampleCount: _samples.length,
    );
  }
}

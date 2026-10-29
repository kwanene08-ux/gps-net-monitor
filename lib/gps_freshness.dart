class GpsFreshness {
  GpsFreshness._();

  static const double freshLimitSeconds = 3.0;
  static const double speedMaxAgeSeconds = 5.0;
  static const double staleLimitSeconds = 10.0;

  static double? ageSeconds(DateTime? fixTime, DateTime now) {
    if (fixTime == null) return null;
    final microseconds = now.difference(fixTime).inMicroseconds;
    if (microseconds <= 0) return 0.0;
    return microseconds / Duration.microsecondsPerSecond;
  }

  static bool isFresh(double? age) =>
      age != null &&
      age.isFinite &&
      age >= 0 &&
      age <= freshLimitSeconds;

  static bool canUseSpeed(double? age) =>
      age != null &&
      age.isFinite &&
      age >= 0 &&
      age <= speedMaxAgeSeconds;

  static String status({
    required double? ageSeconds,
    required double? accuracy,
  }) {
    final age = ageSeconds;
    if (age == null || !age.isFinite || age < 0) {
      return 'ไม่มีข้อมูล GPS';
    }
    if (age > staleLimitSeconds) return 'ข้อมูล GPS เก่า';
    if (age > speedMaxAgeSeconds) return 'GPS ล่าช้า';

    if (accuracy == null ||
        !accuracy.isFinite ||
        accuracy < 0) {
      return 'Accuracy ใช้ไม่ได้';
    }
    if (accuracy > 10) return 'GPS คลาดเคลื่อน';
    if (age > freshLimitSeconds) return 'GPS เริ่มล่าช้า';
    return 'GPS สด';
  }
}

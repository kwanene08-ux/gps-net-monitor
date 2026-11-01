import 'package:flutter/services.dart';

class GpsProvider {
  static const EventChannel _channel =
      EventChannel('gps_net_monitor/gps_provider');

  static Stream<Map<String, dynamic>> getPositionStream() {
    return _channel.receiveBroadcastStream().map((dynamic event) {
      if (event is! Map) {
        throw const FormatException('ข้อมูล GPS_PROVIDER ไม่ใช่ Map');
      }
      return Map<String, dynamic>.from(event);
    });
  }
}

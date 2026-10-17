// จุดต่อยอดสำหรับ alert notification แยกจาก ongoing notification
// การแจ้งเตือนเหตุการณ์ยังไม่เปิดใช้ใน starter นี้ เพื่อไม่สร้าง false alarm
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin plugin = FlutterLocalNotificationsPlugin();
  static Future<void> init() async {
    const settings = InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher'));
    await plugin.initialize(settings);
  }
  static Future<void> alert(String title, String body) async {
    const details = NotificationDetails(android: AndroidNotificationDetails('gps_monitor_alerts','GPS Net Monitor Alerts',channelDescription:'แจ้งเตือน GPS และเครือข่าย',importance:Importance.high,priority:Priority.high));
    await plugin.show(DateTime.now().millisecondsSinceEpoch.remainder(100000),title,body,details);
  }
}

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(GpsMonitorTaskHandler());

class GpsMonitorTaskHandler extends TaskHandler {
  Position? _lastAccepted;
  DateTime? _lastNetRead;
  String _network = 'N/A';
  int? _dbm; // ยังไม่อ่าน dBm เพราะ telephony permission/API ต่างกันตามรุ่น
  DateTime? _lastAlert;

  @override Future<void> onStart(DateTime timestamp, TaskStarter starter) async { await _publish(null); }
  @override Future<void> onRepeatEvent(DateTime timestamp) async {
    Position? p;
    try {
      p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        forceAndroidLocationManager: true,
        timeLimit: const Duration(seconds: 2),
      );
    } catch (_) {}
    if (p != null && p.accuracy <= 100) {
      final last = _lastAccepted;
      if (last != null) {
        final seconds = p.timestamp.difference(last.timestamp).inMilliseconds.abs()/1000.0;
        final distance = Geolocator.distanceBetween(last.latitude,last.longitude,p.latitude,p.longitude);
        final speed = seconds > 0 ? distance/seconds : 0.0;
        if (speed > 60) { await _alertOnce('⚠️ GPS กระโดด! จุดเกิน 216 กม./ชม.'); p = last; }
      }
      _lastAccepted = p;
    } else { p = _lastAccepted; }
    if (_lastNetRead == null || timestamp.difference(_lastNetRead!) >= const Duration(seconds:3)) {
      try { final c = await Connectivity().checkConnectivity(); _network = c.map((e)=>e.name).join(', '); if (_network.isEmpty) _network='none'; }
      catch (_) { _network='N/A'; }
      _lastNetRead = timestamp;
    }
    await _publish(p);
  }
  Future<void> _publish(Position? p) async {
    final data = <String,dynamic>{'accuracy':p?.accuracy,'latitude':p?.latitude,'longitude':p?.longitude,'speedKmh':p == null ? null : math.max(0,p.speed*3.6),'provider':'gps','network':_network,'dbm':_dbm,'carrier':'N/A','satellites':'N/A','timestamp':DateTime.now().toIso8601String()};
    FlutterForegroundTask.sendDataToMain(data);
    final acc = p == null ? 'N/A' : '±${p.accuracy.toStringAsFixed(1)}ม.';
    await FlutterForegroundTask.updateService(notificationTitle:'🟢 GPS Net Monitor — กำลังทำงาน',notificationText:'GPS $acc | 📶 $_network ${_dbm ?? 'N/A'} dBm');
  }
  Future<void> _alertOnce(String message) async { final now=DateTime.now(); if(_lastAlert!=null && now.difference(_lastAlert!)<const Duration(seconds:30))return; _lastAlert=now; /* ไม่เด้ง alert ซ้ำถี่; ใช้ log/notification service แยกเพิ่มได้ */ }
  @override Future<void> onDestroy(DateTime timestamp) async {}
  @override void onReceiveData(Object data) {}
  @override void onNotificationButtonPressed(String id) { if(id=='stop') FlutterForegroundTask.stopService(); }
  @override void onNotificationPressed() { FlutterForegroundTask.launchApp('/'); }
}

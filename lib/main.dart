import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'foreground_service.dart';
import 'notification_service.dart';

const githubRepo = 'kwanene08-ux/gps-net-monitor'; // เปลี่ยนเป็น owner/repo ของคุณ

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'gps_monitor_service', channelName: 'GPS Net Monitor',
      channelDescription: 'ติดตาม GPS และเครือข่ายขณะทำงาน',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW, onlyAlertOnce: true,
      playSound: false, enableVibration: false,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(3000),
      autoRunOnBoot: false, allowWakeLock: true,
    ),
  );
  runApp(const WithForegroundTask(child: GPSNetMonitorApp()));
}

class GPSNetMonitorApp extends StatelessWidget {
  const GPSNetMonitorApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'GPS Net Monitor', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: const Dashboard(),
  );
}

class Dashboard extends StatefulWidget { const Dashboard({super.key}); @override State<Dashboard> createState() => _DashboardState(); }
class _DashboardState extends State<Dashboard> {
  Map<String, dynamic> _data = {};
  bool _running = false, _checking = false;
  String _updateText = 'กดเพื่อเช็คเวอร์ชัน';
  final List<String> _logs = [];
  DateTime? _started;
  Timer? _refreshTimer;
  DateTime? _lastNativePoll;
  bool _nativeBusy = false;
  bool _agpsBusy = false;
  String _agpsStatus = 'ยังไม่ได้สั่งอัปเดต A-GPS';
  bool _gpsLocked = false;
  bool _gpsLockBusy = false;
  String _gpsLockStatus = 'โหมดล็อก GPS ปิด';
  bool _serviceBusy = false;

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    _restore();
    unawaited(_refreshNativeStatus());
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final rawFixTime = _data['fixTimestamp'];
      final fixTime = rawFixTime is String ? DateTime.tryParse(rawFixTime) : null;
      if (fixTime != null) {
        final diff = DateTime.now().difference(fixTime).inSeconds;
        final age = diff < 0 ? 0 : diff;
        final fresh = age <= 10;
        final rawAccuracy = _data['accuracy'];
        final accuracy = rawAccuracy is num ? rawAccuracy.toDouble() : null;
        final gpsStatus = !fresh
            ? 'ข้อมูล GPS เก่า'
            : accuracy == null || !accuracy.isFinite
                ? 'ไม่มีข้อมูล GPS'
                : accuracy > 10
                    ? 'GPS คลาดเคลื่อน'
                    : 'GPS ดี';

        if (_data['ageSeconds'] != age ||
            _data['gpsFresh'] != fresh ||
            _data['gpsStatus'] != gpsStatus) {
          setState(() {
            _data = {
              ..._data,
              'ageSeconds': age,
              'gpsFresh': fresh,
              'gpsStatus': gpsStatus,
            };
          });
        }
      }
      final lastPoll = _lastNativePoll;
      if (lastPoll == null || DateTime.now().difference(lastPoll) >= const Duration(seconds: 2)) {
        unawaited(_refreshNativeStatus());
      }
    });
  }

  Future<void> _refreshNativeStatus() async {
    if (_nativeBusy) return;
    _nativeBusy = true;
    _lastNativePoll = DateTime.now();
    try {
      final status = await const MethodChannel('gps_net_monitor/native_status')
          .invokeMapMethod<String, dynamic>('getNativeStatus');
      if (!mounted || status == null) return;
      setState(() => _data = {..._data, ...status});
    } catch (e) {
      debugPrint('อ่านสถานะ Android ไม่สำเร็จ: $e');
    } finally {
      _nativeBusy = false;
    }
  }

  void _onReceiveTaskData(Object d) {
    if (d is! Map) return;

    if (d['event'] == 'service_destroyed') {
      if (mounted) {
        setState(() {
          _running = false;
          _gpsLocked = false;
          _gpsLockStatus = 'GPS Lock ปิด: บริการติดตามหยุดแล้ว';
        });
      }
      return;
    }

    if (d['event'] == 'gps_lock_status') {
      if (mounted) {
        setState(() {
          _gpsLocked = d['locked'] == true;
          _gpsLockStatus = (d['status'] ?? 'สถานะล็อก GPS ไม่ทราบ').toString();
        });
      }
      return;
    }

    if (d['event'] == 'gps_jump_rejected') {
      unawaited(
        NotificationService.alert(
          'ตรวจพบ GPS กระโดด',
          'ระบบปฏิเสธตำแหน่งที่ผิดปกติแล้ว',
        ).catchError((Object error) {
          debugPrint('GPS alert failed: $error');
        }),
      );
      return;
    }

    if (mounted) {
      setState(() => _data = {..._data, ...Map<String, dynamic>.from(d)});
    }
  }
  Future<void> _restore() async {
    try {
      final running = await FlutterForegroundTask.isRunningService;
      if (!mounted) return;
      setState(() => _running = running);
      if (running) {
        FlutterForegroundTask.sendDataToTask({'action': 'gps_lock_status_request'});
      }
    } catch (e) {
      debugPrint('กู้คืนสถานะบริการไม่สำเร็จ: $e');
      _snack('อ่านสถานะบริการไม่สำเร็จ กรุณาลองเปิดแอปใหม่');
    }
  }
  void _log(String s) { final now = DateTime.now(); _logs.insert(0, '${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')} $s'); if (_logs.length > 30) _logs.removeLast(); }
  Future<void> _startStop() async {
    if (_serviceBusy || _gpsLockBusy) return;
    setState(() => _serviceBusy = true);
    try {
      final serviceRunning = await FlutterForegroundTask.isRunningService;
      if (_running || serviceRunning) {
        await FlutterForegroundTask.stopService();
        if (!mounted) return;
        setState(() {
          _running = false;
          _gpsLocked = false;
          _gpsLockStatus = 'GPS Lock ปิด: บริการติดตามหยุดแล้ว';
        });
        _log('หยุดติดตาม');
        _snack('หยุดบริการติดตามแล้ว');
        return;
      }

      final loc = await Permission.locationWhenInUse.request();
      if (!loc.isGranted) {
        _snack('ต้องอนุญาตตำแหน่งก่อน');
        return;
      }

      if (Platform.isAndroid) {
        await Permission.notification.request();
        if (!(await Permission.phone.status).isGranted) {
          await Permission.phone.request();
        }
      }

      final bg = await Permission.locationAlways.status;
      if (!bg.isGranted) {
        _snack('หากต้องการติดตามตอนปิดจอ ให้ตั้งสิทธิ์ตำแหน่งเป็น “อนุญาตตลอดเวลา” ในการตั้งค่าแอป');
      }

      final result = await FlutterForegroundTask.startService(
        serviceId: 7001,
        notificationTitle: '🟢 GPS Net Monitor — กำลังทำงาน',
        notificationText: 'กำลังเริ่มอ่าน GPS…',
        notificationButtons: [const NotificationButton(id: 'stop', text: 'หยุด')],
        callback: startCallback,
      );

      if (result is ServiceRequestSuccess) {
        if (!mounted) return;
        setState(() {
          _running = true;
          _started = DateTime.now();
        });
        _log('เริ่มติดตาม');
        _snack('เริ่มบริการติดตามแล้ว');
      } else {
        _snack('เริ่มบริการไม่สำเร็จ: $result');
      }
    } catch (e) {
      debugPrint('Start/stop service failed: $e');
      _snack('สั่งเริ่มหรือหยุดบริการไม่สำเร็จ: $e');
      try {
        final running = await FlutterForegroundTask.isRunningService;
        if (mounted) setState(() => _running = running);
      } catch (_) {
        // Keep last-known state if Android cannot report service status.
      }
    } finally {
      if (mounted) setState(() => _serviceBusy = false);
    }
  }
  void _snack(String s) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s))); }
  Future<void> _settings(String type) async {
    try {
      if (type == 'location') {
        await Geolocator.openLocationSettings();
      } else {
        await openAppSettings();
      }
    } catch (e) {
      debugPrint('เปิดการตั้งค่าไม่สำเร็จ: $e');
      _snack('เปิดการตั้งค่าไม่สำเร็จ กรุณาเปิดจากการตั้งค่าโทรศัพท์');
    }
  }
  Future<void> _toggleGpsLock() async {
    if (_gpsLockBusy) return;
    if (_serviceBusy) {
      _snack('รอให้การเริ่มหรือหยุดบริการเสร็จก่อน');
      return;
    }
    final enable = !_gpsLocked;
    setState(() {
      _gpsLockBusy = true;
      _gpsLockStatus = enable ? 'กำลังเปิดโหมดล็อก GPS…' : 'กำลังปลดล็อก GPS…';
    });
    try {
      final loc = await Permission.locationWhenInUse.request();
      if (!loc.isGranted) {
        _snack('ต้องอนุญาตตำแหน่งก่อนใช้โหมดล็อก GPS');
        return;
      }

      var running = await FlutterForegroundTask.isRunningService;
      if (enable && !running) {
        await Permission.notification.request();
        if (!(await Permission.phone.status).isGranted) {
          await Permission.phone.request();
        }
        final bg = await Permission.locationAlways.status;
        if (!bg.isGranted) {
          _snack('หากต้องการใช้ตอนปิดจอ ให้ตรวจสิทธิ์ตำแหน่งและการทำงานเบื้องหลังของแอป');
        }
        final result = await FlutterForegroundTask.startService(
          serviceId: 7001,
          notificationTitle: '🟢 GPS Net Monitor — กำลังเปิดล็อก GPS',
          notificationText: 'กำลังเริ่มบริการตำแหน่ง…',
          notificationButtons: [const NotificationButton(id: 'stop', text: 'หยุด')],
          callback: startCallback,
        );
        if (result is! ServiceRequestSuccess) {
          _snack('เริ่มบริการ GPS ไม่สำเร็จ: $result');
          return;
        }
        running = true;
        if (mounted) {
          setState(() {
            _running = true;
            _started ??= DateTime.now();
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      if (!running) {
        if (mounted) {
          setState(() {
            _gpsLocked = false;
            _gpsLockStatus = 'GPS Lock ปิด: บริการติดตามไม่ได้ทำงาน';
          });
        }
        return;
      }

      FlutterForegroundTask.sendDataToTask({
        'action': 'gps_lock',
        'enabled': enable,
      });
      if (mounted) {
        setState(() {
          _gpsLocked = enable;
          _gpsLockStatus = enable
              ? 'กำลังเปิดรับตำแหน่ง GPS ต่อเนื่อง…'
              : 'กำลังกลับไปอ่าน GPS ตามรอบปกติ…';
        });
      }
      _log(enable ? 'เปิดโหมดล็อก GPS ต่อเนื่อง' : 'ปิดโหมดล็อก GPS');
    } catch (e) {
      final message = 'เปลี่ยนโหมดล็อก GPS ไม่สำเร็จ: $e';
      if (mounted) {
        setState(() {
          _gpsLockStatus = message;
        });
        _snack(message);
      }
    } finally {
      if (mounted) setState(() => _gpsLockBusy = false);
    }
  }


Future<void> _runAgpsAction({required bool reset}) async {
    if (_agpsBusy) return;
    if (reset) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('ยืนยัน Reset A-GPS?'),
          content: const Text(
            'คำสั่งนี้จะขอให้ระบบล้างข้อมูลช่วย GPS ทั้งหมดที่ผู้ให้บริการเปิดให้ล้างได้ '
            'อาจทำให้การหาตำแหน่งครั้งถัดไปช้าลง และไม่ใช่วิธีแก้ GPS กระโดดที่ควรกดเป็นประจำ',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('ยกเลิก'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('ยืนยันล้างข้อมูล'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() {
      _agpsBusy = true;
      _agpsStatus = reset ? 'กำลังส่งคำสั่ง Reset…' : 'กำลังส่งคำขออัปเดต A-GPS…';
    });
    try {
      final loc = await Permission.locationWhenInUse.request();
      if (!loc.isGranted) {
        throw PlatformException(code: 'location_permission', message: 'ต้องอนุญาตตำแหน่งแบบแม่นยำก่อน');
      }
      final result = await const MethodChannel('gps_net_monitor/native_status')
          .invokeMapMethod<String, dynamic>(reset ? 'resetAgps' : 'refreshAgps');
      final message = (result?['message'] ?? 'Android ไม่ส่งรายละเอียดผลลัพธ์กลับมา').toString();
      final displayMessage = result?['ok'] == true ? message : '⚠️ $message';
      if (mounted) {
        setState(() => _agpsStatus = displayMessage);
        _snack(displayMessage);
      }
    } on PlatformException catch (e) {
      final message = e.message ?? 'ไม่สามารถสั่งงาน A-GPS ได้';
      if (mounted) {
        setState(() => _agpsStatus = message);
        _snack(message);
      }
    } catch (e) {
      final message = 'สั่งงาน A-GPS ไม่สำเร็จ: $e';
      if (mounted) {
        setState(() => _agpsStatus = message);
        _snack(message);
      }
    } finally {
      if (mounted) setState(() => _agpsBusy = false);
    }
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    if (mounted) {
      setState(() {
        _checking = true;
        _updateText = 'กำลังตรวจสอบ…';
      });
    }

    try {
      final releaseUri = Uri.https(
        'api.github.com',
        '/repos/$githubRepo/releases/latest',
      );
      final releaseResponse = await http.get(
        releaseUri,
        headers: const {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      ).timeout(const Duration(seconds: 20));

      if (releaseResponse.statusCode != 200) {
        throw Exception('GitHub ตอบกลับ HTTP ${releaseResponse.statusCode}');
      }

      final decoded = jsonDecode(releaseResponse.body);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('ข้อมูล Release ไม่ถูกต้อง');
      }

      final latest = (decoded['tag_name'] ?? '')
          .toString()
          .replaceFirst(RegExp(r'^v'), '')
          .trim();
      if (latest.isEmpty) throw Exception('Release ไม่มีหมายเลขเวอร์ชัน');

      final current = (await PackageInfo.fromPlatform()).version;
      if (_compare(latest, current) <= 0) {
        if (mounted) setState(() => _updateText = '✅ ใช้เวอร์ชันล่าสุดแล้ว (v$current)');
        return;
      }

      final rawAssets = decoded['assets'];
      final assets = rawAssets is List ? rawAssets.whereType<Map>().toList() : <Map>[];
      Map? apk;
      for (final asset in assets) {
        if ((asset['name'] ?? '').toString() == 'app-release.apk') {
          apk = asset;
          break;
        }
      }
      if (apk == null) {
        for (final asset in assets) {
          if ((asset['name'] ?? '').toString().toLowerCase().endsWith('.apk')) {
            apk = asset;
            break;
          }
        }
      }
      if (apk == null) throw Exception('Release ไม่มีไฟล์ APK');

      final downloadUrl = Uri.tryParse((apk['browser_download_url'] ?? '').toString());
      if (downloadUrl == null ||
          downloadUrl.scheme != 'https' ||
          downloadUrl.host != 'github.com') {
        throw Exception('ลิงก์ดาวน์โหลด APK ไม่ถูกต้อง');
      }

      if (mounted) setState(() => _updateText = '🔄 พบ v$latest — กำลังดาวน์โหลด APK');
      final downloadResponse = await http.get(downloadUrl)
          .timeout(const Duration(minutes: 3));
      if (downloadResponse.statusCode != 200 || downloadResponse.bodyBytes.isEmpty) {
        throw Exception('ดาวน์โหลด APK ไม่สำเร็จ (HTTP ${downloadResponse.statusCode})');
      }

      final directory = await getExternalStorageDirectory() ??
          await getApplicationSupportDirectory();
      final file = File('${directory.path}/gps-net-monitor-update.apk');
      await file.writeAsBytes(downloadResponse.bodyBytes, flush: true);
      final size = await file.length();
      if (size < 1000000) {
        await file.delete();
        throw Exception('ไฟล์ APK ที่ดาวน์โหลดมีขนาดผิดปกติ');
      }

      if (mounted) setState(() => _updateText = 'ดาวน์โหลด v$latest แล้ว — กำลังเปิดตัวติดตั้ง');
      final openResult = await OpenFilex.open(file.path);
      if (mounted) {
        final opened = openResult.type.toString().toLowerCase().contains('done');
        final message = opened
            ? 'เปิดตัวติดตั้งสำหรับ v$latest แล้ว กรุณายืนยันติดตั้ง'
            : 'ดาวน์โหลด v$latest แล้ว แต่เปิดตัวติดตั้งไม่สำเร็จ: ${openResult.message}';
        setState(() => _updateText = message);
      }
    } catch (e) {
      debugPrint('ตรวจอัปเดตไม่สำเร็จ: $e');
      if (mounted) setState(() => _updateText = 'ตรวจอัปเดตไม่ได้: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }
  int _compare(String a, String b) {
    List<int> parts(String value) => value
        .split('.')
        .map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final left = parts(a);
    final right = parts(b);
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final x = i < left.length ? left[i] : 0;
      final y = i < right.length ? right[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }
  @override
  void dispose() {
    _refreshTimer?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    super.dispose();
  }
  @override Widget build(BuildContext context) {
    final accuracy = (_data['accuracy'] as num?)?.toDouble(); final dbm = _data['dbm'] as int?;
    final gpsScore = accuracy == null ? 0 : accuracy <= 5 ? 50 : accuracy <= 15 ? 35 : accuracy <= 30 ? 15 : 0;
    final netScore = dbm == null ? 0 : dbm >= -80 ? 50 : dbm >= -100 ? 35 : dbm >= -110 ? 15 : 0;
    final gpsFresh = _data['gpsFresh'] == true;
    final accuracyText = !gpsFresh
        ? (accuracy == null
            ? 'ไม่มีข้อมูล'
            : 'ข้อมูลเก่า · ±${accuracy.toStringAsFixed(1)} ม.')
        : accuracy == null
            ? 'N/A'
            : accuracy > 10
                ? 'คลาดเคลื่อน · ±${accuracy.toStringAsFixed(1)} ม.'
                : '±${accuracy.toStringAsFixed(1)} ม.';
    final score = gpsScore + netScore;
    final color = !gpsFresh
        ? Colors.grey
        : score >= 80
            ? Colors.green
            : score >= 50
                ? Colors.orange
                : Colors.red;
    final status = !gpsFresh
        ? (_data['gpsStatus'] == 'ข้อมูล GPS เก่า'
            ? 'GPS ข้อมูลเก่า'
            : 'รอ GPS')
        : score >= 80
            ? 'พร้อมวิ่ง'
            : score >= 50
                ? 'ระวัง'
                : 'ตรวจสอบ GPS/สัญญาณ';
    return Scaffold(appBar: AppBar(title: const Text('GPS Net Monitor'), actions:[IconButton(onPressed:()=>_settings('app'), icon:const Icon(Icons.settings))]), body: ListView(padding: const EdgeInsets.all(16), children:[
      Card(color:color.withOpacity(.12), child: Padding(padding:const EdgeInsets.all(18), child:Row(children:[Icon(Icons.circle,color:color,size:20),const SizedBox(width:10),Expanded(child:Text(status,style:Theme.of(context).textTheme.titleLarge)),Text(gpsFresh ? '$score / 100' : 'N/A',style:Theme.of(context).textTheme.titleLarge)]))),
      _card('🛰️ GPS', [ 'สถานะ GPS: ${_data['gpsStatus'] ?? 'รอข้อมูล GPS'}',
        'อายุข้อมูล: ${_data['ageSeconds'] == null ? 'กำลังรอข้อมูล GPS' : '${_data['ageSeconds']} วินาที'}',
        'ดาวเทียม: ${_satelliteText()}', 'Accuracy: $accuracyText', 'ความเร็ว: ${_data['speedKmh'] == null ? 'N/A' : '${(_data['speedKmh'] as num).toStringAsFixed(1)} กม./ชม.'}', 'Latitude: ${_data['latitude'] ?? 'N/A'}', 'Longitude: ${_data['longitude'] ?? 'N/A'}', 'Provider: ${_data['provider'] ?? 'gps (รอข้อมูล)'}' ]),
      _card('📶 เครือข่าย', [
        'อุปกรณ์: ${_data['device'] ?? 'กำลังอ่านข้อมูล…'}',
        'ชนิดเครือข่าย: ${_data['networkType'] ?? _data['network'] ?? 'กำลังอ่านข้อมูล…'}',
        'สัญญาณ: ${dbm == null ? (_data['phonePermissionGranted'] == false ? 'อนุญาตสิทธิ์โทรศัพท์ก่อน' : 'ยังอ่านค่าไม่ได้') : '$dbm dBm'}',
        'ผู้ให้บริการ: ${(_data['carrier'] ?? '').toString().trim().isEmpty ? 'ยังอ่านค่าไม่ได้ (ตรวจ SIM/สิทธิ์โทรศัพท์)' : _data['carrier']}',
        'สถานะเซลล์: ${_data['lteCellStatus'] ?? 'ยังไม่มีข้อมูล'}',
        'CI: ${_radioValue('lteCi')}',
        'eNB ID : CID: ${_radioValue('lteEnbId')} : ${_radioValue('lteCid')}',
        'TAC: ${_radioValue('lteTac')}',
        'PCI: ${_radioValue('ltePci')}',
        'BW: ${_bandwidthText()}',
        'EARFCN: ${_radioValue('lteEarfcn')}',
        'RSSI: ${_radioValue('lteRssi', ' dBm')}',
        'RSRP: ${_radioValue('lteRsrp', ' dBm')}',
        'RSRQ: ${_radioValue('lteRsrq', ' dB')}',
        'SNR: ${_radioValue('lteSnr', ' dB')}',
        'TA: ${_radioValue('lteTa')}',
      ]),
      Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('สถานะบริการ: ${_running ? 'ทำงานเบื้องหลัง' : 'หยุดอยู่'}'),Text('เริ่มมา: ${_started == null ? 'ไม่ทราบ' : _elapsed(DateTime.now().difference(_started!))}'),const SizedBox(height:12),SizedBox(width:double.infinity,height:56,child:FilledButton.icon(style:FilledButton.styleFrom(backgroundColor:_running?Colors.red:Colors.green),onPressed:(_serviceBusy||_gpsLockBusy)?null:_startStop,icon:(_serviceBusy||_gpsLockBusy)?const SizedBox(width:20,height:20,child:CircularProgressIndicator(strokeWidth:2)):Icon(_running?Icons.stop:Icons.play_arrow),label:Text((_serviceBusy||_gpsLockBusy)?'กำลังดำเนินการ…':_running?'⏹️ หยุดติดตาม':'▶️ เริ่มติดตาม')))]))),
      Wrap(spacing:8,runSpacing:8,children:[
        OutlinedButton.icon(onPressed:()=>_settings('location'),icon:const Icon(Icons.location_on),label:const Text('ตั้งค่า GPS')),
        OutlinedButton.icon(onPressed:()=>_settings('app'),icon:const Icon(Icons.battery_saver),label:const Text('ตั้งค่าแอป')),
        OutlinedButton.icon(onPressed:_checking?null:_checkUpdate,icon:const Icon(Icons.system_update),label:const Text('เช็คอัปเดต')),
        FilledButton.icon(onPressed:_agpsBusy?null:()=>_runAgpsAction(reset:false),icon:const Icon(Icons.satellite_alt),label:const Text('อัปเดต A-GPS')),
        FilledButton.icon(onPressed:_gpsLockBusy?null:_toggleGpsLock,icon:Icon(_gpsLocked?Icons.lock_open:Icons.lock),label:Text(_gpsLockBusy?'กำลังทำงาน…':_gpsLocked?'ปลดล็อก GPS':'ล็อก GPS')),
        OutlinedButton.icon(onPressed:_agpsBusy?null:()=>_runAgpsAction(reset:true),icon:const Icon(Icons.restart_alt),label:const Text('Reset A-GPS')),
      ]),
      Padding(padding:const EdgeInsets.symmetric(vertical:4),child:Text(_agpsStatus,style:const TextStyle(fontSize:12))),
      Padding(padding:const EdgeInsets.symmetric(vertical:4),child:Text('🔒 GPS Lock: $_gpsLockStatus',style:const TextStyle(fontSize:12))),
      const Padding(padding:EdgeInsets.only(bottom:6),child:Text('โหมดล็อกจะขอตำแหน่งต่อเนื่องขณะบริการทำงาน',style:TextStyle(fontSize:11))),
      Padding(padding:const EdgeInsets.symmetric(vertical:8),child:Text(_updateText,style:const TextStyle(fontSize:12))),
      Text('📋 ประวัติวันนี้',style:Theme.of(context).textTheme.titleMedium), if(_logs.isEmpty) const Text('ยังไม่มีเหตุการณ์ในเซสชันนี้'), ..._logs.map((s)=>ListTile(dense:true,leading:const Icon(Icons.history),title:Text(s))),
    ]));
  }
  Widget _card(String title,List<String> lines)=>Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold)),const Divider(),...lines.map((s)=>Padding(padding:const EdgeInsets.symmetric(vertical:3),child:Text(s)))])));
  String _radioValue(String key, [String suffix = '']) {
    final value = _data[key];
    if (value is! num) return 'N/A';
    return '${value.toString()}$suffix';
  }

  String _bandwidthText() {
    final value = _data['lteBandwidthKhz'];
    if (value is! num || value <= 0) return 'N/A';
    return '${(value / 1000).toStringAsFixed(1)} MHz';
  }

  String _satelliteText() {
    final visible = _data['satellites'];
    final used = _data['satellitesUsed'];
    if (visible is num && visible > 0) {
      return '${visible.toInt()} ดวง${used is num ? ' (ใช้ ${used.toInt()})' : ''}';
    }
    return (_data['satelliteStatus'] ?? 'กำลังค้นหาดาวเทียม…').toString();
  }

  String _elapsed(Duration d) { if(d.inSeconds<0)return '0 นาที'; if(d.inHours>0)return '${d.inHours} ชม. ${d.inMinutes%60} นาที'; return '${d.inMinutes} นาที'; }
}

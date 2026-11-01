import 'dart:async';
import 'dart:io';

class Ipv4NetworkMonitor {
  static const String host = 'www.google.com';
  static const int port = 443;

  static const Duration dnsTimeout = Duration(seconds: 3);
  static const Duration tcpTimeout = Duration(seconds: 4);
  static const int historyLimit = 20;

  bool _running = false;
  final List<_Ipv4Sample> _history = [];

  Future<Map<String, dynamic>?> check() async {
    if (_running) return null;
    _running = true;

    final checkedAt = DateTime.now();
    String address = 'N/A';
    int? latencyMs;
    bool success = false;
    bool timeout = false;
    String status = 'กำลังตรวจสอบ';

    try {
      final addresses = await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv4,
      ).timeout(dnsTimeout);

      if (addresses.isEmpty) {
        throw const SocketException('ไม่พบ IPv4 address');
      }

      final ipv4 = addresses.firstWhere(
        (item) => item.type == InternetAddressType.IPv4,
      );
      address = ipv4.address;

      final stopwatch = Stopwatch()..start();
      Socket? socket;

      try {
        socket = await Socket.connect(
          ipv4,
          port,
          timeout: tcpTimeout,
        );
        stopwatch.stop();

        latencyMs = stopwatch.elapsedMilliseconds;
        success = true;
        status = 'เชื่อมต่อ TCP สำเร็จ';
      } finally {
        socket?.destroy();
      }
    } on TimeoutException {
      timeout = true;
      status = 'หมดเวลารอ DNS/TCP';
    } on SocketException catch (error) {
      final message = error.message.toLowerCase();
      timeout = message.contains('timed out') ||
          message.contains('timeout');
      status = timeout ? 'TCP Timeout' : 'เชื่อมต่อไม่สำเร็จ';
    } catch (error) {
      status = 'ตรวจสอบไม่สำเร็จ: ${error.runtimeType}';
    } finally {
      _running = false;
    }

    _history.add(
      _Ipv4Sample(
        time: checkedAt,
        address: address,
        latencyMs: latencyMs,
        success: success,
        timeout: timeout,
        status: status,
      ),
    );

    if (_history.length > historyLimit) {
      _history.removeRange(0, _history.length - historyLimit);
    }

    final successCount = _history.where((item) => item.success).length;
    final successRate = _history.isEmpty
        ? 0.0
        : successCount * 100.0 / _history.length;

    return {
      'ipv4Status': status,
      'ipv4Host': host,
      'ipv4Port': port,
      'ipv4Address': address,
      'ipv4TcpLatencyMs': latencyMs,
      'ipv4Timeout': timeout,
      'ipv4Success': success,
      'ipv4SuccessRate': successRate,
      'ipv4Samples': _history.length,
      'ipv4CheckedAt': checkedAt.toIso8601String(),
      'ipv4History': _history
          .map((item) => item.toMap())
          .toList(growable: false),
    };
  }
}

class _Ipv4Sample {
  const _Ipv4Sample({
    required this.time,
    required this.address,
    required this.latencyMs,
    required this.success,
    required this.timeout,
    required this.status,
  });

  final DateTime time;
  final String address;
  final int? latencyMs;
  final bool success;
  final bool timeout;
  final String status;

  Map<String, dynamic> toMap() => {
        'time': time.toIso8601String(),
        'address': address,
        'latencyMs': latencyMs,
        'success': success,
        'timeout': timeout,
        'status': status,
      };
}

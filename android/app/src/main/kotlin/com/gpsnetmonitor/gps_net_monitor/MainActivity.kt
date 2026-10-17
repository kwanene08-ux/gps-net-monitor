package com.gpsnetmonitor.gps_net_monitor

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.location.GnssStatus
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "gps_net_monitor/native_status"
    }

    private var gnssRegistered = false
    private var satelliteStatusReceived = false
    private var visibleSatelliteCount = 0
    private var satellitesUsedInFix = 0

    private val gnssCallback = object : GnssStatus.Callback() {
        override fun onSatelliteStatusChanged(status: GnssStatus) {
            var used = 0
            for (index in 0 until status.satelliteCount) {
                if (status.usedInFix(index)) used++
            }
            visibleSatelliteCount = status.satelliteCount
            satellitesUsedInFix = used
            satelliteStatusReceived = true
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getNativeStatus") {
                    result.success(readNativeStatus())
                } else {
                    result.notImplemented()
                }
            }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun readNativeStatus(): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        result["device"] = "${Build.MANUFACTURER} ${Build.MODEL}".trim()

        val fineLocationGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (fineLocationGranted && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                if (!gnssRegistered) {
                    val manager = getSystemService(LOCATION_SERVICE) as LocationManager
                    gnssRegistered = manager.registerGnssStatusCallback(
                        gnssCallback, Handler(Looper.getMainLooper())
                    )
                }
            } catch (_: SecurityException) {
                gnssRegistered = false
            } catch (_: RuntimeException) {
                gnssRegistered = false
            }
        }

        result["satellites"] = if (satelliteStatusReceived) visibleSatelliteCount else null
        result["satellitesUsed"] = if (satelliteStatusReceived) satellitesUsedInFix else null
        result["satelliteStatus"] = when {
            !fineLocationGranted -> "ต้องอนุญาตตำแหน่งแบบแม่นยำ"
            !gnssRegistered -> "กำลังเปิดอ่าน GNSS"
            !satelliteStatusReceived -> "กำลังค้นหาดาวเทียม…"
            visibleSatelliteCount == 0 -> "ยังไม่พบดาวเทียม"
            else -> "รับข้อมูลดาวเทียมแล้ว"
        }

        val phoneGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.READ_PHONE_STATE
        ) == PackageManager.PERMISSION_GRANTED
        result["phonePermissionGranted"] = phoneGranted

        if (phoneGranted) {
            try {
                val telephony = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
                val carrier = telephony.networkOperatorName.takeIf { it.isNotBlank() }
                    ?: telephony.simOperatorName.takeIf { it.isNotBlank() }
                result["carrier"] = carrier

                val networkType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    telephony.dataNetworkType
                } else {
                    telephony.networkType
                }
                result["networkType"] = networkTypeLabel(networkType)

                val dbm: Int? = when {
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> telephony.signalStrength
                        ?.cellSignalStrengths
                        ?.map { it.dbm }
                        ?.filter { it < 0 && it >= -200 }
                        ?.maxOrNull()
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.P -> telephony.signalStrength
                        ?.dbm
                        ?.takeIf { it < 0 && it >= -200 }
                    else -> null
                }
                result["dbm"] = dbm
            } catch (_: SecurityException) {
                result["carrier"] = null
                result["networkType"] = null
                result["dbm"] = null
                result["phonePermissionGranted"] = false
            } catch (_: RuntimeException) {
                result["carrier"] = null
                result["networkType"] = null
                result["dbm"] = null
            }
        } else {
            result["carrier"] = null
            result["networkType"] = null
            result["dbm"] = null
        }
        return result
    }

    private fun networkTypeLabel(type: Int): String = when (type) {
        1, 2, 4, 7, 11, 16 -> "2G"
        3, 5, 6, 8, 9, 10, 12, 14, 15, 17, 18 -> "3G"
        13, 19 -> "4G LTE"
        20 -> "5G NR"
        else -> "ไม่ทราบชนิดเครือข่าย"
    }

    override fun onDestroy() {
        if (gnssRegistered && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                (getSystemService(LOCATION_SERVICE) as LocationManager)
                    .unregisterGnssStatusCallback(gnssCallback)
            } catch (_: RuntimeException) {
            }
        }
        gnssRegistered = false
        super.onDestroy()
    }
}

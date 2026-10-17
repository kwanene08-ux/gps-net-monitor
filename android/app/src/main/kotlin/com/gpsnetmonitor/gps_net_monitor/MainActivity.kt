package com.gpsnetmonitor.gps_net_monitor

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.location.GnssStatus
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telephony.TelephonyManager
import android.telephony.CellInfoLte
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
                when (call.method) {
                    "getNativeStatus" -> result.success(readNativeStatus())
                    "refreshAgps" -> result.success(refreshAgpsCommands())
                    "resetAgps" -> result.success(resetAgpsData())
                    else -> result.notImplemented()
                }
            }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun refreshAgpsCommands(): Map<String, Any?> {
        val fineLocationGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        if (!fineLocationGranted) {
            return mapOf("ok" to false, "message" to "ต้องอนุญาตตำแหน่งแบบแม่นยำก่อน")
        }
        return try {
            val manager = getSystemService(LOCATION_SERVICE) as LocationManager
            if (!manager.allProviders.contains(LocationManager.GPS_PROVIDER)) {
                return mapOf("ok" to false, "message" to "อุปกรณ์ไม่เปิดเผย GPS provider")
            }
            if (!manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                return mapOf("ok" to false, "message" to "กรุณาเปิดบริการตำแหน่ง/GPS ก่อน")
            }
            // Provider-specific extension commands. Some OEM providers may ignore them.
            try {
                manager.sendExtraCommand(LocationManager.GPS_PROVIDER, "force_time_injection", Bundle())
            } catch (_: RuntimeException) {
                // Continue to attempt the XTRA request independently.
            }
            try {
                manager.sendExtraCommand(LocationManager.GPS_PROVIDER, "force_xtra_injection", Bundle())
            } catch (_: RuntimeException) {
                return mapOf(
                    "ok" to false,
                    "message" to "ส่งคำสั่ง A-GPS ไม่สำเร็จ ผู้ให้บริการ GPS อาจไม่รองรับ"
                )
            }
            mapOf(
                "ok" to true,
                "message" to "ส่งคำขออัปเดตเวลาและ A-GPS แล้ว แต่ Android ไม่ยืนยันว่าดาวน์โหลดข้อมูลสำเร็จ ให้เปิดเน็ตและรอสักครู่"
            )
        } catch (_: SecurityException) {
            mapOf("ok" to false, "message" to "Android ปฏิเสธสิทธิ์คำสั่งตำแหน่ง")
        } catch (_: RuntimeException) {
            mapOf("ok" to false, "message" to "ส่งคำสั่งไม่ได้ในอุปกรณ์นี้")
        }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun resetAgpsData(): Map<String, Any?> {
        val fineLocationGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        if (!fineLocationGranted) {
            return mapOf("ok" to false, "message" to "ต้องอนุญาตตำแหน่งแบบแม่นยำก่อน")
        }
        return try {
            val manager = getSystemService(LOCATION_SERVICE) as LocationManager
            if (!manager.allProviders.contains(LocationManager.GPS_PROVIDER)) {
                return mapOf("ok" to false, "message" to "อุปกรณ์ไม่เปิดเผย GPS provider")
            }
            // A null extras bundle means provider-defined deletion of all aiding data.
            manager.sendExtraCommand(LocationManager.GPS_PROVIDER, "delete_aiding_data", null)
            mapOf(
                "ok" to true,
                "message" to "ส่งคำขอล้างข้อมูลช่วย GPS แล้ว แต่ผู้ให้บริการอาจไม่รองรับ การจับตำแหน่งครั้งถัดไปอาจช้าลง"
            )
        } catch (_: SecurityException) {
            mapOf("ok" to false, "message" to "Android ปฏิเสธสิทธิ์คำสั่งตำแหน่ง")
        } catch (_: RuntimeException) {
            mapOf("ok" to false, "message" to "ล้างข้อมูลช่วย GPS ไม่สำเร็จในอุปกรณ์นี้")
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
        readLteCellInfo(result, phoneGranted && fineLocationGranted)

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

                val dbm: Int? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    telephony.signalStrength
                        ?.cellSignalStrengths
                        ?.map { it.dbm }
                        ?.filter { it < 0 && it >= -200 }
                        ?.maxOrNull()
                } else {
                    null
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


    private fun validCellValue(value: Int, min: Int, max: Int): Int? =
        value.takeIf { it != Int.MAX_VALUE && it in min..max }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun readLteCellInfo(result: MutableMap<String, Any?>, allowed: Boolean) {
        val keys = listOf(
            "lteCi", "lteEnbId", "lteCid", "lteTac", "ltePci", "lteBandwidthKhz",
            "lteEarfcn", "lteRssi", "lteRsrp", "lteRsrq", "lteSnr", "lteTa"
        )
        keys.forEach { result[it] = null }

        if (!allowed) {
            result["lteCellStatus"] = "ต้องอนุญาตตำแหน่งแม่นยำและสิทธิ์โทรศัพท์"
            return
        }

        try {
            val telephony = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
            val cells = telephony.allCellInfo.orEmpty()
            val lte = cells.filterIsInstance<CellInfoLte>().firstOrNull { it.isRegistered }

            if (lte == null) {
                result["lteCellStatus"] = if (cells.any { it.isRegistered }) {
                    "เครือข่ายที่ลงทะเบียนไม่รายงานเซลล์ LTE"
                } else {
                    "กำลังรอข้อมูลเซลล์จาก Android"
                }
                return
            }

            val identity = lte.cellIdentity
            val signal = lte.cellSignalStrength
            val ci = validCellValue(identity.ci, 0, 0x0FFFFFFF)
            result["lteCi"] = ci
            // LTE ECI is commonly split into eNB ID (upper bits) and local cell ID (8 lower bits).
            result["lteEnbId"] = ci?.ushr(8)
            result["lteCid"] = ci?.and(0xFF)
            result["lteTac"] = validCellValue(identity.tac, 0, 65535)
            result["ltePci"] = validCellValue(identity.pci, 0, 503)
            result["lteEarfcn"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                validCellValue(identity.earfcn, 0, 262143)
            } else null
            result["lteBandwidthKhz"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                validCellValue(identity.bandwidth, 1, 100000)
            } else null
            result["lteRssi"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                validCellValue(signal.rssi, -150, -40)
            } else null
            result["lteRsrp"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                validCellValue(signal.rsrp, -160, -30)
            } else null
            result["lteRsrq"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                validCellValue(signal.rsrq, -40, 0)
            } else null
            result["lteSnr"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                validCellValue(signal.rssnr, -20, 30)
            } else null
            result["lteTa"] = validCellValue(signal.timingAdvance, 0, 1282)
            result["lteCellStatus"] = "อ่านข้อมูลเซลล์ LTE ที่ลงทะเบียนแล้ว"
        } catch (_: SecurityException) {
            result["lteCellStatus"] = "Android ไม่อนุญาตให้อ่านข้อมูลเซลล์"
        } catch (_: RuntimeException) {
            result["lteCellStatus"] = "อุปกรณ์หรือเครือข่ายไม่เปิดเผยข้อมูลเซลล์"
        }
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

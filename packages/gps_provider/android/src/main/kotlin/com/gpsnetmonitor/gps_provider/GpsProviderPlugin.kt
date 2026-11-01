package com.gpsnetmonitor.gps_provider

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

class GpsProviderPlugin : FlutterPlugin, EventChannel.StreamHandler, LocationListener {
    companion object {
        private const val CHANNEL = "gps_net_monitor/gps_provider"
        private const val UPDATE_INTERVAL_MS = 2000L
    }

    private var appContext: Context? = null
    private var locationManager: LocationManager? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        eventChannel = EventChannel(binding.binaryMessenger, CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stopGpsUpdates()
        eventSink = events
        startGpsUpdates()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        stopGpsUpdates()
    }

    @SuppressLint("MissingPermission")
    private fun startGpsUpdates() {
        val context = appContext ?: return reportError(
            "context_unavailable", "ไม่พบ Android Context"
        )
        val sink = eventSink ?: return

        val permission = ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_FINE_LOCATION
        )
        if (permission != PackageManager.PERMISSION_GRANTED) {
            sink.error("fine_location_denied", "ต้องอนุญาตตำแหน่งแบบแม่นยำ", null)
            return
        }

        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (manager == null) {
            sink.error("location_manager_unavailable", "ไม่พบ LocationManager", null)
            return
        }

        if (!manager.allProviders.contains(LocationManager.GPS_PROVIDER)) {
            sink.error("gps_provider_missing", "อุปกรณ์ไม่เปิดเผย GPS_PROVIDER", null)
            return
        }

        if (!manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            sink.error("gps_provider_disabled", "กรุณาเปิดบริการตำแหน่ง/GPS", null)
            return
        }

        try {
            locationManager = manager
            manager.requestLocationUpdates(
                LocationManager.GPS_PROVIDER,
                UPDATE_INTERVAL_MS,
                0f,
                this,
                Looper.getMainLooper()
            )
        } catch (error: SecurityException) {
            stopGpsUpdates()
            reportError("gps_permission_error", error.message ?: "Android ปฏิเสธสิทธิ์ GPS")
        } catch (error: IllegalArgumentException) {
            stopGpsUpdates()
            reportError("gps_provider_error", error.message ?: "GPS_PROVIDER ใช้งานไม่ได้")
        } catch (error: RuntimeException) {
            stopGpsUpdates()
            reportError("gps_start_error", error.message ?: "เริ่ม GPS_PROVIDER ไม่สำเร็จ")
        }
    }

    private fun reportError(code: String, message: String) {
        eventSink?.error(code, message, null)
    }

    private fun stopGpsUpdates() {
        try {
            locationManager?.removeUpdates(this)
        } catch (_: SecurityException) {
        } catch (_: RuntimeException) {
        }
        locationManager = null
    }

    override fun onLocationChanged(location: Location) {
        // ป้องกันไม่ให้ตำแหน่งจาก provider อื่นถูกส่งเข้าแอป
        if (location.provider != LocationManager.GPS_PROVIDER) return

        val hasAltitudeAccuracy =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            location.hasVerticalAccuracy()
        val hasHeadingAccuracy =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            location.hasBearingAccuracy()
        val hasSpeedAccuracy =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            location.hasSpeedAccuracy()

        val mocked = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            location.isMock
        } else {
            @Suppress("DEPRECATION")
            location.isFromMockProvider
        }

        eventSink?.success(
            mapOf(
                "provider" to LocationManager.GPS_PROVIDER,
                "latitude" to location.latitude,
                "longitude" to location.longitude,
                "accuracy" to location.accuracy.toDouble(),
                "timestamp" to location.time,
                "altitude" to if (location.hasAltitude()) location.altitude else 0.0,
                "altitudeAccuracy" to if (hasAltitudeAccuracy) {
                    location.verticalAccuracyMeters.toDouble()
                } else null,
                "heading" to if (location.hasBearing()) location.bearing.toDouble() else 0.0,
                "headingAccuracy" to if (hasHeadingAccuracy) {
                    location.bearingAccuracyDegrees.toDouble()
                } else null,
                "speed" to if (location.hasSpeed()) location.speed.toDouble() else 0.0,
                "speedAccuracy" to if (hasSpeedAccuracy) {
                    location.speedAccuracyMetersPerSecond.toDouble()
                } else null,
                "isMocked" to mocked
            )
        )
    }

    override fun onProviderDisabled(provider: String) {
        if (provider == LocationManager.GPS_PROVIDER) {
            reportError("gps_provider_disabled", "GPS_PROVIDER ถูกปิด")
            stopGpsUpdates()
        }
    }

    override fun onProviderEnabled(provider: String) {
        // TaskHandler จะลองเริ่ม stream ใหม่ตามรอบ retry
    }

    @Suppress("DEPRECATION")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {
        // Android รุ่นใหม่ไม่เรียก callback นี้แล้ว
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopGpsUpdates()
        eventSink = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        appContext = null
    }
}

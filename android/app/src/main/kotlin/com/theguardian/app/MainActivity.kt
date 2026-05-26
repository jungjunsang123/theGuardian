package com.theguardian.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.location.Address
import android.location.Geocoder
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.theguardian.app/geocoding"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = "the_guardian_location"
            val channelName = "The Guardian Location Service"
            val descriptionText = "Background location tracking service notification"
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(channelId, channelName, importance).apply {
                description = descriptionText
            }
            val notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "searchAddress" -> {
                    val address = call.argument<String>("address")
                    if (address == null) {
                        result.error("INVALID_ARGUMENT", "Address is null", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val geocoder = Geocoder(this, Locale.KOREA)
                            val addresses: List<Address>? = geocoder.getFromLocationName(address, 5)
                            val response = ArrayList<Map<String, Any?>>()
                            if (addresses != null) {
                                for (addr in addresses) {
                                    val item = HashMap<String, Any?>()
                                    item["latitude"] = addr.latitude
                                    item["longitude"] = addr.longitude
                                    val maxIndex = addr.maxAddressLineIndex
                                    val fullAddress = if (maxIndex >= 0) addr.getAddressLine(0) else ""
                                    item["formattedAddress"] = fullAddress
                                    item["postalCode"] = addr.postalCode
                                    response.add(item)
                                }
                            }
                            runOnUiThread {
                                result.success(response)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("GEOCODE_FAILED", e.message, null)
                            }
                        }
                    }.start()
                }
                "reverseGeocode" -> {
                    val lat = call.argument<Double>("latitude")
                    val lng = call.argument<Double>("longitude")
                    if (lat == null || lng == null) {
                        result.error("INVALID_ARGUMENT", "Lat/Lng is null", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val geocoder = Geocoder(this, Locale.KOREA)
                            val addresses: List<Address>? = geocoder.getFromLocation(lat, lng, 1)
                            val item = HashMap<String, Any?>()
                            if (addresses != null && addresses.isNotEmpty()) {
                                val addr = addresses[0]
                                item["latitude"] = addr.latitude
                                item["longitude"] = addr.longitude
                                val maxIndex = addr.maxAddressLineIndex
                                val fullAddress = if (maxIndex >= 0) addr.getAddressLine(0) else ""
                                item["formattedAddress"] = fullAddress
                                item["postalCode"] = addr.postalCode
                            }
                            runOnUiThread {
                                result.success(item)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("REVERSE_GEOCODE_FAILED", e.message, null)
                            }
                        }
                    }.start()
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}

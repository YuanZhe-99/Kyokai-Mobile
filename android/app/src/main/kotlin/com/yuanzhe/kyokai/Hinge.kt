package com.yuanzhe.kyokai

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build

/**
 * A foldable's hinge angle (Sensor.TYPE_HINGE_ANGLE, Android 11 and later):
 * 0 closed, 180 flat. Laptop mode and the diagnostics read it, alongside the
 * display features Flutter reports, which some devices give late or not
 * at all.
 */
class Hinge(context: Context, private val angle: (Float) -> Unit) : SensorEventListener {
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val sensor: Sensor? =
        if (Build.VERSION.SDK_INT >= 30) sensors.getDefaultSensor(Sensor.TYPE_HINGE_ANGLE) else null

    /** Whether the device has a hinge sensor. */
    val present: Boolean get() = sensor != null

    fun start() {
        sensor?.let { sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL) }
    }

    fun stop() = sensors.unregisterListener(this)

    override fun onSensorChanged(event: SensorEvent) = angle(event.values[0])

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}

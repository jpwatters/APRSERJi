// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import kotlin.math.roundToInt
import org.aprsfoundation.core.UltimeterWeather

/** Your own weather station's latest reading, in SI units; null fields were not reported. */
data class LocalWeather(
    val source: String,
    val timeMillis: Long,
    val temperatureC: Double?,
    val humidity: Int?,
    val pressureHpa: Double?,
    val windDegrees: Int?,
    val windMps: Double?,
    val gustMps: Double?,
    val rainHourMm: Double?,
    val rain24hMm: Double?,
    val rainMidnightMm: Double?,
    val luminosityWm2: Double?,
)

/**
 * Turns weather-station input into [LocalWeather]: WeatherFlow Tempest (local UDP broadcasts on port 50222 and the
 * cloud REST API), Cumulus/WeeWX-style wxnow.txt, Peet Bros Ultimeter, and simple JSON with SI keys. Tempest's local
 * broadcast reports rain per minute, so the hourly, 24-hour and since-midnight totals are accumulated here.
 */
class WeatherInput {
    private val minuteRain = ArrayDeque<Pair<Long, Double>>()
    private var midnightRain = 0.0
    private var midnightDay = -1L
    private var latestWind: Triple<Long, Double, Int>? = null
    var latest: LocalWeather? = null
        private set

    /** One Tempest UDP datagram (JSON). Returns true when it updated the reading. */
    fun tempestUdp(json: String, nowMillis: Long, utcOffsetMinutes: Int): Boolean {
        val type = string(json, "type") ?: return false
        if (type == "rapid_wind") {
            val ob = numbers(json, "ob")
            if (ob.size >= 3) latestWind = Triple(nowMillis, ob[1] ?: return false, (ob[2] ?: 0.0).roundToInt())
            return false
        }
        if (type != "obs_st") return false
        val obs = numbers(json, "obs")
        if (obs.size < 13) return false
        val rain = obs[12] ?: 0.0
        addRain(nowMillis, rain, utcOffsetMinutes)
        latest = LocalWeather(
            source = "Tempest " + (string(json, "serial_number") ?: ""),
            timeMillis = nowMillis,
            temperatureC = obs[7], humidity = obs[8]?.roundToInt(), pressureHpa = obs[6]?.let { stationToSeaLevel(it) },
            windDegrees = obs[4]?.roundToInt(), windMps = obs[2], gustMps = obs[3],
            rainHourMm = rainSince(nowMillis - 3_600_000), rain24hMm = rainSince(nowMillis - 86_400_000),
            rainMidnightMm = midnightRain, luminosityWm2 = obs[11],
        )
        return true
    }

    /** Altitude for converting Tempest's station pressure to sea level; 0 leaves it as reported. */
    var elevationMeters = 0.0

    private fun stationToSeaLevel(hpa: Double): Double =
        if (elevationMeters <= 0) hpa else hpa * kotlin.math.exp(elevationMeters / (29.263 * 288.15))

    /** The WeatherFlow REST "observations/station" response (precipitation totals are already computed there). */
    fun tempestRest(json: String, nowMillis: Long): Boolean {
        val section = json.substringAfter("\"obs\"", "").ifEmpty { return false }
        fun n(key: String) = number(section, key)
        val temperature = n("air_temperature") ?: return false
        latest = LocalWeather(
            source = "Tempest (WeatherFlow cloud)", timeMillis = nowMillis, temperatureC = temperature,
            humidity = n("relative_humidity")?.roundToInt(),
            pressureHpa = n("sea_level_pressure") ?: n("barometric_pressure"),
            windDegrees = n("wind_direction")?.roundToInt(), windMps = n("wind_avg"), gustMps = n("wind_gust"),
            rainHourMm = n("precip_accum_last_1hr"), rain24hMm = n("precip_accum_last_24hr") ?: n("precip_accum_local_day"),
            rainMidnightMm = n("precip_accum_local_day"), luminosityWm2 = n("solar_radiation"),
        )
        return true
    }

    /**
     * Generic JSON with SI keys: temperature_c, humidity, pressure_hpa, wind_direction, wind_speed_mps, wind_gust_mps,
     * rain_1h_mm, rain_24h_mm, rain_midnight_mm.
     */
    fun json(json: String, nowMillis: Long): Boolean {
        val temperature = number(json, "temperature_c")
        val wind = number(json, "wind_speed_mps")
        if (temperature == null && wind == null) return false
        latest = LocalWeather("JSON", nowMillis, temperature, number(json, "humidity")?.roundToInt(),
            number(json, "pressure_hpa"), number(json, "wind_direction")?.roundToInt(), wind,
            number(json, "wind_gust_mps"), number(json, "rain_1h_mm"), number(json, "rain_24h_mm"),
            number(json, "rain_midnight_mm"), null)
        return true
    }

    /**
     * Text input: a wxnow.txt file (a date line, then an APRS positionless weather string such as
     * "272/010g006t069r010p030P020h61b10150") or Peet Bros Ultimeter data ($ULTW…, !!…).
     */
    fun text(text: String, nowMillis: Long): Boolean {
        for (raw in text.lines().map { it.trim() }.filter { it.isNotEmpty() }) {
            UltimeterWeather.decode("WX", raw, nowMillis)?.let { w ->
                latest = LocalWeather("Ultimeter", nowMillis, w.temperatureC, w.humidity, w.pressureHpa, w.windDegrees,
                    w.windKph?.div(3.6), w.gustKph?.div(3.6), w.rainHourMm, w.rainDayMm, w.rainMidnightMm, null)
                return true
            }
            val m = Regex("^_?(?:\\d{8})?(\\d{3}|\\.{3})/(\\d{3}|\\.{3})(.*)$").find(raw) ?: continue
            val rest = m.groupValues[3]
            fun field(tag: Char, digits: Int) = Regex("$tag(-?\\d{1,$digits})").find(rest)?.groupValues?.get(1)?.toDoubleOrNull()
            latest = LocalWeather(
                "wxnow.txt", nowMillis, field('t', 3)?.let { (it - 32) * 5 / 9 },
                field('h', 2)?.roundToInt()?.let { if (it == 0) 100 else it }, field('b', 5)?.div(10),
                m.groupValues[1].toIntOrNull(), m.groupValues[2].toDoubleOrNull()?.times(0.44704),
                field('g', 3)?.times(0.44704), field('r', 3)?.times(0.254), field('p', 3)?.times(0.254),
                field('P', 3)?.times(0.254), field('L', 3),
            )
            return true
        }
        return false
    }

    /** Uses the newest rapid-wind sample when it is fresher than the last full observation. */
    fun current(nowMillis: Long): LocalWeather? {
        val w = latest ?: return null
        val wind = latestWind
        return if (wind != null && wind.first > w.timeMillis && nowMillis - wind.first < 60_000)
            w.copy(windMps = wind.second, windDegrees = wind.third) else w
    }

    private fun addRain(nowMillis: Long, mm: Double, utcOffsetMinutes: Int) {
        val day = (nowMillis + utcOffsetMinutes * 60_000L).floorDiv(86_400_000L)
        if (day != midnightDay) { midnightDay = day; midnightRain = 0.0 }
        midnightRain += mm
        minuteRain.addLast(nowMillis to mm)
        while (minuteRain.isNotEmpty() && nowMillis - minuteRain.first().first > 86_400_000) minuteRain.removeFirst()
    }

    private fun rainSince(since: Long) = minuteRain.filter { it.first >= since }.sumOf { it.second }

    companion object {
        private fun string(json: String, key: String) =
            Regex("\"" + key + "\"\\s*:\\s*\"([^\"]*)\"").find(json)?.groupValues?.get(1)

        private fun number(json: String, key: String) =
            Regex("\"" + key + "\"\\s*:\\s*(-?[0-9.eE+-]+)").find(json)?.groupValues?.get(1)?.toDoubleOrNull()

        /** The first array of numbers (or nulls) under [key], unwrapping one level of nesting. */
        private fun numbers(json: String, key: String): List<Double?> {
            val start = json.indexOf("\"$key\"").takeIf { it >= 0 } ?: return emptyList()
            val open = json.indexOf('[', start).takeIf { it >= 0 } ?: return emptyList()
            var i = open
            while (i < json.length && (json[i] == '[' || json[i].isWhitespace())) i++
            val close = json.indexOf(']', i).takeIf { it >= 0 } ?: return emptyList()
            return json.substring(i, close).split(',').map { it.trim().toDoubleOrNull() }
        }

        /**
         * The APRS weather fields after the "_" symbol: "ddd/sssgGGGtTTTrRRRpPPPPPPPhHHbBBBBB" with each unknown
         * field left out (wind as "..." when unknown), in the APRS units (degrees F, mph, hundredths of an inch, tenths of hPa).
         */
        fun aprsFields(w: LocalWeather): String {
            fun pad(v: Int, n: Int) = if (v < 0) "-" + (-v).toString().padStart(n - 1, '0') else v.toString().padStart(n, '0')
            val sb = StringBuilder()
            sb.append(w.windDegrees?.let { pad((if (it == 0) 360 else it).coerceIn(1, 360), 3) } ?: "...")
            sb.append('/')
            sb.append(w.windMps?.let { pad((it * 2.23694).roundToInt().coerceIn(0, 999), 3) } ?: "...")
            sb.append('g').append(w.gustMps?.let { pad((it * 2.23694).roundToInt().coerceIn(0, 999), 3) } ?: "...")
            sb.append('t').append(w.temperatureC?.let { pad((it * 9 / 5 + 32).roundToInt().coerceIn(-99, 999), 3) } ?: "...")
            w.rainHourMm?.let { sb.append('r').append(pad((it / 0.254).roundToInt().coerceIn(0, 999), 3)) }
            w.rain24hMm?.let { sb.append('p').append(pad((it / 0.254).roundToInt().coerceIn(0, 999), 3)) }
            w.rainMidnightMm?.let { sb.append('P').append(pad((it / 0.254).roundToInt().coerceIn(0, 999), 3)) }
            w.humidity?.let { sb.append('h').append(pad((if (it >= 100) 0 else it).coerceIn(0, 99), 2)) }
            w.pressureHpa?.let { sb.append('b').append(pad((it * 10).roundToInt().coerceIn(0, 99999), 5)) }
            w.luminosityWm2?.let { if (it < 1000) sb.append('L').append(pad(it.roundToInt().coerceAtLeast(0), 3)) else sb.append('l').append(pad((it - 1000).roundToInt().coerceIn(0, 999), 3)) }
            return sb.toString()
        }
    }
}

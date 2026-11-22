// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import org.aprsfoundation.core.AprsMessages
import org.aprsfoundation.core.AprsObservations
import org.aprsfoundation.core.AprsProtocol
import org.aprsfoundation.core.AprsStation
import org.aprsfoundation.core.AprsWeather
import org.aprsfoundation.core.RadioPacket

/** Everything the Apple UI shows about one station, object or item. Weather fields are SI and null when absent. */
data class StationDetail(
    val callsign: String,
    val latitude: Double,
    val longitude: Double,
    val symbolTable: String,
    val symbol: String,
    val comment: String,
    val heardAtMillis: Long,
    val courseDegrees: Double?,
    val speedKnots: Double?,
    val altitudeMeters: Double?,
    /** "station", "weather", "object" or "item". */
    val kind: String,
    /** Sender of an object or item; null for ordinary stations. */
    val owner: String?,
    val path: String,
    val packetCount: Int,
    val hasWeather: Boolean,
    val temperatureC: Double?,
    val windDegrees: Int?,
    val windKph: Double?,
    val gustKph: Double?,
    val humidity: Int?,
    val pressureHpa: Double?,
    val rainHourMm: Double?,
    val rainDayMm: Double?,
    val rainMidnightMm: Double?,
    val weatherAtMillis: Long,
)

/** A new chat message addressed to the signed-in account, for notifications only. */
data class IncomingAlert(val sender: String, val text: String, val receivedAtMillis: Long)

/**
 * Keeps the per-station facts the core's position store drops: object ownership, last path,
 * packet counts and the latest weather report. Not thread-safe; callers confine it to one thread.
 */
class PacketInsights(private val ttlMillis: Long = 1_800_000, private val maxEntries: Int = 4_000) {
    private class Extra(val objectKind: String?, val owner: String?, val path: String, val packets: Int, val heardAtMillis: Long)

    private val extras = LinkedHashMap<String, Extra>()
    private val weather = LinkedHashMap<String, AprsWeather>()
    private val alertKeys = LinkedHashMap<String, Long>()

    /** Records one APRS-IS line. Returns an alert when it is a new chat message for [account]. */
    fun receive(line: String, account: String?, nowMillis: Long): IncomingAlert? {
        expire(nowMillis)
        val outer = RadioPacket.parse(line, receiveOnly = true) ?: return null
        val packet = outer.content(receiveOnly = true) ?: return null
        val message = AprsMessages.parse(line)
        val body = if (packet.payload.startsWith(':')) {
            message?.text?.takeIf { it.startsWith(')') } ?: packet.payload
        } else packet.payload

        val station = AprsProtocol.parse(line, nowMillis)
        val report = AprsObservations.weather(line, nowMillis)
        val key = station?.callsign ?: report?.call
        if (key != null) {
            val previous = extras.remove(key)
            val objectKind = when {
                body.startsWith(';') -> "object"
                body.startsWith(')') -> "item"
                station != null -> null
                else -> previous?.objectKind
            }
            val owner = if (objectKind != null) packet.source else null
            extras[key] = Extra(objectKind, owner, outer.path.joinToString(","), (previous?.packets ?: 0) + 1, nowMillis)
            if (report != null) {
                weather.remove(key)
                weather[key] = report
            }
            trim()
        }
        return alert(message, account, nowMillis)
    }

    private fun alert(message: org.aprsfoundation.core.AprsMessage?, account: String?, nowMillis: Long): IncomingAlert? {
        if (message == null || account.isNullOrEmpty()) return null
        if (!message.recipient.equals(account, ignoreCase = true) || message.sender.equals(account, ignoreCase = true)) return null
        if (message.acknowledgement != null || message.text.isBlank() || message.text.startsWith(')')) return null
        // Senders retry until acknowledged; only the first copy should alert.
        val dedup = "${message.sender.uppercase()}|${message.id ?: message.text}"
        if (alertKeys.containsKey(dedup)) return null
        alertKeys[dedup] = nowMillis
        while (alertKeys.size > 500) alertKeys.remove(alertKeys.keys.first())
        return IncomingAlert(message.sender.uppercase(), message.text, nowMillis)
    }

    /** Merges the core's station snapshot with the extra facts kept here. */
    fun details(stations: List<AprsStation>): List<StationDetail> = stations.map { s ->
        val extra = extras[s.callsign]
        val wx = weather[s.callsign]
        val kind = extra?.objectKind ?: if (wx != null || s.symbol == '_') "weather" else "station"
        StationDetail(
            callsign = s.callsign, latitude = s.latitude, longitude = s.longitude,
            symbolTable = s.symbolTable.toString(), symbol = s.symbol.toString(), comment = s.comment,
            heardAtMillis = maxOf(s.heardAtMillis, extra?.heardAtMillis ?: 0L),
            courseDegrees = s.courseDegrees, speedKnots = s.speedKnots, altitudeMeters = s.altitudeMeters,
            kind = kind, owner = extra?.owner, path = extra?.path.orEmpty(), packetCount = extra?.packets ?: 1,
            hasWeather = wx != null,
            temperatureC = wx?.temperatureC, windDegrees = wx?.windDegrees, windKph = wx?.windKph, gustKph = wx?.gustKph,
            humidity = wx?.humidity, pressureHpa = wx?.pressureHpa, rainHourMm = wx?.rainHourMm,
            rainDayMm = wx?.rainDayMm, rainMidnightMm = wx?.rainMidnightMm, weatherAtMillis = wx?.time ?: 0L,
        )
    }

    private fun expire(nowMillis: Long) {
        extras.entries.removeAll { nowMillis - it.value.heardAtMillis >= ttlMillis }
        weather.entries.removeAll { nowMillis - it.value.time >= ttlMillis }
        alertKeys.entries.removeAll { nowMillis - it.value >= ttlMillis }
    }

    private fun trim() {
        while (extras.size > maxEntries) extras.remove(extras.keys.first())
        while (weather.size > maxEntries) weather.remove(weather.keys.first())
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import org.aprsfoundation.core.AprsBulletin
import org.aprsfoundation.core.AprsMessages
import org.aprsfoundation.core.AprsObservations
import org.aprsfoundation.core.AprsProtocol
import org.aprsfoundation.core.AprsSpatial
import org.aprsfoundation.core.AprsStation
import org.aprsfoundation.core.AprsWeather
import org.aprsfoundation.core.RadioPacket
import org.aprsfoundation.core.TelemetryDefinition
import org.aprsfoundation.core.TelemetrySample

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
    /** Radio coverage radius from a PHG or RNG comment, in meters. */
    val coverageMeters: Double?,
    /** Dead-reckoned position for a moving station, projected from its last course and speed. */
    val predictedLatitude: Double?,
    val predictedLongitude: Double?,
    val hasTelemetry: Boolean,
    /** True when the last packet came from the radio (TNC) rather than APRS-IS. */
    val heardOnRadio: Boolean,
)

/** A new chat message addressed to the signed-in account, for notifications only. */
data class IncomingAlert(val sender: String, val text: String, val receivedAtMillis: Long)

/** One position in a station's path of travel. */
data class TrackPoint(val latitude: Double, val longitude: Double, val timeMillis: Long)

/** One analog telemetry channel with its PARM name, UNIT and EQNS-scaled value. */
data class TelemetryChannel(val name: String, val unit: String, val raw: Double?, val value: Double?)
/** One telemetry bit; active follows the station's BITS sense pattern. */
data class TelemetryBit(val name: String, val set: Boolean, val active: Boolean)
data class TelemetryReport(val callsign: String, val sequence: String, val timeMillis: Long, val title: String,
                           val channels: List<TelemetryChannel>, val bits: List<TelemetryBit>)

/**
 * Keeps the per-station facts the core's position store drops: object ownership, last path, packet counts,
 * weather and telemetry reports, bulletins and paths of travel. Not thread-safe; callers confine it to one thread.
 */
class PacketInsights(private val ttlMillis: Long = 1_800_000, private val maxEntries: Int = 4_000) {
    private class Extra(val objectKind: String?, val owner: String?, val path: String, val packets: Int,
                        val heardAtMillis: Long, val radio: Boolean)

    private val extras = LinkedHashMap<String, Extra>()
    private val weather = LinkedHashMap<String, AprsWeather>()
    private val alertKeys = LinkedHashMap<String, Long>()
    private val tracks = LinkedHashMap<String, MutableList<TrackPoint>>()
    private val samples = LinkedHashMap<String, TelemetrySample>()
    private val definitions = LinkedHashMap<String, MutableMap<String, TelemetryDefinition>>()
    private val bulletinMap = LinkedHashMap<String, AprsBulletin>()

    /**
     * Records one packet line. [account] is the signed-in callsign for APRS-IS lines (null for radio lines).
     * Returns an alert when the line is a new chat message for that account.
     */
    fun receive(line: String, account: String?, nowMillis: Long, radio: Boolean = false): IncomingAlert? {
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
            extras[key] = Extra(objectKind, owner, outer.path.joinToString(","), (previous?.packets ?: 0) + 1,
                nowMillis, radio)
            if (report != null) {
                weather.remove(key)
                weather[key] = report
            }
            if (station != null) addTrackPoint(key, station, nowMillis)
        }
        AprsObservations.telemetry(line, nowMillis)?.let { sample ->
            samples.remove(sample.call)
            samples[sample.call] = sample
        }
        AprsObservations.definition(line)?.let { definition ->
            definitions.getOrPut(definition.call) { mutableMapOf() }[definition.kind] = definition
        }
        AprsObservations.bulletin(line, nowMillis)?.let { bulletin ->
            val id = "${bulletin.sender}|${bulletin.destination}"
            bulletinMap.remove(id)
            bulletinMap[id] = bulletin
        }
        trim()
        return alert(message, account, nowMillis)
    }

    private fun addTrackPoint(key: String, station: AprsStation, nowMillis: Long) {
        val points = tracks.remove(key) ?: mutableListOf()
        val last = points.lastOrNull()
        val point = TrackPoint(station.latitude, station.longitude, nowMillis)
        // Only real movement extends a track; repeated fixed-station beacons do not.
        if (last == null || distanceMeters(last, point) >= 25.0) points.add(point)
        while (points.size > 300) points.removeAt(0)
        tracks[key] = points
    }

    private fun distanceMeters(a: TrackPoint, b: TrackPoint): Double {
        val r = kotlin.math.PI / 180
        val x = (b.longitude - a.longitude) * r * kotlin.math.cos((a.latitude + b.latitude) / 2 * r)
        val y = (b.latitude - a.latitude) * r
        return kotlin.math.sqrt(x * x + y * y) * 6_371_000
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
    fun details(stations: List<AprsStation>, nowMillis: Long = 0L): List<StationDetail> = stations.map { s ->
        val extra = extras[s.callsign]
        val wx = weather[s.callsign]
        val kind = extra?.objectKind ?: if (wx != null || s.symbol == '_') "weather" else "station"
        val spatial = AprsSpatial.details(s)
        val predicted = if (nowMillis > 0) AprsSpatial.predicted(s, nowMillis, 600) else null
        StationDetail(
            callsign = s.callsign, latitude = s.latitude, longitude = s.longitude,
            symbolTable = s.symbolTable.toString(), symbol = s.symbol.toString(), comment = s.comment,
            heardAtMillis = maxOf(s.heardAtMillis, extra?.heardAtMillis ?: 0L),
            courseDegrees = spatial.course, speedKnots = spatial.speedKnots, altitudeMeters = spatial.altitudeMeters,
            kind = kind, owner = extra?.owner, path = extra?.path.orEmpty(), packetCount = extra?.packets ?: 1,
            hasWeather = wx != null,
            temperatureC = wx?.temperatureC, windDegrees = wx?.windDegrees, windKph = wx?.windKph, gustKph = wx?.gustKph,
            humidity = wx?.humidity, pressureHpa = wx?.pressureHpa, rainHourMm = wx?.rainHourMm,
            rainDayMm = wx?.rainDayMm, rainMidnightMm = wx?.rainMidnightMm, weatherAtMillis = wx?.time ?: 0L,
            coverageMeters = spatial.coverage?.radiusMeters,
            predictedLatitude = predicted?.latitude, predictedLongitude = predicted?.longitude,
            hasTelemetry = samples.containsKey(s.callsign),
            heardOnRadio = extra?.radio ?: false,
        )
    }

    /** Paths of travel with at least two points, keyed by station. */
    fun tracks(): Map<String, List<TrackPoint>> = tracks.filterValues { it.size >= 2 }.mapValues { it.value.toList() }

    /** Current bulletins and announcements (BLN, NWS), newest first. */
    fun bulletins(): List<AprsBulletin> = bulletinMap.values.sortedByDescending { it.time }

    fun telemetry(): Map<String, TelemetryReport> = samples.mapValues { (call, sample) -> report(call, sample) }

    private fun report(call: String, sample: TelemetrySample): TelemetryReport {
        val defs = definitions[call].orEmpty()
        val names = defs["PARM"]?.values.orEmpty()
        val units = defs["UNIT"]?.values.orEmpty()
        val bitsDefinition = defs["BITS"]?.values.orEmpty()
        val sense = bitsDefinition.firstOrNull() ?: "11111111"
        val channels = sample.analog.mapIndexed { index, raw ->
            TelemetryChannel(names.getOrNull(index)?.ifBlank { null } ?: "A${index + 1}",
                units.getOrNull(index).orEmpty(), raw, AprsObservations.engineering(raw, index, defs["EQNS"]))
        }
        val bits = sample.bits.mapIndexed { index, c ->
            val set = c == '1'
            TelemetryBit(names.getOrNull(5 + index)?.ifBlank { null } ?: "B${index + 1}", set,
                set == (sense.getOrNull(index) != '0'))
        }
        return TelemetryReport(call, sample.sequence, sample.time,
            bitsDefinition.drop(1).joinToString(",").trim(), channels, bits)
    }

    private fun expire(nowMillis: Long) {
        extras.entries.removeAll { nowMillis - it.value.heardAtMillis >= ttlMillis }
        weather.entries.removeAll { nowMillis - it.value.time >= ttlMillis }
        alertKeys.entries.removeAll { nowMillis - it.value >= ttlMillis }
        tracks.keys.retainAll(extras.keys)
        samples.entries.removeAll { nowMillis - it.value.time >= ttlMillis * 2 }
        bulletinMap.entries.removeAll { nowMillis - it.value.time >= 12 * 3_600_000L }
    }

    private fun trim() {
        while (extras.size > maxEntries) extras.remove(extras.keys.first())
        while (weather.size > maxEntries) weather.remove(weather.keys.first())
        while (tracks.size > maxEntries) tracks.remove(tracks.keys.first())
        while (samples.size > maxEntries) samples.remove(samples.keys.first())
        while (definitions.size > maxEntries) definitions.remove(definitions.keys.first())
        while (bulletinMap.size > 500) bulletinMap.remove(bulletinMap.keys.first())
    }
}

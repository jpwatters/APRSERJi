// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import org.aprsfoundation.core.AprsFix
import org.aprsfoundation.core.AprsMessages
import org.aprsfoundation.core.AprsServices
import org.aprsfoundation.core.AprsSpatial
import org.aprsfoundation.core.BeaconFormat
import org.aprsfoundation.core.BeaconPackets
import org.aprsfoundation.core.BeaconPosition
import org.aprsfoundation.core.BeaconTimestamp

/**
 * An object or item this station publishes. [following] objects sit at your current position. A [shape] of
 * "lat,lon;lat,lon…" adds an AE5PL multiline (a line, or a polygon when [shapeClosed]) drawn in [shapeStyle]
 * 'a'…'l'. Killed objects ([alive] false) are sent three more times as deleted, then stop.
 */
data class OwnEntity(
    val id: String,
    val name: String,
    val item: Boolean,
    val latitude: Double,
    val longitude: Double,
    val symbolTable: String,
    val symbol: String,
    val comment: String,
    val following: Boolean,
    val alive: Boolean,
    val enabled: Boolean,
    val intervalSeconds: Int,
    val toInternet: Boolean,
    val toRadio: Boolean,
    /** QRU group this object answers for ("" for none). */
    val group: String,
    val shape: String,
    val shapeClosed: Boolean,
    val shapeStyle: String,
)

/** When an entity last went out and what happened. */
data class EntityStatus(val id: String, val lastSentMillis: Long, val killsLeft: Int, val error: String?)

/** A bulletin re-sent on a schedule: BLN[slot][group]. */
data class ScheduledBulletin(
    val id: String, val slot: String, val group: String, val text: String, val intervalMinutes: Int,
    val enabled: Boolean, val toInternet: Boolean, val toRadio: Boolean,
)

/** Status beacon (">" report). */
data class StatusBeaconSettings(val enabled: Boolean, val text: String, val intervalMinutes: Int, val grid: Boolean,
                                val toInternet: Boolean, val toRadio: Boolean)

/**
 * Your own telemetry. [sources] lists five analog channel sources: "rf" (packets heard on RF), "is" (heard on
 * APRS-IS), "digi" (digipeated), "gated" (gated to APRS-IS), "torf" (gated to RF), "msgs" (messages received),
 * "stations" (stations tracked), "uptime" (minutes running), "const:N", or "input:KEY" (a value the app supplies,
 * e.g. from a sensor file). Raw values are clamped to 0–255; [equations] (15 numbers a,b,c per channel) scale them.
 */
data class TelemetrySettings(
    val enabled: Boolean, val intervalMinutes: Int, val sources: List<String>, val names: List<String>,
    val units: List<String>, val equations: List<String>, val bitNames: List<String>, val title: String,
    val toInternet: Boolean, val toRadio: Boolean,
)

/** Your weather station's reports: as your own station, or as a weather object; optionally also to CWOP. */
data class WeatherBeaconSettings(
    val enabled: Boolean, val intervalMinutes: Int, val objectName: String, val toInternet: Boolean, val toRadio: Boolean,
    val cwop: Boolean, val cwopCallsign: String, val cwopServer: String, val cwopPasscode: String,
)

internal object EntityPackets {
    /** The info field (after ':') of an object or item report. */
    fun entity(owner: String, e: OwnEntity, position: AprsFix, nowMillis: Long, alive: Boolean): String {
        val table = e.symbolTable.firstOrNull() ?: '/'
        val symbol = e.symbol.firstOrNull() ?: '/'
        val shape = runCatching {
            val points = e.shape.split(';').filter { it.isNotBlank() }.map {
                val (la, lo) = it.split(',').map(String::trim).map(String::toDouble)
                AprsFix(la, lo, nowMillis)
            }
            if (points.size >= 2) AprsSpatial.encodeMultiline(position, points, e.shapeClosed,
                e.shapeStyle.firstOrNull()?.takeIf { it in 'a'..'l' } ?: 'j', "00000") else ""
        }.getOrDefault("")
        val comment = (e.comment.trim() + shape).take(120)
        val format = BeaconFormat(table = table, symbol = symbol, timestamp = BeaconTimestamp.NONE, courseSpeed = false, altitude = false)
        val line = BeaconPackets.entity(owner, e.name.trim(), e.item, alive, BeaconPosition(position), format, comment)
        return line.substringAfter(':').trimEnd('\r', '\n')
    }

    fun validate(e: OwnEntity): Boolean = runCatching {
        entity("N0CALL", e, AprsFix(e.latitude, e.longitude, 0), 0, true)
        require(e.intervalSeconds in 60..86_400)
    }.isSuccess

    fun bulletin(owner: String, b: ScheduledBulletin): String =
        AprsServices.bulletin(owner, b.slot.uppercase(), b.group.uppercase(), b.text.trim()).substringAfter(':').trimEnd('\r', '\n')

    /** T#sss,a1,a2,a3,a4,a5,bbbbbbbb */
    fun telemetry(sequence: Int, values: List<Int>, bits: String): String =
        "T#" + (sequence % 1000).toString().padStart(3, '0') + "," +
            values.take(5).joinToString(",") { it.coerceIn(0, 255).toString() } + "," + bits

    /** PARM, UNIT, EQNS and BITS definitions, addressed to our own callsign (info fields). */
    fun definitions(call: String, s: TelemetrySettings): List<String> {
        fun message(text: String) = runCatching {
            AprsMessages.unnumbered(call, call, text.take(67)).substringAfter(':').trimEnd('\r', '\n')
        }.getOrNull()
        val names = (s.names.take(5) + s.bitNames.take(8)).map { it.trim().replace(",", " ") }
        val parm = "PARM." + names.joinToString(",").trimEnd(',')
        val units = "UNIT." + s.units.take(5).joinToString(",") { it.trim().replace(",", " ") }.trimEnd(',')
        val eqns = if (s.equations.size >= 15) "EQNS." + s.equations.take(15).joinToString(",") { it.trim() } else null
        val bits = "BITS.11111111," + s.title.trim().take(23)
        return listOfNotNull(message(parm), message(units), eqns?.let(::message), message(bits))
    }
}

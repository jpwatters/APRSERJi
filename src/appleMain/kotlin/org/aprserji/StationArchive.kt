// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import org.aprsfoundation.core.ChatSql

/** A stored position with its motion, for history and exports. */
data class HistoryPoint(val latitude: Double, val longitude: Double, val timeMillis: Long, val speedKnots: Double?,
                        val courseDegrees: Double?, val altitudeMeters: Double?, val radio: Boolean)

/** A stored telemetry sample (raw analog values; scale with the station's EQNS). */
data class TelemetryPoint(val timeMillis: Long, val sequence: String, val analog: List<Double?>, val bits: String)

/** A station heard directly on RF (no digipeater), with the farthest distance seen. */
data class DxEntry(val callsign: String, val distanceMeters: Double, val bearing: Double, val timeMillis: Long,
                   val port: String, val latitude: Double, val longitude: Double)

/**
 * SQLite archive of station positions, telemetry and RF DX, kept for [retentionDays]. Writes are batched by the
 * caller; everything here runs on the engine's single insight thread.
 */
internal class StationArchive(private val sql: ChatSql) {
    var retentionDays = 30

    init {
        sql.transaction {
            sql.execute("CREATE TABLE IF NOT EXISTS positions(call TEXT NOT NULL, time INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, speed REAL, course REAL, alt REAL, radio INTEGER NOT NULL)")
            sql.execute("CREATE INDEX IF NOT EXISTS positions_call ON positions(call,time)")
            sql.execute("CREATE TABLE IF NOT EXISTS telemetry(call TEXT NOT NULL, time INTEGER NOT NULL, seq TEXT NOT NULL, a1 REAL, a2 REAL, a3 REAL, a4 REAL, a5 REAL, bits TEXT NOT NULL)")
            sql.execute("CREATE INDEX IF NOT EXISTS telemetry_call ON telemetry(call,time)")
            sql.execute("CREATE TABLE IF NOT EXISTS dx(call TEXT PRIMARY KEY, distance REAL NOT NULL, bearing REAL NOT NULL, time INTEGER NOT NULL, port TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL)")
        }
    }

    fun write(events: List<ArchiveEvent>) {
        if (events.isEmpty()) return
        sql.transaction {
            for (event in events) when (event) {
                is ArchiveEvent.Position -> sql.execute(
                    "INSERT INTO positions(call,time,lat,lon,speed,course,alt,radio) VALUES(?,?,?,?,?,?,?,?)",
                    event.call, event.point.timeMillis, event.point.latitude, event.point.longitude,
                    event.speedKnots, event.course, event.altitude, if (event.radio) 1L else 0L)
                is ArchiveEvent.Telemetry -> {
                    val a = event.sample.analog
                    sql.execute("INSERT INTO telemetry(call,time,seq,a1,a2,a3,a4,a5,bits) VALUES(?,?,?,?,?,?,?,?,?)",
                        event.sample.call, event.sample.time, event.sample.sequence,
                        a.getOrNull(0), a.getOrNull(1), a.getOrNull(2), a.getOrNull(3), a.getOrNull(4), event.sample.bits)
                }
            }
        }
    }

    fun dx(entry: DxEntry) {
        sql.execute("INSERT INTO dx(call,distance,bearing,time,port,lat,lon) VALUES(?,?,?,?,?,?,?) " +
            "ON CONFLICT(call) DO UPDATE SET distance=excluded.distance,bearing=excluded.bearing,time=excluded.time," +
            "port=excluded.port,lat=excluded.lat,lon=excluded.lon WHERE excluded.distance>dx.distance",
            entry.callsign, entry.distanceMeters, entry.bearing, entry.timeMillis, entry.port, entry.latitude, entry.longitude)
    }

    fun expire(nowMillis: Long) {
        val cutoff = nowMillis - retentionDays.coerceIn(1, 3650) * 86_400_000L
        sql.transaction {
            sql.execute("DELETE FROM positions WHERE time<?", cutoff)
            sql.execute("DELETE FROM telemetry WHERE time<?", cutoff)
        }
    }

    private fun optional(row: org.aprsfoundation.core.ChatSqlRow, index: Int): Double? =
        row.text(index).takeIf { it.isNotEmpty() }?.toDoubleOrNull()

    fun history(call: String, sinceMillis: Long, limit: Int): List<HistoryPoint> =
        sql.query("SELECT lat,lon,time,speed,course,alt,radio FROM positions WHERE call=? AND time>=? ORDER BY time DESC LIMIT ?",
            listOf(call, sinceMillis, limit.toLong())) {
            HistoryPoint(it.text(0).toDouble(), it.text(1).toDouble(), it.number(2), optional(it, 3), optional(it, 4),
                optional(it, 5), it.number(6) == 1L)
        }.asReversed()

    fun telemetry(call: String, sinceMillis: Long, limit: Int): List<TelemetryPoint> =
        sql.query("SELECT time,seq,a1,a2,a3,a4,a5,bits FROM telemetry WHERE call=? AND time>=? ORDER BY time DESC LIMIT ?",
            listOf(call, sinceMillis, limit.toLong())) {
            TelemetryPoint(it.number(0), it.text(1), (2..6).map { i -> optional(it, i) }, it.text(7))
        }.asReversed()

    fun dxList(limit: Int): List<DxEntry> =
        sql.query("SELECT call,distance,bearing,time,port,lat,lon FROM dx ORDER BY distance DESC LIMIT ?", listOf(limit.toLong())) {
            DxEntry(it.text(0), it.text(1).toDouble(), it.text(2).toDouble(), it.number(3), it.text(4),
                it.text(5).toDouble(), it.text(6).toDouble())
        }

    fun callsigns(): List<String> =
        sql.query("SELECT DISTINCT call FROM positions ORDER BY call", emptyList()) { it.text(0) }

    fun clearDx() { sql.execute("DELETE FROM dx") }
}

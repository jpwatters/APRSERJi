// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.getAndUpdate
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.datetime.Clock
import org.aprsfoundation.core.AprsConnectionState
import org.aprsfoundation.core.AprsFix
import org.aprsfoundation.core.AprsIsClient
import org.aprsfoundation.core.AprsIsConfig
import org.aprsfoundation.core.AprsProtocol
import org.aprsfoundation.core.ChatRow
import org.aprsfoundation.core.ChatSession
import org.aprsfoundation.core.StationMarker

/** Main-thread entry points for the Apple app. ChatSession owns transport and retries. */
@OptIn(ExperimentalCoroutinesApi::class)
class AppleAprs @Throws(Exception::class) constructor(path: String, private val applicationVersion: String) {
    private val store = AppleChatStore(path)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    /** PacketInsights is not thread-safe; every access runs on this one-at-a-time dispatcher. */
    private val insightThread = Dispatchers.Default.limitedParallelism(1)
    private var client: AprsIsClient? = null
    private var session: ChatSession? = null
    private var insightJob: Job? = null
    private val transportError = MutableStateFlow<String?>(null)
    private val activeClient = MutableStateFlow<AprsIsClient?>(null)
    private val activeAccount = MutableStateFlow<String?>(null)
    private val details = MutableStateFlow<List<StationDetail>>(emptyList())
    private val alerts = MutableStateFlow<List<IncomingAlert>>(emptyList())

    private class BeaconSettings(val enabled: Boolean, val intervalMillis: Long, val symbolTable: Char,
                                 val symbol: Char, val comment: String)
    private val beaconSettings = MutableStateFlow<BeaconSettings?>(null)
    private val beaconFix = MutableStateFlow<AprsFix?>(null)
    private val beaconRequested = MutableStateFlow(false)
    private val beaconStatus = MutableStateFlow("OFF")
    private val beaconLast = MutableStateFlow(0L)
    private val beaconNext = MutableStateFlow(0L)

    init { scope.launch { beaconLoop() } }

    val connectionState: String get() = client?.state?.value?.name ?: "STOPPED"
    val stations: List<StationMarker>
        get() = client?.stations?.value.orEmpty().map { StationMarker(it.callsign, it.latitude, it.longitude) }
    /** Stations, weather stations, objects and items heard in range, refreshed once a second. */
    val stationDetails: List<StationDetail> get() = details.value
    val revision: Long get() = store.revision.value
    val chatError: String? get() = transportError.value
    /** The server's latest login response (passcodes are already redacted by the core), or null. */
    val loginReply: String?
        get() = client?.serverMessages?.value?.lastOrNull { it.contains("logresp", ignoreCase = true) }

    /** OFF, NOT_CONNECTED, NOT_VERIFIED, NO_POSITION, LOW_ACCURACY, SCHEDULED, TOO_SOON, SENT or FAILED. */
    val beaconState: String get() = beaconStatus.value
    /** Epoch milliseconds of the last beacon this session sent, or 0. */
    val lastBeaconMillis: Long get() = beaconLast.value
    /** Epoch milliseconds when the next automatic beacon is due, or 0 when none is scheduled. */
    val nextBeaconMillis: Long get() = beaconNext.value

    fun start(callsign: String, passcode: String, host: String, port: Int, latitude: Double, longitude: Double): Boolean {
        val config = try {
            AprsIsConfig(callsign, passcode, host, port, latitude, longitude,
                application = "APRSERJi", applicationVersion = applicationVersion)
        } catch (_: IllegalArgumentException) {
            return false
        }
        return begin(config, callsign)
    }

    /**
     * Connects with one range circle per area. [areas] is "lat,lon;lat,lon;…" (up to four points) and
     * [radiusKm] applies to each, e.g. 805 km for 500 miles. The core's single range filter stops at 500 km,
     * so this sends the equivalent javAPRSSrvr r/ terms as a custom filter.
     */
    fun startAreas(callsign: String, passcode: String, host: String, port: Int, areas: String, radiusKm: Int): Boolean {
        val points = parseAreas(areas) ?: return false
        if (points.isEmpty() || points.size > 4 || radiusKm !in 1..2000) return false
        val filter = points.joinToString(" ") { (lat, lon) -> "r/${coordinate(lat)}/${coordinate(lon)}/$radiusKm" }
        val config = try {
            AprsIsConfig(callsign, passcode, host, port, points[0].first, points[0].second,
                filterMode = "custom", customFilter = filter,
                application = "APRSERJi", applicationVersion = applicationVersion)
        } catch (_: IllegalArgumentException) {
            return false
        }
        return begin(config, callsign)
    }

    /** The server filter in use, for display. */
    val activeFilter: String get() = filterText.value

    private val filterText = MutableStateFlow("")

    private fun parseAreas(text: String): List<Pair<Double, Double>>? = runCatching {
        text.split(';').filter { it.isNotBlank() }.map { area ->
            val (lat, lon) = area.split(',').map { it.trim().toDouble() }
            AprsFix(lat, lon, 0) // validates the range
            lat to lon
        }
    }.getOrNull()

    /** Fixed-point text; Double.toString could produce exponent notation the server rejects. */
    private fun coordinate(value: Double): String {
        val scaled = kotlin.math.round(value * 10_000).toLong()
        val magnitude = kotlin.math.abs(scaled)
        return (if (scaled < 0) "-" else "") + "${magnitude / 10_000}." + (magnitude % 10_000).toString().padStart(4, '0')
    }

    private fun begin(config: AprsIsConfig, callsign: String): Boolean {
        stop()
        filterText.value = org.aprsfoundation.core.AprsFilters.compose(callsign, config.latitude, config.longitude,
            config.radiusKm, config.filterMode, config.customFilter)
        val next = AprsIsClient()
        client = next
        session = ChatSession(callsign, next, store, scope) { transportError.value = it }
        val insights = PacketInsights()
        insightJob = scope.launch(insightThread) {
            launch {
                next.packets.collect { line ->
                    insights.receive(line, callsign, Clock.System.now().toEpochMilliseconds())
                        ?.let { alert -> alerts.update { (it + alert).takeLast(50) } }
                }
            }
            while (isActive) {
                details.value = insights.details(next.stations.value)
                delay(1000)
            }
        }
        beaconLast.value = 0L
        activeAccount.value = callsign
        activeClient.value = next
        next.start(config)
        return true
    }

    fun stop() {
        activeClient.value = null
        activeAccount.value = null
        insightJob?.cancel()
        insightJob = null
        details.value = emptyList()
        session?.close()
        session = null
        client?.stop()
        client = null
        transportError.value = null
        filterText.value = ""
    }

    /** Returns and clears chat messages that arrived since the last call. */
    fun takeIncomingAlerts(): List<IncomingAlert> = alerts.getAndUpdate { emptyList() }

    /**
     * Applies beacon settings. Interval is in seconds (60 or more). The symbol table is "/", "\" or an
     * overlay character; the comment is up to 43 printable characters. Returns false if anything is invalid.
     */
    fun configureBeacon(enabled: Boolean, intervalSeconds: Int, symbolTable: String, symbol: String, comment: String): Boolean {
        val settings = runCatching {
            require(intervalSeconds in 60..86_400)
            require(symbolTable.length == 1 && symbol.length == 1)
            val text = comment.trim()
            require(text.length <= 43 && text.all { it.code in 32..126 && it !in "|~{" })
            // Let the core validate the symbol and comment exactly as it will format them.
            AprsProtocol.beacon("N0CALL", AprsFix(0.0, 0.0, 0), text, symbolTable[0], symbol[0])
            BeaconSettings(enabled, intervalSeconds * 1000L, symbolTable[0], symbol[0], text)
        }.getOrNull() ?: return false
        beaconSettings.value = settings
        return true
    }

    /** Supplies the position to beacon. Fixes older than ten minutes or worse than 100 m are not sent. */
    fun updateBeaconPosition(latitude: Double, longitude: Double, accuracyMeters: Double, timeMillis: Long) {
        beaconFix.value = runCatching { AprsFix(latitude, longitude, timeMillis, accuracyMeters) }.getOrNull()
    }

    fun clearBeaconPosition() { beaconFix.value = null }

    /** Sends one beacon as soon as the connection and position allow, at most once every 30 seconds. */
    fun beaconNow() { beaconRequested.value = true }

    private suspend fun beaconLoop() {
        while (true) {
            delay(1000)
            val now = Clock.System.now().toEpochMilliseconds()
            val settings = beaconSettings.value
            val requested = beaconRequested.value
            if (settings == null || (!settings.enabled && !requested)) {
                beaconStatus.value = "OFF"
                beaconNext.value = 0L
                continue
            }
            val transport = activeClient.value
            val account = activeAccount.value
            if (transport == null || account == null) {
                beaconStatus.value = "NOT_CONNECTED"; beaconNext.value = 0L; beaconRequested.value = false; continue
            }
            if (transport.state.value != AprsConnectionState.VERIFIED) {
                beaconStatus.value = "NOT_VERIFIED"; beaconNext.value = 0L; continue
            }
            val fix = beaconFix.value
            if (fix == null || now - fix.timeMillis !in -60_000L..600_000L) {
                beaconStatus.value = "NO_POSITION"; beaconNext.value = 0L; continue
            }
            if (fix.accuracyMeters > 100) {
                beaconStatus.value = "LOW_ACCURACY"; beaconNext.value = 0L; continue
            }
            val last = beaconLast.value
            if (requested && last != 0L && now - last < 30_000) {
                beaconRequested.value = false
                beaconStatus.value = "TOO_SOON"
                continue
            }
            val scheduled = settings.enabled && (last == 0L || now - last >= settings.intervalMillis)
            if (!requested && !scheduled) {
                beaconNext.value = last + settings.intervalMillis
                if (beaconStatus.value != "SENT" || now - last > 10_000) beaconStatus.value = "SCHEDULED"
                continue
            }
            beaconRequested.value = false
            try {
                transport.sendBroadcast(account, AprsProtocol.beacon(account, fix.copy(timeMillis = now),
                    settings.comment, settings.symbolTable, settings.symbol))
                beaconLast.value = now
                beaconNext.value = if (settings.enabled) now + settings.intervalMillis else 0L
                beaconStatus.value = "SENT"
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                beaconStatus.value = "FAILED"
            }
        }
    }

    @Throws(Exception::class)
    suspend fun enqueue(account: String, peer: String, body: String) {
        store.enqueue(account, peer, body)
    }

    @Throws(Exception::class)
    suspend fun conversations(account: String): List<String> =
        store.rows(account).asReversed().map(ChatRow::peer).distinct()

    @Throws(Exception::class)
    suspend fun messages(account: String, peer: String): List<ChatRow> =
        store.rows(account, peer).takeLast(200)
}

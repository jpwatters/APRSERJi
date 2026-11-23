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
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.datetime.Clock
import org.aprsfoundation.core.AdaptiveBeaconPolicy
import org.aprsfoundation.core.AprsBulletin
import org.aprsfoundation.core.AprsConnectionState
import org.aprsfoundation.core.AprsFilters
import org.aprsfoundation.core.AprsFix
import org.aprsfoundation.core.AprsIsClient
import org.aprsfoundation.core.AprsIsConfig
import org.aprsfoundation.core.AprsServices
import org.aprsfoundation.core.AprsStation
import org.aprsfoundation.core.AprsStationStore
import org.aprsfoundation.core.BeaconFormat
import org.aprsfoundation.core.BeaconPackets
import org.aprsfoundation.core.BeaconPosition
import org.aprsfoundation.core.BeaconTimestamp
import org.aprsfoundation.core.BeaconTiming
import org.aprsfoundation.core.ChatRow
import org.aprsfoundation.core.ChatSession
import org.aprsfoundation.core.RadioPacket
import org.aprsfoundation.core.RadioRouter
import org.aprsfoundation.core.RadioRules
import org.aprsfoundation.core.StationMarker

/** Main-thread entry points for the Apple app. ChatSession owns transport and retries. */
@OptIn(ExperimentalCoroutinesApi::class)
class AppleAprs @Throws(Exception::class) constructor(path: String, private val applicationVersion: String) {
    private val store = AppleChatStore(path)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    /** PacketInsights, the radio station store and the IGate router are confined to this one-at-a-time dispatcher. */
    private val insightThread = Dispatchers.Default.limitedParallelism(1)
    private val insights = PacketInsights()
    private val radioStations = AprsStationStore()
    private var router: RadioRouter? = null
    private var client: AprsIsClient? = null
    private var session: ChatSession? = null
    private var packetJob: Job? = null
    private val transportError = MutableStateFlow<String?>(null)
    private val activeClient = MutableStateFlow<AprsIsClient?>(null)
    private val activeAccount = MutableStateFlow<String?>(null)
    private val details = MutableStateFlow<List<StationDetail>>(emptyList())
    private val trackMap = MutableStateFlow<Map<String, List<TrackPoint>>>(emptyMap())
    private val telemetryMap = MutableStateFlow<Map<String, TelemetryReport>>(emptyMap())
    private val bulletinList = MutableStateFlow<List<AprsBulletin>>(emptyList())
    private val alerts = MutableStateFlow<List<IncomingAlert>>(emptyList())
    private val filterText = MutableStateFlow("")

    private val tnc = TncLink(scope) { packet -> receiveRadio(packet) }
    private val tncCallsign = MutableStateFlow<String?>(null)
    private val igateEnabled = MutableStateFlow(false)
    private val gatedCount = MutableStateFlow(0L)

    init {
        scope.launch(insightThread) {
            while (true) {
                publish()
                delay(1000)
            }
        }
        scope.launch { beaconLoop() }
    }

    // MARK: APRS-IS connection

    val connectionState: String get() = client?.state?.value?.name ?: "STOPPED"
    val stations: List<StationMarker>
        get() = client?.stations?.value.orEmpty().map { StationMarker(it.callsign, it.latitude, it.longitude) }
    /** Stations, weather stations, objects and items heard on APRS-IS and the radio, refreshed once a second. */
    val stationDetails: List<StationDetail> get() = details.value
    /** Paths of travel for stations that have moved, keyed by callsign. */
    val stationTracks: Map<String, List<TrackPoint>> get() = trackMap.value
    /** Latest telemetry per station, with PARM names, UNITs, EQNS scaling and BITS. */
    val telemetryReports: Map<String, TelemetryReport> get() = telemetryMap.value
    /** Bulletins and announcements (BLN…, NWS-…) heard in range, newest first. */
    val bulletins: List<AprsBulletin> get() = bulletinList.value
    val revision: Long get() = store.revision.value
    val chatError: String? get() = transportError.value
    /** The server's latest login response (passcodes are already redacted by the core), or null. */
    val loginReply: String?
        get() = client?.serverMessages?.value?.lastOrNull { it.contains("logresp", ignoreCase = true) }
    /** The server filter in use, for display. */
    val activeFilter: String get() = filterText.value

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
     * Connects with one range circle per area. [areas] is "lat,lon,radiusKm;…" (up to four areas, each
     * radius 1–2000 km). The core's single range filter stops at 500 km, so this sends the equivalent
     * javAPRSSrvr r/ terms as a custom filter. [extraFilter] adds more server filter terms, such as a buddy list
     * ("b/CALL1/CALL2*") for stations to receive wherever they are; pass "" for none.
     */
    fun startAreas(callsign: String, passcode: String, host: String, port: Int, areas: String, extraFilter: String): Boolean {
        val points = parseAreas(areas) ?: return false
        if (points.isEmpty() || points.size > 4) return false
        val extra = extraFilter.trim()
        if (extra.length > 100 || extra.any { it.code !in 33..126 && it != ' ' }) return false
        val filter = (points.map { "r/${coordinate(it.latitude)}/${coordinate(it.longitude)}/${it.radiusKm}" } +
            listOf(extra).filter { it.isNotEmpty() }).joinToString(" ")
        val config = try {
            AprsIsConfig(callsign, passcode, host, port, points[0].latitude, points[0].longitude,
                filterMode = "custom", customFilter = filter,
                application = "APRSERJi", applicationVersion = applicationVersion)
        } catch (_: IllegalArgumentException) {
            return false
        }
        return begin(config, callsign)
    }

    private class Area(val latitude: Double, val longitude: Double, val radiusKm: Int)

    private fun parseAreas(text: String): List<Area>? = runCatching {
        text.split(';').filter { it.isNotBlank() }.map { area ->
            val parts = area.split(',').map { it.trim() }
            require(parts.size == 3)
            val radius = parts[2].toInt()
            require(radius in 1..2000)
            AprsFix(parts[0].toDouble(), parts[1].toDouble(), 0) // validates the coordinates
            Area(parts[0].toDouble(), parts[1].toDouble(), radius)
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
        filterText.value = AprsFilters.compose(callsign, config.latitude, config.longitude,
            config.radiusKm, config.filterMode, config.customFilter)
        val next = AprsIsClient()
        client = next
        session = ChatSession(callsign, next, store, scope) { transportError.value = it }
        packetJob = scope.launch(insightThread) {
            router = RadioRouter(callsign, RadioRules())
            next.packets.collect { line ->
                val now = Clock.System.now().toEpochMilliseconds()
                insights.receive(line, callsign, now)?.let { alert -> alerts.update { (it + alert).takeLast(50) } }
                RadioPacket.parse(line, receiveOnly = true)?.let { router?.observeInternet(it, now) }
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
        packetJob?.cancel()
        packetJob = null
        session?.close()
        session = null
        client?.stop()
        client = null
        transportError.value = null
        filterText.value = ""
    }

    /** Returns and clears chat messages that arrived since the last call. */
    fun takeIncomingAlerts(): List<IncomingAlert> = alerts.getAndUpdate { emptyList() }

    private fun publish() {
        val now = Clock.System.now().toEpochMilliseconds()
        // A station heard both ways shows its newest report.
        val merged = (activeClient.value?.stations?.value.orEmpty() + radioStations.snapshot(now))
            .groupBy(AprsStation::callsign).values.map { copies -> copies.maxBy(AprsStation::heardAtMillis) }
        details.value = insights.details(merged, now)
        trackMap.value = insights.tracks()
        telemetryMap.value = insights.telemetry()
        bulletinList.value = insights.bulletins()
    }

    // MARK: Software modem (KISS / AGWPE over TCP)

    /** STOPPED, CONNECTING, CONNECTED or RECONNECTING. */
    val tncState: String get() = tnc.state.value
    val tncError: String? get() = tnc.lastError.value
    val tncReceived: Long get() = tnc.received.value
    val tncTransmitted: Long get() = tnc.transmitted.value
    val igatedPackets: Long get() = gatedCount.value

    /**
     * Connects to a software modem. [modem] is "KISS" or "AGW". [callsign] is used for beacons sent on RF
     * when APRS-IS is not connected. With [igate] on, packets heard on the radio are gated to APRS-IS while
     * the login is verified, following the core's IGate rules.
     */
    fun startTnc(host: String, port: Int, modem: String, channel: Int, callsign: String, igate: Boolean): Boolean {
        val call = callsign.trim().uppercase()
        if (call.isNotEmpty() && !RadioPacket.address(call)) return false
        tncCallsign.value = call.ifEmpty { null }
        igateEnabled.value = igate
        return tnc.start(host.trim(), port, modem, channel)
    }

    fun stopTnc() {
        tnc.stop()
    }

    fun setIgate(enabled: Boolean) { igateEnabled.value = enabled }

    private suspend fun receiveRadio(packet: RadioPacket) {
        val line = packet.line()
        withContext(insightThread) {
            val now = Clock.System.now().toEpochMilliseconds()
            radioStations.receive(line, now)
            insights.receive(line, null, now, radio = true)
            val gate = router
            val transport = activeClient.value
            val account = activeAccount.value
            if (gate != null) {
                gate.observeRf("tnc", packet, now)
                if (igateEnabled.value && transport != null && account != null &&
                    transport.state.value == AprsConnectionState.VERIFIED) {
                    gate.toInternet(packet, canReply = false)?.let { gated ->
                        scope.launch {
                            runCatching { transport.sendGated(account, gated) }.onSuccess { gatedCount.value += 1 }
                        }
                    }
                }
            }
        }
    }

    // MARK: Beacons (fixed interval or GeniusBeaconing)

    private data class BeaconSettings(
        val enabled: Boolean, val genius: Boolean, val timing: BeaconTiming, val table: Char, val symbol: Char,
        val comment: String, val viaRadio: Boolean, val radioPath: List<String>,
    )

    private class BeaconFixInput(val position: BeaconPosition, val moving: Boolean)

    private val beaconSettings = MutableStateFlow<BeaconSettings?>(null)
    private val beaconFix = MutableStateFlow<BeaconFixInput?>(null)
    private val beaconRequested = MutableStateFlow(false)
    private val beaconStatus = MutableStateFlow("OFF")
    private val beaconLast = MutableStateFlow(0L)
    private val beaconNext = MutableStateFlow(0L)
    private val beaconWhy = MutableStateFlow("")
    private val beaconRoutes = MutableStateFlow("")

    /** OFF, NOT_CONNECTED, NOT_VERIFIED, NO_POSITION, LOW_ACCURACY, SCHEDULED, WATCHING, TOO_SOON, SENT or FAILED. */
    val beaconState: String get() = beaconStatus.value
    /** Epoch milliseconds of the last beacon sent, or 0. */
    val lastBeaconMillis: Long get() = beaconLast.value
    /** When the next beacon is due at the latest (GeniusBeaconing may send sooner), or 0. */
    val nextBeaconMillis: Long get() = beaconNext.value
    /** Why the last beacon was sent: Initial, Interval, Distance, Heading, Forecast error, Moving, Stopped, Manual… */
    val lastBeaconReason: String get() = beaconWhy.value
    /** Where the last beacon went: "APRS-IS", "RF" or "APRS-IS + RF". */
    val lastBeaconRoutes: String get() = beaconRoutes.value

    /**
     * Applies beacon settings. With [genius] off, a beacon goes out every [maximumSeconds]. With it on
     * (GeniusBeaconing), a moving GPS station also beacons when its position strays [forecastErrorMeters] from
     * where its last beacon predicted, after [distanceMeters] of travel, or after turning [headingDegrees];
     * never sooner than [minimumSeconds]. The comment is up to 43 printable characters. [radioPath] is the
     * digipeater path for RF beacons, e.g. "WIDE1-1,WIDE2-1". Returns false if anything is invalid.
     */
    fun configureBeacon(enabled: Boolean, genius: Boolean, minimumSeconds: Int, maximumSeconds: Int,
                        forecastErrorMeters: Double, distanceMeters: Double, headingDegrees: Double,
                        symbolTable: String, symbol: String, comment: String, viaRadio: Boolean, radioPath: String): Boolean {
        val settings = runCatching {
            require(symbolTable.length == 1 && symbol.length == 1)
            val text = comment.trim()
            require(text.length <= 43 && text.all { it.code in 32..126 && it !in "|~{" })
            val path = radioPath.split(',').map { it.trim().uppercase() }.filter { it.isNotEmpty() }
            require(path.size <= 8 && path.all { RadioPacket.address(it) })
            val timing = if (genius) {
                BeaconTiming(minimumSeconds = minimumSeconds.coerceIn(10, 3600),
                    maximumSeconds = maximumSeconds.coerceIn(minimumSeconds.coerceIn(10, 3600), 86_400),
                    headingDegrees = headingDegrees, forecastErrorMeters = forecastErrorMeters,
                    distanceMeters = distanceMeters)
            } else {
                BeaconTiming(minimumSeconds = 60, maximumSeconds = maximumSeconds.coerceIn(60, 86_400), timeOnly = true)
            }
            val format = BeaconFormat(table = symbolTable[0], symbol = symbol[0], timestamp = BeaconTimestamp.NONE)
            // Let the core validate the symbol and comment exactly as it will format them.
            BeaconPackets.position("N0CALL", BeaconPosition(AprsFix(0.0, 0.0, 0)), format, text)
            BeaconSettings(enabled, genius, timing, symbolTable[0], symbol[0], text, viaRadio, path)
        }.getOrNull() ?: return false
        if (settings != beaconSettings.value) beaconSettings.value = settings
        return true
    }

    /**
     * Supplies the position to beacon. Speed (knots), course (degrees) and altitude (meters) are optional:
     * pass a negative speed or course, or NaN altitude, when unknown. [moving] is true for a GPS fix and false
     * for a fixed position. Fixes older than ten minutes or worse than 100 m are not sent.
     */
    fun updateBeaconPosition(latitude: Double, longitude: Double, accuracyMeters: Double, timeMillis: Long,
                             speedKnots: Double, courseDegrees: Double, altitudeMeters: Double, moving: Boolean) {
        beaconFix.value = runCatching {
            BeaconFixInput(BeaconPosition(AprsFix(latitude, longitude, timeMillis, accuracyMeters),
                speedKnots.takeIf { it.isFinite() && it >= 0 },
                courseDegrees.takeIf { it.isFinite() && it in 0.0..360.0 },
                altitudeMeters.takeIf { it.isFinite() }), moving)
        }.getOrNull()
    }

    fun clearBeaconPosition() { beaconFix.value = null }

    /** Sends one beacon as soon as a transport and position allow, at most once every 30 seconds. */
    fun beaconNow() { beaconRequested.value = true }

    private suspend fun beaconLoop() {
        var policy: AdaptiveBeaconPolicy? = null
        var policyTiming: BeaconTiming? = null
        var policyCall: String? = null
        var wasVerified = false
        while (true) {
            delay(1000)
            val now = Clock.System.now().toEpochMilliseconds()
            val settings = beaconSettings.value
            val requested = beaconRequested.value
            if (settings == null || (!settings.enabled && !requested)) {
                beaconStatus.value = "OFF"
                beaconNext.value = 0L
                beaconRequested.value = false
                continue
            }
            val transport = activeClient.value
            val verified = transport?.state?.value == AprsConnectionState.VERIFIED
            val reconnected = verified && !wasVerified
            wasVerified = verified
            val radioReady = settings.viaRadio && tnc.isConnected
            val call = (if (verified) activeAccount.value else null) ?: tncCallsign.value?.takeIf { radioReady }
            if (call == null || (!verified && !radioReady)) {
                beaconStatus.value = if (transport == null && !radioReady) "NOT_CONNECTED" else "NOT_VERIFIED"
                beaconNext.value = 0L
                continue
            }
            val input = beaconFix.value
            if (input == null || now - input.position.fix.timeMillis !in -60_000L..600_000L) {
                beaconStatus.value = "NO_POSITION"; beaconNext.value = 0L; continue
            }
            if (input.position.fix.accuracyMeters > 100) {
                beaconStatus.value = "LOW_ACCURACY"; beaconNext.value = 0L; continue
            }
            if (policy == null || policyTiming != settings.timing || policyCall != call) {
                policy = AdaptiveBeaconPolicy(settings.timing)
                policyTiming = settings.timing
                policyCall = call
            }
            val activePolicy = policy ?: continue
            val last = beaconLast.value
            if (requested && last != 0L && now - last < 30_000) {
                beaconRequested.value = false
                beaconStatus.value = "TOO_SOON"
                continue
            }
            val position = input.position.copy(fix = input.position.fix.copy(timeMillis = now))
            val decision = activePolicy.evaluate(position, now, movingSource = input.moving, forced = requested,
                reconnected = reconnected && last != 0L)
            if (decision == null) {
                beaconNext.value = (activePolicy.lastSent ?: now) + settings.timing.maximumSeconds * 1000L
                if (beaconStatus.value != "SENT" || now - last > 10_000) {
                    beaconStatus.value = if (settings.genius && input.moving) "WATCHING" else "SCHEDULED"
                }
                continue
            }
            beaconRequested.value = false
            val format = BeaconFormat(table = settings.table, symbol = settings.symbol, timestamp = BeaconTimestamp.NONE)
            val packet = try {
                BeaconPackets.position(call, position, format, settings.comment)
            } catch (_: Exception) {
                beaconStatus.value = "FAILED"; continue
            }
            val routes = mutableListOf<String>()
            if (verified && transport != null && call == activeAccount.value) {
                try {
                    transport.sendBroadcast(call, packet)
                    routes += "APRS-IS"
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                }
            }
            if (radioReady) {
                val body = packet.substringAfter(':').trimEnd('\r', '\n')
                val rf = runCatching { RadioPacket(call, "APRS", settings.radioPath, body) }.getOrNull()
                if (rf != null && RadioPacket.address(call) && tnc.send(rf)) routes += "RF"
            }
            if (routes.isEmpty()) {
                beaconStatus.value = "FAILED"
                continue
            }
            activePolicy.sent(position, now)
            beaconLast.value = now
            beaconNext.value = now + settings.timing.maximumSeconds * 1000L
            beaconWhy.value = decision.reason
            beaconRoutes.value = routes.joinToString(" + ")
            beaconStatus.value = "SENT"
        }
    }

    // MARK: Messages, announcements (ANSRVR)

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

    /**
     * Queues an ANSRVR command through the message outbox: [action] "J" joins [group], "U" leaves it,
     * "CQ" sends [text] to every member, "K" leaves all groups. Returns false when the input is invalid.
     */
    @Throws(Exception::class)
    suspend fun announcement(account: String, action: String, group: String, text: String): Boolean {
        val body = runCatching { AprsServices.group(action, group, text) }.getOrNull() ?: return false
        store.enqueue(account, "ANSRVR", body)
        return true
    }
}

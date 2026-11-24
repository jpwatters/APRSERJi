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
import org.aprsfoundation.core.AprsEndpoint
import org.aprsfoundation.core.AprsFilters
import org.aprsfoundation.core.AprsFix
import org.aprsfoundation.core.AprsIsClient
import org.aprsfoundation.core.AprsIsConfig
import org.aprsfoundation.core.AprsMessages
import org.aprsfoundation.core.AprsProtocol
import org.aprsfoundation.core.AprsServices
import org.aprsfoundation.core.AprsSpatial
import org.aprsfoundation.core.AprsStation
import org.aprsfoundation.core.AprsStationStore
import org.aprsfoundation.core.BeaconFormat
import org.aprsfoundation.core.BeaconPackets
import org.aprsfoundation.core.BeaconPosition
import org.aprsfoundation.core.BeaconTimestamp
import org.aprsfoundation.core.BeaconTiming
import org.aprsfoundation.core.ChatOptions
import org.aprsfoundation.core.ChatRow
import org.aprsfoundation.core.ChatSession
import org.aprsfoundation.core.EmailMessages
import org.aprsfoundation.core.GpsDiagnostics
import org.aprsfoundation.core.NmeaPositionDecoder
import org.aprsfoundation.core.PacketFilter
import org.aprsfoundation.core.QruObjects
import org.aprsfoundation.core.QueryObject
import org.aprsfoundation.core.RadioPacket
import org.aprsfoundation.core.RadioRouter
import org.aprsfoundation.core.RadioRules
import org.aprsfoundation.core.StationMarker

/** One line in the packet monitor. [direction] is "RX" or "TX"; [port] is "APRS-IS", a radio port's name or a service. */
data class PacketLogEntry(val sequence: Long, val timeMillis: Long, val port: String, val direction: String, val line: String)

/** One report this station sent: what, why and where. */
data class BeaconJournalEntry(val timeMillis: Long, val kind: String, val reason: String, val routes: String, val packet: String)

/** A position from an external GPS (serial or network NMEA, or gpsd). */
data class ExternalFix(val latitude: Double, val longitude: Double, val altitudeMeters: Double?, val speedKnots: Double?,
                       val courseDegrees: Double?, val accuracyMeters: Double, val timeMillis: Long)

/** GPS satellites in view (from NMEA GSV/GSA), for the sky plot. */
data class GpsSatelliteInfo(val constellation: String, val id: String, val elevation: Double?, val azimuth: Double?,
                            val snr: Double?, val used: Boolean)
data class GpsSkyInfo(val satellites: List<GpsSatelliteInfo>, val fixType: Int, val hdop: Double?, val pdop: Double?,
                      val vdop: Double?, val timeMillis: Long)

/** Counters for the status screens and telemetry. */
data class EngineCounters(val heardRf: Long, val heardInternet: Long, val digipeated: Long, val gatedToInternet: Long,
                          val gatedToRadio: Long, val messagesReceived: Long, val sent: Long, val startedMillis: Long)

/** Main-thread entry points for the Apple app. ChatSession owns the outbox and retries. */
@OptIn(ExperimentalCoroutinesApi::class)
class AppleAprs @Throws(Exception::class) constructor(path: String, private val applicationVersion: String) {
    private val store = AppleChatStore(path)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    /** Insights, the radio station store, the router, the archive and the responder live on this one-at-a-time dispatcher. */
    private val insightThread = Dispatchers.Default.limitedParallelism(1)
    private val insights = PacketInsights()
    private val radioStations = AprsStationStore()
    private val archive: StationArchive? = runCatching {
        StationArchive(AppleChatSql(path.substringBeforeLast('/', ".") + "/stations.sqlite"))
    }.getOrNull()
    private val responder = Responder()
    private var router: RadioRouter? = null
    private var routerCall: String? = null
    private var client: AprsIsClient? = null
    private var session: ChatSession? = null
    private var sessionCall: String? = null
    private var packetJob: Job? = null
    private val transportError = MutableStateFlow<String?>(null)
    private val activeClient = MutableStateFlow<AprsIsClient?>(null)
    /** The callsign this station uses on the air and in chat, with or without APRS-IS. */
    private val account = MutableStateFlow<String?>(null)
    private val isAccount = MutableStateFlow<String?>(null)
    private val details = MutableStateFlow<List<StationDetail>>(emptyList())
    private val trackMap = MutableStateFlow<Map<String, List<TrackPoint>>>(emptyMap())
    private val telemetryMap = MutableStateFlow<Map<String, TelemetryReport>>(emptyMap())
    private val bulletinList = MutableStateFlow<List<AprsBulletin>>(emptyList())
    private val alerts = MutableStateFlow<List<IncomingAlert>>(emptyList())
    private val filterText = MutableStateFlow("")
    private val startedAt = Clock.System.now().toEpochMilliseconds()

    private fun now() = Clock.System.now().toEpochMilliseconds()

    // MARK: Station identity and position

    /** Sets the callsign used on RF and for chat. APRS-IS logins set it too. */
    fun setStation(callsign: String) {
        val call = callsign.trim().uppercase()
        if (call.isNotEmpty() && !AprsProtocol.validCallsign(call) && !RadioPacket.address(call)) return
        account.value = call.ifEmpty { null }
        ensureSession()
    }

    private val ownFix = MutableStateFlow<AprsFix?>(null)
    private val ownAltitude = MutableStateFlow<Double?>(null)

    /** Where this station is, for RF DX distances, QRU answers and query replies. Pass valid=false when unknown. */
    fun setOwnPosition(latitude: Double, longitude: Double, altitudeMeters: Double, valid: Boolean) {
        ownFix.value = if (!valid) null else runCatching { AprsFix(latitude, longitude, now()) }.getOrNull()
        ownAltitude.value = altitudeMeters.takeIf { valid && it.isFinite() }
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
    /** The APRS-IS server currently in use ("host:port"), which may be a backup server. */
    val activeServer: String get() = client?.activeEndpoint?.value?.let { "${it.host}:${it.port}" } ?: ""

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
     * Connects with one range circle per area. [areas] is "lat,lon,radiusKm;…" (up to four areas, each radius
     * 1–2000 km), sent as javAPRSSrvr r/ terms. [extraFilter] adds more server filter terms, such as a buddy list
     * ("b/CALL1/CALL2*"); pass "" for none. [backupServers] is a comma-separated list of "host:port" tried in turn
     * when the main server fails.
     */
    fun startAreas(callsign: String, passcode: String, host: String, port: Int, areas: String, extraFilter: String,
                   backupServers: String): Boolean {
        val points = parseAreas(areas) ?: return false
        if (points.isEmpty() || points.size > 4) return false
        val extra = extraFilter.trim()
        if (extra.length > 200 || extra.any { it.code !in 33..126 && it != ' ' }) return false
        val backups = runCatching {
            backupServers.split(',', ' ', ';').map { it.trim() }.filter { it.isNotEmpty() }.take(16).map { AprsEndpoint.parse(it) }
        }.getOrNull() ?: return false
        val filter = (points.map { "r/${coordinate(it.latitude)}/${coordinate(it.longitude)}/${it.radiusKm}" } +
            listOf(extra).filter { it.isNotEmpty() }).joinToString(" ")
        val config = try {
            AprsIsConfig(callsign, passcode, host, port, points[0].latitude, points[0].longitude,
                filterMode = "custom", customFilter = filter, fallbackServers = backups,
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
        account.value = callsign
        isAccount.value = callsign
        val next = AprsIsClient()
        client = next
        packetJob = scope.launch(insightThread) {
            next.packets.collect { line -> runCatching { receiveInternet(line) } }
        }
        beaconLast.value = 0L
        activeClient.value = next
        ensureSession()
        next.start(config)
        return true
    }

    fun stop() {
        activeClient.value = null
        isAccount.value = null
        packetJob?.cancel()
        packetJob = null
        client?.stop()
        client = null
        transportError.value = null
        filterText.value = ""
    }

    /** Returns and clears chat messages that arrived since the last call. */
    fun takeIncomingAlerts(): List<IncomingAlert> = alerts.getAndUpdate { emptyList() }

    private val transport = RoutedTransport(
        internet = activeClient,
        radioPorts = { links.value.values.toList() },
        heardOnRadio = { call -> radioHeard.value[call.uppercase()]?.let { now() - it < 1_800_000 } ?: false },
        onSent = { port, line -> logPacket(port, "TX", line) },
        onReceived = { counters.update { it.copy(messagesReceived = it.messagesReceived + 1) } },
    )

    /** One chat session per station callsign; it survives APRS-IS reconnects and works over RF alone. */
    private fun ensureSession() {
        val call = account.value
        if (call == sessionCall) return
        session?.close()
        session = null
        sessionCall = call
        if (call != null && AprsProtocol.validCallsign(call)) {
            session = ChatSession(call, transport, store, scope) { transportError.value = it }
        }
    }

    private fun routerFor(call: String?): RadioRouter? {
        if (call == null) return null
        if (routerCall != call) {
            router = runCatching { RadioRouter(call, RadioRules()) }.getOrNull()
            routerCall = call
        }
        return router
    }

    private suspend fun receiveInternet(line: String) {
        val t = now()
        counters.update { it.copy(heardInternet = it.heardInternet + 1) }
        logPacket("APRS-IS", "RX", line)
        val call = account.value
        insights.receive(line, isAccount.value, t)?.let { alert -> alerts.update { (it + alert).takeLast(50) } }
        val packet = RadioPacket.parse(line, receiveOnly = true) ?: return
        val gate = routerFor(call)
        gate?.observeInternet(packet, t)
        server.broadcast(line) { f -> f.matches(packet, ownFix.value, positionsSnapshot(), insights.igateCalls()) }
        syslog.send(line)
        if (call != null) handleQueries(packet, line, call, null, t)
        // IGate: APRS-IS to RF, for messages to stations heard locally and packets passing the gate filter.
        if (gate != null && call != null) {
            for (port in links.value.values) {
                if (!port.config.igateToRadio || !port.isConnected || !port.config.transmit) continue
                val allowed = gateFilter.value?.let { f ->
                    runCatching { f.matches(packet, ownFix.value, positionsSnapshot(), insights.igateCalls()) }.getOrDefault(false)
                } ?: false
                val path = runCatching { PortLink.pathList(port.config.path) }.getOrDefault(emptyList())
                val out = gate.toRadio(port.config.id, packet, t, path, passCalls.value, passObjects.value, allowed) ?: continue
                if (gate.duplicate("torf:${port.config.id}", out, t)) continue
                if (port.send(out)) {
                    gate.transmitted("torf:${port.config.id}", out, t)
                    gate.gatedToRadio(port.config.id, packet, t)
                    counters.update { it.copy(gatedToRadio = it.gatedToRadio + 1) }
                    logPacket(port.config.name, "TX", out.line())
                }
            }
        }
    }

    private fun positionsSnapshot(): Map<String, AprsFix> =
        details.value.associate { it.callsign to AprsFix(it.latitude, it.longitude, it.heardAtMillis) }

    private fun publish() {
        val t = now()
        // A station heard both ways shows its newest report.
        val merged = (activeClient.value?.stations?.value.orEmpty() + radioStations.snapshot(t))
            .groupBy(AprsStation::callsign).values.map { copies -> copies.maxBy(AprsStation::heardAtMillis) }
        details.value = insights.details(merged, t)
        trackMap.value = insights.tracks()
        telemetryMap.value = insights.telemetry()
        bulletinList.value = insights.bulletins()
        packetLogState.value = packetLog.toList()
    }

    private fun flushArchive() {
        val a = archive ?: run { insights.archive.clear(); return }
        if (insights.archive.isEmpty()) return
        val batch = insights.archive.toList()
        insights.archive.clear()
        a.write(batch)
    }

    // MARK: Packet monitor

    private val packetLog = ArrayDeque<PacketLogEntry>()
    private val packetLogState = MutableStateFlow<List<PacketLogEntry>>(emptyList())
    private var packetSequence = 0L

    /** Logs from any thread; the entry lands on the insight thread. */
    private fun logPacket(port: String, direction: String, line: String) {
        val t = now()
        scope.launch(insightThread) {
            packetLog.addLast(PacketLogEntry(++packetSequence, t, port, direction, line.trimEnd('\r', '\n')))
            while (packetLog.size > 3000) packetLog.removeFirst()
            if (direction == "TX") counters.update { it.copy(sent = it.sent + 1) }
        }
    }

    /** The newest packets heard and sent (up to 3000), oldest first, updated once a second. */
    val packetLogEntries: List<PacketLogEntry> get() = packetLogState.value

    private val counters = MutableStateFlow(EngineCounters(0, 0, 0, 0, 0, 0, 0, startedAt))
    val engineCounters: EngineCounters get() = counters.value

    // MARK: Radio ports

    private val links = MutableStateFlow<Map<String, PortLink>>(emptyMap())
    private val radioHeard = MutableStateFlow<Map<String, Long>>(emptyMap())
    private val passCalls = MutableStateFlow<List<String>>(emptyList())
    private val passObjects = MutableStateFlow<List<String>>(emptyList())
    private val gateFilter = MutableStateFlow<PacketFilter?>(null)

    /**
     * Applies the full list of radio ports: new ones start, removed ones stop, changed ones restart.
     * Returns the ids that were rejected as invalid.
     */
    fun configurePorts(ports: List<PortConfig>): List<String> {
        val valid = ports.filter { PortLink.validate(it) }
        val current = links.value
        val next = LinkedHashMap<String, PortLink>()
        for (config in valid) {
            val existing = current[config.id]
            if (existing != null && existing.config == config) { next[config.id] = existing; continue }
            existing?.stop()
            val link = if (config.kind == "TCP") TcpPortLink(config, scope) { l, p -> receiveRadio(l, p) }
                else ExternalPortLink(config) { l, p -> receiveRadio(l, p) }
            link.start()
            next[config.id] = link
        }
        for ((id, link) in current) if (id !in next) link.stop()
        links.value = next
        return ports.map { it.id } - valid.map { it.id }.toSet()
    }

    val portStatuses: List<PortStatus> get() = links.value.values.map { it.status() }

    /** IGate settings: callsigns and object names always gated to RF, and a javAPRSFilter expression for more. */
    fun configureIgate(passCallsigns: String, passObjectNames: String, filter: String): Boolean {
        val parsed = if (filter.isBlank()) null else runCatching { PacketFilter(filter.trim()) }.getOrNull() ?: return false
        passCalls.value = passCallsigns.split(',', ' ').map { it.trim().uppercase() }.filter { it.isNotEmpty() }
        passObjects.value = passObjectNames.split(',').map { it.trim() }.filter { it.isNotEmpty() }
        gateFilter.value = parsed
        return true
    }

    /** Bytes the app read from a serial or Bluetooth port. */
    suspend fun externalReceived(id: String, bytes: ByteArray) {
        (links.value[id] as? ExternalPortLink)?.accept(bytes)
    }

    /** The next bytes to write to a serial or Bluetooth port, or null. */
    fun externalTakeOutgoing(id: String): ByteArray? = (links.value[id] as? ExternalPortLink)?.takeOutgoing()

    /** Bytes to write when a serial or Bluetooth link opens (AGW raw mode, Mobilinkd queries). */
    fun externalOpening(id: String): List<ByteArray> = (links.value[id] as? ExternalPortLink)?.openingBytes().orEmpty()

    fun externalLinkState(id: String, connected: Boolean, error: String?) {
        (links.value[id] as? ExternalPortLink)?.linkState(connected, error)
    }

    private suspend fun receiveRadio(link: PortLink, packet: RadioPacket) {
        val line = packet.line()
        withContext(insightThread) {
            val t = now()
            counters.update { it.copy(heardRf = it.heardRf + 1) }
            logPacket(link.config.name, "RX", line)
            radioStations.receive(line, t)
            radioHeard.update { (it + (packet.source.uppercase() to t)).entries.sortedBy { e -> e.value }.takeLast(2000).associate { e -> e.key to e.value } }
            val call = account.value
            insights.receive(line, call, t, radio = true, port = link.config.name)
                ?.let { alert -> alerts.update { (it + alert).takeLast(50) } }
            server.broadcast(line) { f -> f.matches(packet, ownFix.value, positionsSnapshot(), insights.igateCalls()) }
            syslog.send(line)
            recordDx(packet, link, t)
            // Messages for this station heard on the radio go to the chat session.
            if (call != null) {
                AprsMessages.parse(packet.content()?.line() ?: line)?.takeIf { it.recipient.equals(call, true) && !it.sender.equals(call, true) }
                    ?.let { transport.fromRadio.tryEmit(it) }
                handleQueries(packet, line, call, link, t)
            }
            val gate = routerFor(call) ?: return@withContext
            gate.observeRf(link.config.id, packet, t)
            // Digipeat on this port and any cross ports.
            if (link.config.digipeat) {
                val transforms = runCatching { PortLink.transformList(link.config.transforms) }.getOrDefault(emptyList())
                gate.digipeat(packet, transforms)?.let { out ->
                    if (!gate.duplicate("digi", packet, t)) {
                        gate.transmitted("digi", packet, t)
                        val targets = listOf(link) + link.config.crossPorts.split(',').mapNotNull { links.value[it.trim()] }
                        for (target in targets.distinct()) if (target.send(out)) {
                            target.digipeated.value += 1
                            counters.update { it.copy(digipeated = it.digipeated + 1) }
                            logPacket(target.config.name, "TX", out.line())
                        }
                    }
                }
            }
            // IGate: RF to APRS-IS while the login is verified.
            val transportClient = activeClient.value
            val isCall = isAccount.value
            if (link.config.igateToInternet && transportClient != null && isCall != null &&
                transportClient.state.value == AprsConnectionState.VERIFIED) {
                gate.toInternet(packet, canReply = links.value.values.any { it.config.igateToRadio })?.let { gated ->
                    scope.launch {
                        runCatching { transportClient.sendGated(isCall, gated) }.onSuccess {
                            link.gated.value += 1
                            counters.update { it.copy(gatedToInternet = it.gatedToInternet + 1) }
                        }
                    }
                }
            }
        }
    }

    // MARK: RF DX

    private val dxBest = MutableStateFlow<Map<String, DxEntry>>(emptyMap())

    private fun recordDx(packet: RadioPacket, link: PortLink, t: Long) {
        val me = ownFix.value ?: return
        if (!AprsSpatial.directlyHeard(packet)) return
        val station = AprsProtocol.parse(packet.line(), t) ?: return
        val them = AprsFix(station.latitude, station.longitude, t)
        val meters = AdaptiveBeaconPolicy.distance(me, them)
        if (meters < 100 || meters > 2_000_000) return
        val bearing = bearing(me, them)
        val entry = DxEntry(packet.source, meters, bearing, t, link.config.name, station.latitude, station.longitude)
        val old = dxBest.value[packet.source]
        if (old == null || meters > old.distanceMeters) {
            dxBest.update { it + (packet.source to entry) }
            runCatching { archive?.dx(entry) }
        }
    }

    private fun bearing(a: AprsFix, b: AprsFix): Double {
        val r = kotlin.math.PI / 180
        val y = kotlin.math.sin((b.longitude - a.longitude) * r) * kotlin.math.cos(b.latitude * r)
        val x = kotlin.math.cos(a.latitude * r) * kotlin.math.sin(b.latitude * r) -
            kotlin.math.sin(a.latitude * r) * kotlin.math.cos(b.latitude * r) * kotlin.math.cos((b.longitude - a.longitude) * r)
        return (kotlin.math.atan2(y, x) / r + 360) % 360
    }

    /** Stations heard directly on RF, farthest first (from the archive, which keeps them across restarts). */
    suspend fun dxList(limit: Int): List<DxEntry> = withContext(insightThread) {
        archive?.let { runCatching { it.dxList(limit) }.getOrNull() } ?: dxBest.value.values.sortedByDescending { it.distanceMeters }.take(limit)
    }

    suspend fun clearDx() {
        withContext(insightThread) {
            dxBest.value = emptyMap()
            runCatching { archive?.clearDx() }
        }
    }

    // MARK: Archive

    fun setArchiveRetention(days: Int) { archive?.retentionDays = days.coerceIn(1, 3650) }

    suspend fun history(callsign: String, sinceMillis: Long, limit: Int): List<HistoryPoint> = withContext(insightThread) {
        flushArchive()
        archive?.let { runCatching { it.history(callsign, sinceMillis, limit) }.getOrNull() }.orEmpty()
    }

    suspend fun telemetryHistory(callsign: String, sinceMillis: Long, limit: Int): List<TelemetryPoint> = withContext(insightThread) {
        flushArchive()
        archive?.let { runCatching { it.telemetry(callsign, sinceMillis, limit) }.getOrNull() }.orEmpty()
    }

    suspend fun archivedCallsigns(): List<String> = withContext(insightThread) {
        flushArchive()
        archive?.let { runCatching { it.callsigns() }.getOrNull() }.orEmpty()
    }

    /** A GPX track of the archived positions. */
    fun gpx(callsign: String, points: List<HistoryPoint>): String =
        AprsServices.gpx(callsign, points.map { AprsFix(it.latitude, it.longitude, it.timeMillis) })

    // MARK: Queries, auto-reply, QRU and kiosk

    fun configureResponder(settings: ResponderSettings) {
        scope.launch(insightThread) { responder.settings = settings }
    }

    private suspend fun handleQueries(packet: RadioPacket, line: String, call: String, link: PortLink?, t: Long) {
        val content = packet.content(receiveOnly = true) ?: return
        if (content.source.equals(call, true)) return
        val facts = facts(t)
        if (content.payload.startsWith("?")) {
            for (answer in responder.broadcast(content.payload, t, facts)) perform(answer, content.source, link, call)
            return
        }
        val message = AprsMessages.parse(content.line()) ?: return
        if (message.acknowledgement != null) return
        if (message.recipient.equals("QRU", true) && responder.settings.qru) {
            answerQru(message.sender, message.text, link, call, t)
            return
        }
        if (!message.recipient.equals(call, true)) return
        val path = packet.path.joinToString(",")
        for (answer in responder.directed(message.sender, message.text, path, t, facts)) perform(answer, message.sender, link, call)
    }

    private fun facts(t: Long) = Responder.Facts(
        version = applicationVersion,
        directs = radioHeard.value.filterValues { t - it < 3_600_000 }.keys.toList(),
        objects = entities.value.filter { it.enabled && it.alive }.map { it.name },
        igate = "<IGATE,MSG_CNT=${counters.value.gatedToRadio},LOC_CNT=${radioHeard.value.size}",
        isIgate = links.value.values.any { it.config.igateToInternet },
        hasWeather = weather.current(t) != null,
        heard = { target ->
            val when_ = radioHeard.value[target.uppercase()]
            if (when_ == null) "$target not heard on RF" else "$target heard on RF ${(t - when_) / 60_000} min ago"
        },
    )

    private fun perform(answer: Responder.Answer, to: String, link: PortLink?, call: String) {
        when (answer) {
            is Responder.Answer.Message -> scope.launch {
                runCatching { transport.deliver(call, to, answer.text, null, if (link != null) "rf" else "is") }
            }
            Responder.Answer.Position -> beaconRequested.value = true
            Responder.Answer.Status -> statusRequested.value = true
            Responder.Answer.Weather -> weatherRequested.value = true
            Responder.Answer.Requeue -> scope.launch { runCatching { store.requeuePending(call, to) } }
        }
    }

    private fun answerQru(sender: String, text: String, link: PortLink?, call: String, t: Long) {
        val s = responder.settings
        val query = QruObjects.query(text, s.qruDefaultKm, 500) ?: return
        val origin = details.value.firstOrNull { it.callsign == sender }?.let { AprsFix(it.latitude, it.longitude, t) }
            ?: return
        val candidates = entities.value.filter { it.enabled && it.alive && it.group.isNotBlank() }.mapNotNull { e ->
            entityPosition(e, t)?.let { QueryObject(e.name, e.group.uppercase(), it) to e }
        }
        val nearby = QruObjects.nearby(candidates.map { it.first }, origin, query, s.qruMaximum.coerceIn(1, 10))
        for (hit in nearby) {
            val e = candidates.first { it.first == hit }.second
            val body = runCatching {
                QruObjects.item(call, e.name.take(9), BeaconPosition(hit.position),
                    BeaconFormat(table = e.symbolTable.firstOrNull() ?: '/', symbol = e.symbol.firstOrNull() ?: '/',
                        timestamp = BeaconTimestamp.NONE), e.comment)
            }.getOrNull() ?: continue
            scope.launch { runCatching { transport.deliver(call, sender, body, null, if (link != null) "rf" else "is") } }
        }
    }

    // MARK: Transmit helpers

    /** Sends an info field as this station: APRS-IS when verified (and [toInternet]), and every beacon port when [toRadio]. */
    private suspend fun transmit(call: String, info: String, toInternet: Boolean, toRadio: Boolean,
                                 destination: String = "APRS"): List<String> {
        val routes = mutableListOf<String>()
        val transportClient = activeClient.value
        if (toInternet && transportClient != null && transportClient.state.value == AprsConnectionState.VERIFIED &&
            isAccount.value == call) {
            val line = "$call>$destination,TCPIP*:$info\r\n"
            try {
                transportClient.sendBroadcast(call, line)
                routes += "APRS-IS"
                logPacket("APRS-IS", "TX", line)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
            }
        }
        if (toRadio && RadioPacket.address(call)) {
            for (port in links.value.values) {
                if (!port.config.beacons || !port.isConnected || !port.config.transmit) continue
                val path = runCatching { PortLink.pathList(port.config.path) }.getOrDefault(emptyList())
                val packet = runCatching { RadioPacket(call, destination, path, info) }.getOrNull() ?: continue
                if (port.send(packet)) {
                    routes += port.config.name
                    logPacket(port.config.name, "TX", packet.line())
                }
            }
        }
        return routes
    }

    private val journal = MutableStateFlow<List<BeaconJournalEntry>>(emptyList())
    /** The last 200 reports this station sent, newest last. */
    val beaconJournal: List<BeaconJournalEntry> get() = journal.value

    private fun note(kind: String, reason: String, routes: List<String>, info: String) {
        journal.update { (it + BeaconJournalEntry(now(), kind, reason, routes.joinToString(" + "), info)).takeLast(200) }
    }

    // MARK: Beacons (interval, GeniusBeaconing or SmartBeaconing)

    private data class BeaconSettings(val enabled: Boolean, val mode: String, val timing: BeaconTiming,
                                      val format: BeaconFormat, val comment: String)

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
    val lastBeaconMillis: Long get() = beaconLast.value
    val nextBeaconMillis: Long get() = beaconNext.value
    val lastBeaconReason: String get() = beaconWhy.value
    val lastBeaconRoutes: String get() = beaconRoutes.value

    /**
     * Applies beacon settings. [mode] is "interval" (every [maximumSeconds]), "genius" (GeniusBeaconing: also when
     * the position strays [forecastErrorMeters] from the forecast, after [distanceMeters], or a [headingDegrees]
     * turn) or "smart" (SmartBeaconing: [maximumSeconds] when slower than [slowKnots], [fastSeconds] at
     * [fastKnots] and above, scaled between, plus corner pegging after a turn of [headingDegrees] + [turnSlope]/speed
     * no sooner than [turnSeconds]). Never sooner than [minimumSeconds].
     * Format: [micE] sends Mic-E with [micEStatus] (e.g. "!ENROUTE!"); [compressed] base-91; [precision] -4…-1
     * for position ambiguity or 1, 2, 4 for DAO extra precision; [timestamp] "none", "hms" or "dhm".
     */
    fun configureBeacon(enabled: Boolean, mode: String, minimumSeconds: Int, maximumSeconds: Int,
                        forecastErrorMeters: Double, distanceMeters: Double, headingDegrees: Double,
                        slowKnots: Double, fastKnots: Double, fastSeconds: Int, turnSlope: Double, turnSeconds: Int,
                        symbolTable: String, symbol: String, comment: String,
                        micE: Boolean, micEStatus: String, compressed: Boolean, precision: Int, timestamp: String,
                        altitude: Boolean, courseSpeed: Boolean): Boolean {
        val settings = runCatching {
            require(symbolTable.length == 1 && symbol.length == 1 && mode in listOf("interval", "genius", "smart"))
            val text = comment.trim()
            require(text.length <= 60 && text.all { it.code in 32..126 && it !in "|~{" })
            val min = minimumSeconds.coerceIn(10, 3600)
            val timing = when (mode) {
                "genius" -> BeaconTiming(minimumSeconds = min, maximumSeconds = maximumSeconds.coerceIn(min, 86_400),
                    headingDegrees = headingDegrees, forecastErrorMeters = forecastErrorMeters, distanceMeters = distanceMeters)
                "smart" -> BeaconTiming(minimumSeconds = min, maximumSeconds = maximumSeconds.coerceIn(min, 86_400),
                    headingDegrees = headingDegrees, smart = true, slowKnots = slowKnots, fastKnots = fastKnots,
                    fastSeconds = fastSeconds.coerceIn(10, 86_400), turnSlope = turnSlope, turnSeconds = turnSeconds.coerceIn(10, 3600))
                else -> BeaconTiming(minimumSeconds = 60, maximumSeconds = maximumSeconds.coerceIn(60, 86_400), timeOnly = true)
            }
            val format = BeaconFormat(table = symbolTable[0], symbol = symbol[0],
                timestamp = when (timestamp) { "hms" -> BeaconTimestamp.HMS; "dhm" -> BeaconTimestamp.DHM; else -> BeaconTimestamp.NONE },
                compressed = compressed && !micE, courseSpeed = courseSpeed, altitude = altitude, precision = precision,
                statusTag = if (micE) micEStatus else "", micE = micE)
            // Let the core validate the symbol and comment exactly as it will format them.
            BeaconPackets.position("N0CALL", BeaconPosition(AprsFix(41.0, -88.0, 0)), format, text)
            BeaconSettings(enabled, mode, timing, format, text)
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

    private fun radioReady() = links.value.values.any { it.isConnected && it.config.transmit && it.config.beacons }

    private suspend fun beaconLoop() {
        var policy: AdaptiveBeaconPolicy? = null
        var policyTiming: BeaconTiming? = null
        var policyCall: String? = null
        var wasVerified = false
        while (true) {
            delay(1000)
            val t = now()
            val settings = beaconSettings.value
            val requested = beaconRequested.value
            if (settings == null || (!settings.enabled && !requested)) {
                beaconStatus.value = "OFF"
                beaconNext.value = 0L
                beaconRequested.value = false
                continue
            }
            val transportClient = activeClient.value
            val verified = transportClient?.state?.value == AprsConnectionState.VERIFIED
            val reconnected = verified && !wasVerified
            wasVerified = verified
            val radio = radioReady()
            val call = (if (verified) isAccount.value else null) ?: account.value?.takeIf { radio && RadioPacket.address(it) }
            if (call == null || (!verified && !radio)) {
                beaconStatus.value = if (transportClient == null && !radio) "NOT_CONNECTED" else "NOT_VERIFIED"
                beaconNext.value = 0L
                continue
            }
            val input = beaconFix.value
            if (input == null || t - input.position.fix.timeMillis !in -60_000L..600_000L) {
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
            if (requested && last != 0L && t - last < 30_000) {
                beaconRequested.value = false
                beaconStatus.value = "TOO_SOON"
                continue
            }
            val position = input.position.copy(fix = input.position.fix.copy(timeMillis = t))
            val decision = activePolicy.evaluate(position, t, movingSource = input.moving, forced = requested,
                reconnected = reconnected && last != 0L)
            if (decision == null) {
                beaconNext.value = (activePolicy.lastSent ?: t) + settings.timing.maximumSeconds * 1000L
                if (beaconStatus.value != "SENT" || t - last > 10_000) {
                    beaconStatus.value = if (settings.mode != "interval" && input.moving) "WATCHING" else "SCHEDULED"
                }
                continue
            }
            beaconRequested.value = false
            val line = try {
                BeaconPackets.position(call, position, settings.format, settings.comment, decision.reason)
            } catch (_: Exception) {
                beaconStatus.value = "FAILED"; continue
            }
            val destination = line.substringAfter('>').substringBefore(',')
            val info = line.substringAfter(':').trimEnd('\r', '\n')
            val routes = transmit(call, info, toInternet = verified, toRadio = true, destination = destination)
            if (routes.isEmpty()) {
                beaconStatus.value = "FAILED"
                continue
            }
            activePolicy.sent(position, t)
            beaconLast.value = t
            beaconNext.value = t + settings.timing.maximumSeconds * 1000L
            beaconWhy.value = decision.reason
            beaconRoutes.value = routes.joinToString(" + ")
            beaconStatus.value = "SENT"
            note("Position", decision.reason, routes, info)
        }
    }

    // MARK: Objects, items, bulletins, status, telemetry and weather on a schedule

    private val entities = MutableStateFlow<List<OwnEntity>>(emptyList())
    private val entityState = MutableStateFlow<Map<String, EntityStatus>>(emptyMap())
    private val bulletinSchedule = MutableStateFlow<List<ScheduledBulletin>>(emptyList())
    private val bulletinSent = MutableStateFlow<Map<String, Long>>(emptyMap())
    private val statusSettings = MutableStateFlow<StatusBeaconSettings?>(null)
    private val statusRequested = MutableStateFlow(false)
    private val telemetrySettings = MutableStateFlow<TelemetrySettings?>(null)
    private val telemetrySequenceState = MutableStateFlow(0)
    private val telemetryInputs = MutableStateFlow<Map<String, Double>>(emptyMap())
    private val weatherSettings = MutableStateFlow<WeatherBeaconSettings?>(null)
    private val weatherRequested = MutableStateFlow(false)
    private val weather = WeatherInput()
    private val weatherState = MutableStateFlow<LocalWeather?>(null)
    private val cwopState = MutableStateFlow("")

    /** Replaces the objects and items this station publishes. Returns the ids that are invalid. */
    fun setEntities(list: List<OwnEntity>): List<String> {
        val valid = list.filter { EntityPackets.validate(it) }
        val old = entities.value.associateBy { it.id }
        // A newly killed object is sent three times as deleted; reviving resets that.
        entityState.update { states ->
            valid.associate { e ->
                val previous = states[e.id] ?: EntityStatus(e.id, 0, 0, null)
                val wasAlive = old[e.id]?.alive ?: true
                e.id to when {
                    !e.alive && wasAlive -> previous.copy(killsLeft = 3, lastSentMillis = 0)
                    e.alive -> previous.copy(killsLeft = 0)
                    else -> previous
                }
            }
        }
        entities.value = valid
        return list.map { it.id } - valid.map { it.id }.toSet()
    }

    val entityStatuses: List<EntityStatus> get() = entityState.value.values.toList()

    /** Sends an object or item now. */
    fun sendEntityNow(id: String) { entityState.update { m -> m[id]?.let { m + (id to it.copy(lastSentMillis = 0)) } ?: m } }

    fun setScheduledBulletins(list: List<ScheduledBulletin>): List<String> {
        val valid = list.filter { b -> runCatching { EntityPackets.bulletin("N0CALL", b) }.isSuccess && b.intervalMinutes in 1..1440 }
        bulletinSchedule.value = valid
        return list.map { it.id } - valid.map { it.id }.toSet()
    }

    fun sendBulletinNow(id: String) { bulletinSent.update { it - id } }

    fun configureStatus(settings: StatusBeaconSettings): Boolean {
        if (settings.text.length > 62 || settings.text.any { it.code !in 32..126 || it in "|~" }) return false
        statusSettings.value = settings
        return true
    }

    fun sendStatusNow() { statusRequested.value = true }

    /** Applies own-telemetry settings and continues the sequence from [sequence] (saved by the app across restarts). */
    fun configureTelemetry(settings: TelemetrySettings, sequence: Int): Boolean {
        if (settings.sources.size != 5 || settings.intervalMinutes !in 1..1440) return false
        telemetrySettings.value = settings
        if (telemetrySequenceState.value == 0) telemetrySequenceState.value = sequence.coerceIn(0, 999)
        telemetryDefinitionsSent = 0
        return true
    }

    val telemetrySequence: Int get() = telemetrySequenceState.value

    /** A named value for "input:KEY" telemetry channels. */
    fun setTelemetryInput(key: String, value: Double) { telemetryInputs.update { it + (key to value) } }

    fun configureWeatherBeacon(settings: WeatherBeaconSettings) { weatherSettings.value = settings }

    fun sendWeatherNow() { weatherRequested.value = true }

    /** Station elevation, so Tempest station pressure can be reported at sea level. */
    fun setWeatherElevation(meters: Double) { weather.elevationMeters = meters }

    /**
     * Weather station input from the app: [kind] "tempest-rest" (WeatherFlow REST JSON), "json" (SI keys),
     * "text" (wxnow.txt or Ultimeter) or "tempest-udp" (one local broadcast). Returns true when it was understood.
     */
    fun weatherInput(kind: String, text: String, utcOffsetMinutes: Int): Boolean {
        val t = now()
        val ok = when (kind) {
            "tempest-rest" -> weather.tempestRest(text, t)
            "tempest-udp" -> weather.tempestUdp(text, t, utcOffsetMinutes)
            "json" -> weather.json(text, t)
            else -> weather.text(text, t)
        }
        if (ok) weatherState.value = weather.current(t)
        return ok
    }

    val localWeather: LocalWeather? get() = weatherState.value
    /** The last CWOP upload result. */
    val cwopStatus: String get() = cwopState.value

    private var telemetryDefinitionsSent = 0
    private var telemetryLast = 0L
    private var statusLast = 0L
    private var weatherLast = 0L
    private var cwopLast = 0L

    private fun entityPosition(e: OwnEntity, t: Long): AprsFix? =
        if (e.following) beaconFix.value?.position?.fix?.copy(timeMillis = t) ?: ownFix.value?.copy(timeMillis = t)
        else runCatching { AprsFix(e.latitude, e.longitude, t) }.getOrNull()

    private suspend fun schedulerLoop() {
        while (true) {
            delay(1000)
            val call = account.value ?: continue
            val t = now()
            runCatching { entitiesDue(call, t) }
            runCatching { bulletinsDue(call, t) }
            runCatching { statusDue(call, t) }
            runCatching { telemetryDue(call, t) }
            runCatching { weatherDue(call, t) }
            weatherState.value = weather.current(t)
        }
    }

    private suspend fun entitiesDue(call: String, t: Long) {
        for (e in entities.value) {
            if (!e.enabled) continue
            val st = entityState.value[e.id] ?: EntityStatus(e.id, 0, 0, null)
            if (!e.alive && st.killsLeft <= 0) continue
            val interval = if (e.alive) e.intervalSeconds * 1000L else 60_000L
            if (st.lastSentMillis != 0L && t - st.lastSentMillis < interval) continue
            val position = entityPosition(e, t)
            if (position == null) { entityState.update { it + (e.id to st.copy(error = "No position")) }; continue }
            val info = runCatching { EntityPackets.entity(call, e, position, t, e.alive) }.getOrNull()
            if (info == null) { entityState.update { it + (e.id to st.copy(error = "Invalid")) }; continue }
            val routes = transmit(call, info, e.toInternet, e.toRadio)
            if (routes.isEmpty()) { entityState.update { it + (e.id to st.copy(error = "Not connected")) }; continue }
            entityState.update { it + (e.id to st.copy(lastSentMillis = t, error = null, killsLeft = if (e.alive) 0 else st.killsLeft - 1)) }
            note(if (e.item) "Item ${e.name}" else "Object ${e.name}", if (e.alive) "Schedule" else "Killed", routes, info)
        }
    }

    private suspend fun bulletinsDue(call: String, t: Long) {
        for (b in bulletinSchedule.value) {
            if (!b.enabled) continue
            val last = bulletinSent.value[b.id]
            if (last != null && t - last < b.intervalMinutes * 60_000L) continue
            val info = runCatching { EntityPackets.bulletin(call, b) }.getOrNull() ?: continue
            val routes = transmit(call, info, b.toInternet, b.toRadio)
            if (routes.isEmpty()) continue
            bulletinSent.update { it + (b.id to t) }
            note("Bulletin BLN${b.slot}${b.group}", "Schedule", routes, info)
        }
    }

    private suspend fun statusDue(call: String, t: Long) {
        val s = statusSettings.value ?: return
        val requested = statusRequested.value
        if (!s.enabled && !requested) return
        if (!requested && statusLast != 0L && t - statusLast < s.intervalMinutes.coerceAtLeast(5) * 60_000L) return
        val grid = if (s.grid) (beaconFix.value?.position?.fix ?: ownFix.value)?.let { BeaconPackets.grid(it) }.orEmpty() else ""
        val info = runCatching { BeaconPackets.status(call, s.text, t, includeTimestamp = !s.grid, grid = grid) }.getOrNull()
            ?.substringAfter(':')?.trimEnd('\r', '\n') ?: return
        val routes = transmit(call, info, s.toInternet, s.toRadio)
        statusRequested.value = false
        if (routes.isEmpty()) return
        statusLast = t
        note("Status", if (requested) "Requested" else "Schedule", routes, info)
    }

    private fun channelValue(source: String, t: Long): Int {
        val c = counters.value
        val v = when {
            source == "rf" -> c.heardRf.toDouble()
            source == "is" -> c.heardInternet.toDouble()
            source == "digi" -> c.digipeated.toDouble()
            source == "gated" -> c.gatedToInternet.toDouble()
            source == "torf" -> c.gatedToRadio.toDouble()
            source == "msgs" -> c.messagesReceived.toDouble()
            source == "stations" -> details.value.size.toDouble()
            source == "uptime" -> ((t - startedAt) / 60_000).toDouble()
            source.startsWith("const:") -> source.substringAfter(':').toDoubleOrNull() ?: 0.0
            source.startsWith("input:") -> telemetryInputs.value[source.substringAfter(':')] ?: 0.0
            else -> 0.0
        }
        // Counters wrap so they always fit a raw telemetry value.
        return if (source.startsWith("const:") || source.startsWith("input:")) v.toInt().coerceIn(0, 255) else (v.toLong() % 256).toInt()
    }

    private suspend fun telemetryDue(call: String, t: Long) {
        val s = telemetrySettings.value ?: return
        if (!s.enabled) return
        if (telemetryLast != 0L && t - telemetryLast < s.intervalMinutes * 60_000L) return
        // Definitions first, then again every tenth report so new listeners learn the channel names.
        if (telemetryDefinitionsSent == 0 || telemetrySequenceState.value % 10 == 0) {
            for (info in EntityPackets.definitions(call, s)) transmit(call, info, s.toInternet, s.toRadio)
            telemetryDefinitionsSent++
        }
        val values = s.sources.map { channelValue(it, t) }
        val bits = (0 until 8).joinToString("") { i -> if (i == 0 && activeClient.value?.state?.value == AprsConnectionState.VERIFIED) "1" else if (i == 1 && radioReady()) "1" else "0" }
        val seq = (telemetrySequenceState.value + 1) % 1000
        val info = EntityPackets.telemetry(seq, values, bits)
        val routes = transmit(call, info, s.toInternet, s.toRadio)
        if (routes.isEmpty()) return
        telemetrySequenceState.value = seq
        telemetryLast = t
        note("Telemetry", "Schedule", routes, info)
    }

    private suspend fun weatherDue(call: String, t: Long) {
        val s = weatherSettings.value ?: return
        val requested = weatherRequested.value
        if (!s.enabled && !requested) return
        val w = weather.current(t) ?: return
        if (t - w.timeMillis > 900_000) return
        val position = beaconFix.value?.position?.fix ?: ownFix.value ?: return
        if (requested || weatherLast == 0L || t - weatherLast >= s.intervalMinutes.coerceAtLeast(5) * 60_000L) {
            weatherRequested.value = false
            val fields = WeatherInput.aprsFields(w)
            val info = runCatching {
                if (s.objectName.isNotBlank()) EntityPackets.entity(call, OwnEntity("wx", s.objectName.trim().take(9), false,
                    position.latitude, position.longitude, "/", "_", fields, false, true, true, 600, true, true, "", "", false, "j"),
                    position.copy(timeMillis = t), t, true)
                else BeaconPackets.position(call, BeaconPosition(position.copy(timeMillis = t)),
                    BeaconFormat(table = '/', symbol = '_', timestamp = BeaconTimestamp.NONE, messaging = false,
                        courseSpeed = false, altitude = false), fields).substringAfter(':').trimEnd('\r', '\n')
            }.getOrNull() ?: return
            val routes = transmit(call, info, s.toInternet, s.toRadio)
            if (routes.isNotEmpty()) {
                weatherLast = t
                note("Weather", if (requested) "Requested" else "Schedule", routes, info)
            }
        }
        // CWOP asks for one report every 5–10 minutes at most.
        if (s.cwop && s.cwopCallsign.isNotBlank() && (cwopLast == 0L || t - cwopLast >= s.intervalMinutes.coerceAtLeast(5) * 60_000L)) {
            cwopLast = t
            val cw = s.cwopCallsign.trim().uppercase()
            val packet = runCatching {
                BeaconPackets.position(cw, BeaconPosition(position.copy(timeMillis = t)),
                    BeaconFormat(table = '/', symbol = '_', timestamp = BeaconTimestamp.DHM, messaging = false,
                        courseSpeed = false, altitude = false), WeatherInput.aprsFields(w))
            }.getOrNull() ?: run { cwopState.value = "Invalid CWOP callsign"; return }
            val host = s.cwopServer.substringBefore(':').ifBlank { "cwop.aprs.net" }
            val port = s.cwopServer.substringAfter(':', "14580").toIntOrNull() ?: 14580
            scope.launch {
                cwopState.value = try {
                    CwopUploader.upload(host, port, cw, s.cwopPasscode, packet, applicationVersion)
                    logPacket("CWOP", "TX", packet)
                    "Uploaded " + packet.substringAfter(':').take(40)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (e: Exception) {
                    "Upload failed: " + (e.message ?: "network error")
                }
            }
        }
    }

    // MARK: Services: local server, UDP input, syslog, Tempest, external GPS

    private val server = IsServer(scope) { client, line -> forwardServiceLine("IS-Server $client", line) }
    private val udpInput = UdpListener(scope) { text, from -> udpLines(text, from) }
    private val tempest = UdpListener(scope) { text, _ -> weatherInput("tempest-udp", text, utcOffset); }
    private val syslog = SyslogSender(scope)
    private var utcOffset = 0
    private val serviceForward = MutableStateFlow(Pair(false, false))
    private val udpAllowed = MutableStateFlow<List<String>>(emptyList())

    /**
     * Local APRS-IS server for other programs on [port] (14580 is usual). [localOnly] accepts connections from this
     * device only. Verified clients' packets are forwarded to APRS-IS ([toInternet]) and/or the beacon ports ([toRadio]).
     */
    fun configureServer(enabled: Boolean, port: Int, localOnly: Boolean, toInternet: Boolean, toRadio: Boolean) {
        serviceForward.value = toInternet to toRadio
        if (enabled && port in 1..65535) server.start(port, localOnly) else server.stop()
    }

    val serverState: String get() = server.state.value + (server.error.value?.let { " — $it" } ?: "") +
        if (server.clientCount.value > 0) " · ${server.clientCount.value} client(s)" else ""

    /** Accepts TNC2 packet lines as UDP datagrams on [port] from [allowedSources] (comma-separated IPs; loopback always). */
    fun configureUdpInput(enabled: Boolean, port: Int, allowedSources: String) {
        udpAllowed.value = allowedSources.split(',', ' ').map { it.trim() }.filter { it.isNotEmpty() }
        if (enabled && port in 1..65535) udpInput.start(port) else udpInput.stop()
    }

    val udpInputState: String get() = udpInput.state.value + (udpInput.error.value?.let { " — $it" } ?: "")

    fun configureSyslog(enabled: Boolean, host: String, port: Int) {
        if (enabled && host.isNotBlank() && port in 1..65535) syslog.start(host.trim(), port) else syslog.stop()
    }

    /** Listens for WeatherFlow Tempest hub broadcasts on UDP port 50222. */
    fun configureTempest(enabled: Boolean, utcOffsetMinutes: Int) {
        utcOffset = utcOffsetMinutes
        if (enabled) tempest.start(50222) else tempest.stop()
    }

    val tempestState: String get() = tempest.state.value + (tempest.error.value?.let { " — $it" } ?: "")

    private suspend fun udpLines(text: String, from: String) {
        val loopback = from.startsWith("127.") || from == "::1" || from.isEmpty()
        if (!loopback && from !in udpAllowed.value) return
        for (line in text.lines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }) forwardServiceLine("UDP $from", line)
    }

    /** Packets from local clients: never counted as heard on RF; forwarded only where enabled. */
    private suspend fun forwardServiceLine(source: String, line: String) {
        val packet = RadioPacket.parse(line) ?: return
        logPacket(source, "RX", line)
        val (toInternet, toRadio) = serviceForward.value
        val call = isAccount.value
        val transportClient = activeClient.value
        if (toInternet && call != null && transportClient?.state?.value == AprsConnectionState.VERIFIED) {
            val gated = packet.copy(path = packet.path.filterNot { it.startsWith("q") || it.trimEnd('*') in listOf("TCPIP", "TCPXX") } + listOf("qAO", call))
            runCatching { transportClient.sendGated(call, gated.line()) }.onSuccess { logPacket("APRS-IS", "TX", gated.line()) }
        }
        if (toRadio) for (port in links.value.values) {
            if (!port.config.beacons || !port.isConnected) continue
            val out = packet.copy(path = runCatching { PortLink.pathList(port.config.path) }.getOrDefault(emptyList()))
            if (port.send(out)) logPacket(port.config.name, "TX", out.line())
        }
    }

    private val nmea = NmeaPositionDecoder()
    private val sky = GpsDiagnostics()
    private val externalFixState = MutableStateFlow<ExternalFix?>(null)
    private val skyState = MutableStateFlow<GpsSkyInfo?>(null)
    private val gpsNetwork = LineClient(scope) { line -> gpsLine(line) }

    /** A network GPS: raw NMEA over TCP, or gpsd (asks it to stream NMEA). */
    fun configureGpsNetwork(enabled: Boolean, host: String, port: Int, gpsd: Boolean) {
        if (enabled && host.isNotBlank() && port in 1..65535)
            gpsNetwork.start(host.trim(), port, if (gpsd) "?WATCH={\"enable\":true,\"nmea\":true}\n" else null)
        else gpsNetwork.stop()
    }

    val gpsNetworkState: String get() = gpsNetwork.state.value + (gpsNetwork.error.value?.let { " — $it" } ?: "")

    /** One NMEA sentence from a serial or network GPS. */
    fun gpsLine(line: String) {
        val t = now()
        val text = line.trim()
        runCatching { nmea.accept(text, t) }.getOrNull()?.let { p ->
            externalFixState.value = ExternalFix(p.fix.latitude, p.fix.longitude, p.altitudeMeters, p.speedKnots, p.course,
                p.fix.accuracyMeters.takeIf { it > 0 } ?: 10.0, t)
        }
        runCatching { sky.accept(text, t) }.getOrNull()?.let { s ->
            skyState.value = GpsSkyInfo(s.satellites.map { GpsSatelliteInfo(it.constellation, it.id, it.elevation, it.azimuth, it.snr, it.used) },
                s.fixType, s.hdop, s.pdop, s.vdop, t)
        }
    }

    val externalFix: ExternalFix? get() = externalFixState.value
    val gpsSky: GpsSkyInfo? get() = skyState.value

    // MARK: Satellites

    private val satellites = Satellites()

    /** Loads TLEs (name + two lines each). Returns how many satellites loaded. */
    fun loadSatellites(tle: String): Int = satellites.load(tle)

    val satelliteList: List<SatelliteInfo> get() = satellites.list

    fun satellitePositions(names: List<String>, latitude: Double, longitude: Double, altitudeMeters: Double): List<SatellitePosition> {
        val t = now()
        return names.mapNotNull { satellites.position(it, t, latitude, longitude, altitudeMeters) }
    }

    fun satellitePasses(name: String, latitude: Double, longitude: Double, altitudeMeters: Double, hours: Int,
                        minimumElevation: Double, maximum: Int): List<SatellitePass> =
        satellites.passes(name, now(), latitude, longitude, altitudeMeters, hours, minimumElevation, maximum)

    // MARK: Messages, announcements (ANSRVR), email

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

    @Throws(Exception::class)
    suspend fun markRead(account: String, peer: String) { store.markRead(account, peer) }

    @Throws(Exception::class)
    suspend fun conversationOptions(account: String, peer: String): ConversationOptions =
        store.options(account, peer).let { ConversationOptions(it.route, it.requestAck) }

    /** [route] is "best", "rf" or "is". */
    @Throws(Exception::class)
    suspend fun saveConversationOptions(account: String, peer: String, route: String, requestAck: Boolean): Boolean {
        if (route !in listOf("best", "rf", "is")) return false
        store.saveOptions(account, peer, ChatOptions(route, requestAck))
        return true
    }

    /** Queues a retry of a message that was rejected or never acknowledged. */
    @Throws(Exception::class)
    suspend fun retry(account: String, row: Long) { store.retry(account, row) }

    /**
     * Queues an ANSRVR command through the message outbox: [action] "J" joins [group], "U" leaves it,
     * "CQ" sends [text] to every member, "K" leaves all groups, "?" asks which groups you are in, "L" lists groups.
     */
    @Throws(Exception::class)
    suspend fun announcement(account: String, action: String, group: String, text: String): Boolean {
        val body = runCatching { AprsServices.group(action, group, text) }.getOrNull() ?: return false
        store.enqueue(account, "ANSRVR", body)
        return true
    }

    /** Sends an email through an APRS email gateway (EMAIL-2 by default), split into numbered parts when long. */
    @Throws(Exception::class)
    suspend fun email(account: String, gateway: String, address: String, body: String): Boolean {
        val parts = runCatching { EmailMessages.packets(address.trim(), body.trim()) }.getOrNull() ?: return false
        store.enqueueParts(account, gateway.trim().uppercase().ifEmpty { "EMAIL-2" }, parts)
        return true
    }

    // Last, so every property above is initialized before the loops start.
    init {
        scope.launch(insightThread) {
            var tick = 0L
            while (true) {
                runCatching { publish() }
                if (tick % 5 == 0L) runCatching { flushArchive() }
                if (tick % 3600 == 10L) runCatching { archive?.expire(now()) }
                tick++
                delay(1000)
            }
        }
        scope.launch { beaconLoop() }
        scope.launch { schedulerLoop() }
    }
}

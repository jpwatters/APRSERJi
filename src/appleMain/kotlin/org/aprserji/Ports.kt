// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import io.ktor.network.selector.SelectorManager
import io.ktor.network.sockets.*
import io.ktor.utils.io.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.aprsfoundation.core.AprsTnc
import org.aprsfoundation.core.MobileRadio
import org.aprsfoundation.core.RadioPacket

/**
 * One radio port as the user set it up. [kind] is "TCP" (a software modem or network TNC: Dire Wolf, UZ7HO,
 * AGWPE, a KISS-over-TCP TNC) or "EXTERNAL" (bytes carried by the app itself: a serial port, Bluetooth SPP or
 * Bluetooth LE KISS on the Mac). [framing] is "KISS", "AGW" or "TNC2" (Kenwood/TEXT TNC2 monitor lines).
 */
data class PortConfig(
    val id: String,
    val name: String,
    val kind: String,
    val host: String,
    val port: Int,
    val framing: String,
    val channel: Int,
    /** Transmit at all on this port (beacons, messages, objects, digipeats, IGate). Off makes it receive-only. */
    val transmit: Boolean,
    /** Send position, status, object, bulletin, telemetry and weather beacons here. */
    val beacons: Boolean,
    /** Digipeat with [transforms]. */
    val digipeat: Boolean,
    /** Gate packets heard here to APRS-IS. */
    val igateToInternet: Boolean,
    /** Gate messages (and filtered packets) from APRS-IS to RF on this port. */
    val igateToRadio: Boolean,
    /** Digipeater path for packets this station originates, e.g. "WIDE1-1,WIDE2-1". */
    val path: String,
    /** Comma-separated digipeater transforms ALIAS=REPLACEMENT, e.g. "WIDE1-1=,WIDE2-2=WIDE2-1". */
    val transforms: String,
    /** Ports (by id) that also receive this port's digipeats; empty for same-port only. */
    val crossPorts: String,
)

/** What the Setup screen shows for one port. */
data class PortStatus(
    val id: String, val name: String, val kind: String,
    /** STOPPED, CONNECTING, CONNECTED or RECONNECTING. */
    val state: String,
    val error: String?, val received: Long, val transmitted: Long, val digipeated: Long, val gated: Long,
    /** Diagnostics a TNC reported (e.g. Mobilinkd audio gain), newest last. */
    val diagnostics: List<String>,
)

/** A connection carrying one radio port. */
internal abstract class PortLink(val config: PortConfig) {
    val state = MutableStateFlow("STOPPED")
    val lastError = MutableStateFlow<String?>(null)
    val received = MutableStateFlow(0L)
    val transmitted = MutableStateFlow(0L)
    val digipeated = MutableStateFlow(0L)
    val gated = MutableStateFlow(0L)
    val diagnostics = MutableStateFlow<List<String>>(emptyList())
    val isConnected: Boolean get() = state.value == "CONNECTED"
    protected val tnc = AprsTnc(
        when (config.framing) { "AGW" -> AprsTnc.Protocol.AGW; "TNC2" -> AprsTnc.Protocol.TNC2; else -> AprsTnc.Protocol.KISS },
        if (config.framing == "TNC2") 0 else config.channel,
    ).also { t -> t.diagnostic = { line -> diagnostics.value = (diagnostics.value + line).takeLast(10) } }

    abstract fun start()
    abstract fun stop()
    /** Queues one packet for the radio. Returns false when not connected, receive-only, or the queue is full. */
    abstract fun send(packet: RadioPacket): Boolean

    protected fun encode(packet: RadioPacket): ByteArray? = runCatching { tnc.encode(packet) }.getOrNull()

    fun status() = PortStatus(config.id, config.name, config.kind, state.value, lastError.value, received.value,
        transmitted.value, digipeated.value, gated.value, diagnostics.value)

    companion object {
        fun validate(c: PortConfig): Boolean = runCatching {
            require(c.id.isNotBlank() && c.name.isNotBlank() && c.name.length <= 40)
            require(c.kind in listOf("TCP", "EXTERNAL") && c.framing in listOf("KISS", "AGW", "TNC2"))
            require(c.channel in (if (c.framing == "AGW") 0..255 else 0..15))
            if (c.kind == "TCP") require(c.host.isNotBlank() && c.port in 1..65535)
            pathList(c.path)
            transformList(c.transforms)
        }.isSuccess

        fun pathList(text: String): List<String> = text.split(',').map { it.trim().uppercase() }.filter { it.isNotEmpty() }
            .also { require(it.size <= 8 && it.all(RadioPacket::address)) }

        fun transformList(text: String): List<String> = text.split(',').map { it.trim().uppercase() }.filter { it.isNotEmpty() }
            .also { list -> require(list.all { it.contains('=') && RadioPacket.address(it.substringBefore('=')) }) }
    }
}

/** A KISS, AGWPE or TNC2 server reached over TCP. Reconnects with back-off after a drop. */
internal class TcpPortLink(config: PortConfig, private val scope: CoroutineScope,
                           private val onPacket: suspend (PortLink, RadioPacket) -> Unit) : PortLink(config) {
    private var job: Job? = null
    private var outgoing = Channel<ByteArray>(64)

    override fun start() {
        stop()
        outgoing = Channel(64)
        val queue = outgoing
        job = scope.launch {
            var attempt = 0
            while (isActive) {
                state.value = if (attempt == 0) "CONNECTING" else "RECONNECTING"
                try {
                    session(queue) { attempt = 0 }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    lastError.value = error.message ?: "Connection failed"
                }
                if (!isActive) break
                state.value = "RECONNECTING"
                delay(MobileRadio.retrySeconds(attempt++) * 1000L)
            }
        }
    }

    override fun stop() {
        job?.cancel()
        job = null
        outgoing.close()
        state.value = "STOPPED"
    }

    override fun send(packet: RadioPacket): Boolean {
        if (!isConnected || !config.transmit) return false
        val bytes = encode(packet) ?: return false
        return outgoing.trySend(bytes).isSuccess
    }

    private suspend fun session(queue: Channel<ByteArray>, connected: () -> Unit) {
        val selector = SelectorManager(Dispatchers.Default)
        try {
            val socket = withTimeout(15_000) { aSocket(selector).tcp().connect(config.host.trim(), config.port) }
            try {
                val input = socket.openReadChannel()
                val output = socket.openWriteChannel(autoFlush = true)
                tnc.openCommand()?.let { output.writeFully(it, 0, it.size) }
                state.value = "CONNECTED"
                lastError.value = null
                connected()
                val writer = scope.launch {
                    for (bytes in queue) {
                        output.writeFully(bytes, 0, bytes.size)
                        transmitted.value += 1
                    }
                }
                try {
                    val buffer = ByteArray(4096)
                    while (true) {
                        val count = input.readAvailable(buffer, 0, buffer.size)
                        if (count < 0) break
                        if (count == 0) continue
                        for (packet in tnc.receive(buffer.copyOf(count))) {
                            received.value += 1
                            onPacket(this, packet)
                        }
                    }
                    lastError.value = "The modem closed the connection"
                } finally {
                    writer.cancel()
                }
            } finally {
                socket.close()
            }
        } finally {
            selector.close()
        }
    }
}

/**
 * A port whose bytes the app carries itself (serial, Bluetooth SPP, Bluetooth LE). The app reports its link
 * state, hands received bytes to [accept] and collects bytes to write with [takeOutgoing].
 */
internal class ExternalPortLink(config: PortConfig, private val onPacket: suspend (PortLink, RadioPacket) -> Unit) :
    PortLink(config) {
    /** Thread-safe: the app drains it from the main thread while the engine fills it from its own. */
    private val outgoing = Channel<ByteArray>(64)

    override fun start() { if (state.value == "STOPPED") state.value = "CONNECTING" }
    override fun stop() {
        state.value = "STOPPED"
        while (outgoing.tryReceive().isSuccess) { /* drop what was queued */ }
    }

    fun linkState(connected: Boolean, error: String?) {
        state.value = if (connected) "CONNECTED" else if (state.value == "STOPPED") "STOPPED" else "RECONNECTING"
        lastError.value = error
    }

    /** Bytes for the app to open the link with (AGW raw-frame mode, Mobilinkd setting queries). */
    fun openingBytes(): List<ByteArray> = listOfNotNull(tnc.openCommand()) +
        (if (config.framing == "KISS") runCatching { tnc.mobilinkdSetupQueries() }.getOrDefault(emptyList()) else emptyList())

    suspend fun accept(bytes: ByteArray) {
        for (packet in tnc.receive(bytes)) {
            received.value += 1
            onPacket(this, packet)
        }
    }

    fun takeOutgoing(): ByteArray? = outgoing.tryReceive().getOrNull()?.also { transmitted.value += 1 }

    override fun send(packet: RadioPacket): Boolean {
        if (!isConnected || !config.transmit) return false
        val bytes = encode(packet) ?: return false
        return outgoing.trySend(bytes).isSuccess
    }
}

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
import org.aprsfoundation.core.Agw
import org.aprsfoundation.core.AgwDecoder
import org.aprsfoundation.core.Ax25Ui
import org.aprsfoundation.core.Kiss
import org.aprsfoundation.core.KissDecoder
import org.aprsfoundation.core.RadioPacket

/**
 * A software modem or network TNC reached over TCP: KISS (Dire Wolf on port 8001, UZ7HO Sound Modem's KISS
 * server on 8100) or AGWPE (Dire Wolf, UZ7HO and AGWPE on 8000). Received AX.25 UI frames are handed to
 * [onPacket] as TNC2 text; [send] queues a frame for transmission. Reconnects every 5 seconds after a drop.
 */
class TncLink(private val scope: CoroutineScope, private val onPacket: suspend (RadioPacket) -> Unit) {
    /** STOPPED, CONNECTING, CONNECTED or RECONNECTING. */
    val state = MutableStateFlow("STOPPED")
    val lastError = MutableStateFlow<String?>(null)
    val received = MutableStateFlow(0L)
    val transmitted = MutableStateFlow(0L)

    private var job: Job? = null
    private var outgoing = Channel<ByteArray>(32)
    private var protocol = "KISS"
    private var channel = 0

    val isConnected: Boolean get() = state.value == "CONNECTED"

    /** [protocol] is "KISS" or "AGW"; [channel] is the KISS channel or AGW port (0 for most setups). */
    fun start(host: String, port: Int, protocol: String, channel: Int): Boolean {
        if (host.isBlank() || port !in 1..65535 || protocol !in listOf("KISS", "AGW") || channel !in 0..15) return false
        stop()
        this.protocol = protocol
        this.channel = channel
        outgoing = Channel(32)
        val queue = outgoing
        job = scope.launch {
            while (isActive) {
                state.value = if (state.value == "STOPPED") "CONNECTING" else "RECONNECTING"
                try {
                    session(host, port, queue)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    lastError.value = error.message ?: "Connection failed"
                }
                if (!isActive) break
                state.value = "RECONNECTING"
                delay(5_000)
            }
        }
        return true
    }

    fun stop() {
        job?.cancel()
        job = null
        outgoing.close()
        state.value = "STOPPED"
    }

    /** Queues one packet for the radio. Returns false when not connected or the queue is full. */
    fun send(packet: RadioPacket): Boolean {
        if (!isConnected) return false
        val bytes = runCatching {
            if (protocol == "AGW") Agw.packet(channel, packet) else Kiss.encode(packet, channel)
        }.getOrNull() ?: return false
        return outgoing.trySend(bytes).isSuccess
    }

    private suspend fun session(host: String, port: Int, queue: Channel<ByteArray>) {
        val selector = SelectorManager(Dispatchers.Default)
        try {
            val socket = withTimeout(15_000) { aSocket(selector).tcp().connect(host, port) }
            try {
                val input = socket.openReadChannel()
                val output = socket.openWriteChannel(autoFlush = true)
                if (protocol == "AGW") {
                    // 'k' asks AGWPE-compatible servers for raw AX.25 frames on every port.
                    val enable = Agw.encode(0, 'k')
                    output.writeFully(enable, 0, enable.size)
                }
                state.value = "CONNECTED"
                lastError.value = null
                val writer = scope.launch {
                    for (bytes in queue) {
                        output.writeFully(bytes, 0, bytes.size)
                        transmitted.value += 1
                    }
                }
                try {
                    val kiss = KissDecoder(channel)
                    val agw = AgwDecoder()
                    val buffer = ByteArray(4096)
                    while (true) {
                        val count = input.readAvailable(buffer, 0, buffer.size)
                        if (count < 0) break
                        if (count == 0) continue
                        val bytes = buffer.copyOf(count)
                        val packets = if (protocol == "AGW") {
                            agw.accept(bytes).filter { it.kind == 'K' && it.data.size > 1 && it.port == channel }
                                .mapNotNull { Ax25Ui.decode(it.data.copyOfRange(1, it.data.size)) }
                        } else kiss.accept(bytes)
                        for (packet in packets) {
                            received.value += 1
                            onPacket(packet)
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

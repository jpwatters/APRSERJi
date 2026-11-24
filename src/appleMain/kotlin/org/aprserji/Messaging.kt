// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.onEach
import org.aprsfoundation.core.AprsConnectionState
import org.aprsfoundation.core.AprsIsClient
import org.aprsfoundation.core.AprsMessage
import org.aprsfoundation.core.AprsMessageTransport
import org.aprsfoundation.core.AprsMessages
import org.aprsfoundation.core.AprsTnc
import org.aprsfoundation.core.PendingChat

/** A conversation's delivery settings: route "best", "rf" or "is", and whether to ask for acknowledgments. */
data class ConversationOptions(val route: String, val requestAck: Boolean)

/**
 * Carries chat over APRS-IS, the radio ports, or both, following each conversation's route:
 * "is" uses only APRS-IS, "rf" only the radio, and "best" the radio when the recipient was heard there
 * recently (or APRS-IS is down) and APRS-IS otherwise. Messages without ACK go out unnumbered.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class RoutedTransport(
    private val internet: MutableStateFlow<AprsIsClient?>,
    private val radioPorts: () -> List<PortLink>,
    private val heardOnRadio: (String) -> Boolean,
    private val onSent: (port: String, line: String) -> Unit,
    private val onReceived: suspend (AprsMessage) -> Unit,
) : AprsMessageTransport {
    /** Messages to this station heard on the radio. */
    val fromRadio = MutableSharedFlow<AprsMessage>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    override val messages: Flow<AprsMessage> =
        merge(internet.flatMapLatest { it?.messages ?: emptyFlow() }, fromRadio).onEach { onReceived(it) }

    private fun internetReady(): AprsIsClient? = internet.value?.takeIf { it.state.value == AprsConnectionState.VERIFIED }
    private fun radios() = radioPorts().filter { it.isConnected && it.config.transmit }

    override fun canSend(): Boolean = internetReady() != null || radios().isNotEmpty()

    override suspend fun sendMessage(account: String, recipient: String, text: String, id: String) =
        deliver(account, recipient, text, id, "best")

    override suspend fun sendPending(account: String, message: PendingChat) =
        deliver(account, message.peer, message.body, if (message.requestAck) message.wireId else null, message.route)

    override suspend fun acknowledge(account: String, recipient: String, id: String) {
        // Answer the way the message is likely to come back: over the radio if the sender was heard there.
        var sent = false
        if (heardOnRadio(recipient)) for (port in radios()) {
            val packet = runCatching { AprsTnc.acknowledge(account, recipient, id, PortLink.pathList(port.config.path)) }.getOrNull()
            if (packet != null && port.send(packet)) { sent = true; onSent(port.config.name, packet.line()) }
        }
        internetReady()?.let {
            it.acknowledge(account, recipient, id)
            onSent("APRS-IS", AprsMessages.ack(account, recipient, id).trimEnd())
            sent = true
        }
        check(sent) { "No transport for the acknowledgment" }
    }

    /** Sends one message part; throws when no allowed transport took it, so the outbox retries. */
    suspend fun deliver(account: String, recipient: String, text: String, id: String?, route: String) {
        val viaRadio = when (route) {
            "rf" -> true
            "is" -> false
            else -> heardOnRadio(recipient) || internetReady() == null
        }
        if (viaRadio) {
            var sent = false
            for (port in radios()) {
                val packet = runCatching {
                    if (id != null) AprsTnc.message(account, recipient, text, id, PortLink.pathList(port.config.path))
                    else org.aprsfoundation.core.RadioPacket(account, "APRS", PortLink.pathList(port.config.path),
                        AprsMessages.unnumbered(account, recipient, text).substringAfter(':').trimEnd('\r', '\n'))
                }.getOrNull() ?: continue
                if (port.send(packet)) { sent = true; onSent(port.config.name, packet.line()) }
            }
            if (sent) return
            check(route == "best") { "No radio port can transmit" }
        }
        val client = checkNotNull(internetReady()) { "APRS-IS is not verified" }
        if (id != null) {
            client.sendMessage(account, recipient, text, id)
            onSent("APRS-IS", AprsMessages.packet(account, recipient, text, id).trimEnd())
        } else {
            val line = AprsMessages.unnumbered(account, recipient, text)
            client.sendBroadcast(account, line)
            onSent("APRS-IS", line.trimEnd())
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import io.ktor.network.selector.SelectorManager
import io.ktor.network.sockets.*
import io.ktor.utils.io.*
import io.ktor.utils.io.core.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.io.readString

/** The APRS-IS passcode for a callsign (the SSID is ignored). */
object AprsPasscode {
    fun of(callsign: String): Int {
        val call = callsign.substringBefore('-').uppercase()
        var hash = 0x73e2
        var i = 0
        while (i < call.length) {
            hash = hash xor (call[i].code shl 8)
            if (i + 1 < call.length) hash = hash xor call[i + 1].code
            i += 2
        }
        return hash and 0x7fff
    }
}

/** A line-oriented TCP reader used by the GPS (NMEA / gpsd) input. Reconnects every 10 seconds. */
internal class LineClient(private val scope: CoroutineScope, private val onLine: suspend (String) -> Unit) {
    val state = MutableStateFlow("STOPPED")
    val error = MutableStateFlow<String?>(null)
    private var job: Job? = null

    fun start(host: String, port: Int, greeting: String?) {
        stop()
        job = scope.launch {
            while (isActive) {
                state.value = "CONNECTING"
                val selector = SelectorManager(Dispatchers.Default)
                try {
                    val socket = withTimeout(15_000) { aSocket(selector).tcp().connect(host, port) }
                    try {
                        val input = socket.openReadChannel()
                        val output = socket.openWriteChannel(autoFlush = true)
                        greeting?.let { output.writeStringUtf8(it) }
                        state.value = "CONNECTED"
                        error.value = null
                        while (isActive) {
                            val line = withTimeout(60_000) { input.readUTF8Line(1024) } ?: break
                            onLine(line)
                        }
                    } finally { socket.close() }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (e: Exception) {
                    error.value = e.message ?: "Connection failed"
                } finally { selector.close() }
                state.value = "RECONNECTING"
                delay(10_000)
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        state.value = "STOPPED"
    }
}

/** Receives UDP datagrams as text on [port] (Tempest weather broadcasts, UDP packet input). */
internal class UdpListener(private val scope: CoroutineScope, private val onText: suspend (String, String) -> Unit) {
    val state = MutableStateFlow("STOPPED")
    val error = MutableStateFlow<String?>(null)
    private var job: Job? = null

    fun start(port: Int) {
        stop()
        job = scope.launch {
            while (isActive) {
                val selector = SelectorManager(Dispatchers.Default)
                try {
                    val socket = aSocket(selector).udp().bind(InetSocketAddress("0.0.0.0", port)) { broadcast = true }
                    state.value = "LISTENING"
                    error.value = null
                    try {
                        while (isActive) {
                            val datagram = socket.receive()
                            val text = datagram.packet.readString()
                            val from = (datagram.address as? InetSocketAddress)?.hostname ?: ""
                            onText(text, from)
                        }
                    } finally { socket.close() }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (e: Exception) {
                    error.value = e.message ?: "Cannot listen on UDP port $port"
                } finally { selector.close() }
                state.value = "RETRYING"
                delay(10_000)
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        state.value = "STOPPED"
    }
}

/** Sends packet lines to a syslog server as UDP messages. */
internal class SyslogSender(private val scope: CoroutineScope) {
    private val queue = Channel<String>(256, BufferOverflow.DROP_OLDEST)
    private var job: Job? = null

    fun start(host: String, port: Int) {
        stop()
        job = scope.launch {
            val selector = SelectorManager(Dispatchers.Default)
            try {
                val socket = aSocket(selector).udp().connect(InetSocketAddress(host, port))
                try {
                    for (line in queue) socket.send(Datagram(buildPacket { writeText("<14>APRSERJi: $line") }, socket.remoteAddress))
                } finally { socket.close() }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
            } finally { selector.close() }
        }
    }

    fun send(line: String) { if (job != null) queue.trySend(line) }
    fun stop() { job?.cancel(); job = null }
}

/** One-shot Citizen Weather Observer Program upload: log in receive-only, send the report, close. */
internal object CwopUploader {
    suspend fun upload(host: String, port: Int, callsign: String, passcode: String, packet: String, version: String) {
        val selector = SelectorManager(Dispatchers.Default)
        try {
            val socket = withTimeout(20_000) { aSocket(selector).tcp().connect(host, port) }
            try {
                val input = socket.openReadChannel()
                val output = socket.openWriteChannel(autoFlush = true)
                withTimeout(20_000) { input.readUTF8Line(512) }
                output.writeStringUtf8("user $callsign pass ${passcode.ifBlank { "-1" }} vers APRSERJi $version\r\n")
                withTimeoutOrNull(5_000) { input.readUTF8Line(512) }
                output.writeStringUtf8(packet.trimEnd('\r', '\n') + "\r\n")
                delay(1_500)
            } finally { socket.close() }
        } finally { selector.close() }
    }
}

/**
 * A small APRS-IS style server so other programs (Xastir, YAAC, PinPoint, a logging script…) can connect to this
 * station. Clients log in with "user CALL pass NNNN [filter …]"; they receive every packet this station hears
 * (or those matching their filter) and, once their passcode is verified, may send packets for this station to
 * forward. [localOnly] listens on 127.0.0.1 only.
 */
internal class IsServer(private val scope: CoroutineScope, private val onClientPacket: suspend (String, String) -> Unit) {
    private class Client(val socketChannel: Channel<String>, var callsign: String, var verified: Boolean, var filter: org.aprsfoundation.core.PacketFilter?)
    private val clients = MutableStateFlow<List<Client>>(emptyList())
    val clientCount = MutableStateFlow(0)
    val state = MutableStateFlow("STOPPED")
    val error = MutableStateFlow<String?>(null)
    private var job: Job? = null

    fun start(port: Int, localOnly: Boolean) {
        stop()
        job = scope.launch {
            val selector = SelectorManager(Dispatchers.Default)
            try {
                val server = aSocket(selector).tcp().bind(if (localOnly) "127.0.0.1" else "0.0.0.0", port)
                state.value = "LISTENING"
                error.value = null
                try {
                    while (isActive) {
                        val socket = server.accept()
                        launch { serve(socket) }
                    }
                } finally { server.close() }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (e: Exception) {
                error.value = e.message ?: "Cannot listen on port $port"
                state.value = "FAILED"
            } finally { selector.close() }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        clients.value = emptyList()
        clientCount.value = 0
        state.value = "STOPPED"
    }

    /** Offers a packet line to every logged-in client whose filter accepts it. */
    fun broadcast(line: String, match: (org.aprsfoundation.core.PacketFilter) -> Boolean) {
        for (c in clients.value) {
            if (c.callsign.isEmpty()) continue
            val f = c.filter
            if (f == null || runCatching { match(f) }.getOrDefault(true)) c.socketChannel.trySend(line)
        }
    }

    private suspend fun serve(socket: Socket) {
        val queue = Channel<String>(512, BufferOverflow.DROP_OLDEST)
        val client = Client(queue, "", false, null)
        try {
            val input = socket.openReadChannel()
            val output = socket.openWriteChannel(autoFlush = true)
            output.writeStringUtf8("# APRSERJi local server\r\n")
            synchronizedAdd(client)
            val writer = scope.launch {
                for (line in queue) output.writeStringUtf8(line.trimEnd('\r', '\n') + "\r\n")
            }
            try {
                while (true) {
                    val line = withTimeoutOrNull(600_000) { input.readUTF8Line(512) } ?: break
                    if (line.startsWith("user ", ignoreCase = true)) {
                        val parts = line.trim().split(Regex("\\s+"))
                        val call = parts.getOrNull(1)?.uppercase().orEmpty()
                        val pass = parts.getOrNull(parts.indexOfFirst { it.equals("pass", true) } + 1)
                        val verified = pass?.toIntOrNull() == AprsPasscode.of(call) && call.isNotEmpty()
                        val filterAt = parts.indexOfFirst { it.equals("filter", true) }
                        client.filter = if (filterAt > 0) runCatching {
                            org.aprsfoundation.core.PacketFilter(parts.drop(filterAt + 1).joinToString(" "))
                        }.getOrNull() else null
                        client.callsign = call
                        client.verified = verified
                        queue.trySend("# logresp $call ${if (verified) "verified" else "unverified"}, server APRSERJI")
                    } else if (line.startsWith("#")) {
                        continue
                    } else if (client.verified && line.isNotBlank()) {
                        onClientPacket(client.callsign, line.trim())
                    }
                }
            } finally { writer.cancel() }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
        } finally {
            synchronizedRemove(client)
            socket.close()
        }
    }

    private fun synchronizedAdd(c: Client) { clients.update { it + c }; clientCount.value = clients.value.size }
    private fun synchronizedRemove(c: Client) { clients.update { it - c }; clientCount.value = clients.value.size }
}

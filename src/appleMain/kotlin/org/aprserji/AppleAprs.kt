// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import org.aprsfoundation.core.AprsIsClient
import org.aprsfoundation.core.AprsIsConfig
import org.aprsfoundation.core.ChatRow
import org.aprsfoundation.core.ChatSession
import org.aprsfoundation.core.StationMarker

/** Main-thread entry points for the Apple app. ChatSession owns transport and retries. */
class AppleAprs @Throws(Exception::class) constructor(path: String, private val applicationVersion: String) {
    private val store = AppleChatStore(path)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var client: AprsIsClient? = null
    private var session: ChatSession? = null
    private val transportError = MutableStateFlow<String?>(null)

    val connectionState: String get() = client?.state?.value?.name ?: "STOPPED"
    val stations: List<StationMarker>
        get() = client?.stations?.value.orEmpty().map { StationMarker(it.callsign, it.latitude, it.longitude) }
    val revision: Long get() = store.revision.value
    val chatError: String? get() = transportError.value

    fun start(callsign: String, passcode: String, host: String, port: Int, latitude: Double, longitude: Double): Boolean {
        val config = try {
            AprsIsConfig(callsign, passcode, host, port, latitude, longitude,
                application = "APRSERJi", applicationVersion = applicationVersion)
        } catch (_: IllegalArgumentException) {
            return false
        }
        stop()
        val next = AprsIsClient()
        client = next
        session = ChatSession(callsign, next, store, scope) { transportError.value = it }
        next.start(config)
        return true
    }

    fun stop() {
        session?.close()
        session = null
        client?.stop()
        client = null
        transportError.value = null
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

package org.aprserji

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import net.osmand.shared.aprs.AprsIsClient
import net.osmand.shared.aprs.AprsIsConfig
import net.osmand.shared.aprs.AprsStation

/** Small Swift-facing API for the receive-only milestone. */
class StationFeed {
    private var client: AprsIsClient? = null
    private var messageDrain: Job? = null

    val connectionState: String get() = client?.state?.value?.name ?: "STOPPED"
    val stations: List<AprsStation> get() = client?.stations?.value.orEmpty()

    fun start(callsign: String, host: String, port: Int, latitude: Double, longitude: Double): Boolean {
        val config = try {
            AprsIsConfig(callsign = callsign, host = host, port = port, latitude = latitude,
                longitude = longitude, application = "APRSERJi")
        } catch (_: IllegalArgumentException) {
            return false
        }
        stop()
        val next = AprsIsClient()
        client = next
        // The core's incoming message channel is bounded. Keep it flowing until chat is wired up.
        messageDrain = CoroutineScope(Dispatchers.Default).launch { next.messages.collect {} }
        next.start(config)
        return true
    }

    fun stop() {
        client?.stop()
        client = null
        messageDrain?.cancel()
        messageDrain = null
    }
}

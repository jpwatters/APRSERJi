// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import org.aprsfoundation.core.AprsStationStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PacketInsightsTest {
    private fun feed(lines: List<String>, account: String = "N0ABC"): Pair<List<StationDetail>, List<IncomingAlert>> {
        val store = AprsStationStore()
        val insights = PacketInsights()
        val alerts = mutableListOf<IncomingAlert>()
        lines.forEachIndexed { index, line ->
            val now = 1_000_000L + index
            store.receive(line, now)
            insights.receive(line, account, now)?.let(alerts::add)
        }
        return insights.details(store.snapshot(1_000_000L + lines.size)) to alerts
    }

    @Test
    fun classifiesStationsWeatherAndObjects() {
        val (details, _) = feed(listOf(
            "N0CAR-9>APRS,TCPIP*,qAC,T2TEST:!4123.45N/08812.34W>Mobile",
            "N0WX>APRS,TCPIP*,qAC,T2TEST:!4124.00N/08813.00W_180/010g015t072r001p010h55b10132",
            "N0OBJ>APRS,TCPIP*,qAC,T2TEST:;HAMFEST  *111111z4125.00N/08814.00W-Club hamfest",
        ))
        val byCall = details.associateBy { it.callsign }
        assertEquals("station", byCall.getValue("N0CAR-9").kind)
        assertEquals("TCPIP*,qAC,T2TEST", byCall.getValue("N0CAR-9").path)

        val wx = byCall.getValue("N0WX")
        assertEquals("weather", wx.kind)
        assertTrue(wx.hasWeather)
        assertEquals(55, wx.humidity)
        assertNotNull(wx.temperatureC)
        assertEquals(180, wx.windDegrees)

        val obj = byCall.getValue("HAMFEST")
        assertEquals("object", obj.kind)
        assertEquals("N0OBJ", obj.owner)
    }

    @Test
    fun alertsOncePerMessageAndIgnoresAcksAndOtherRecipients() {
        val (_, alerts) = feed(listOf(
            "N0XYZ>APRS,TCPIP*::N0ABC    :Hello there{12",
            "N0XYZ>APRS,TCPIP*::N0ABC    :Hello there{12",
            "N0XYZ>APRS,TCPIP*::N0ABC    :ack7",
            "N0XYZ>APRS,TCPIP*::N0OTHER  :Not for you{13",
            "N0XYZ>APRS,TCPIP*::n0abc    :Second{14",
        ))
        assertEquals(listOf("Hello there", "Second"), alerts.map { it.text })
        assertEquals("N0XYZ", alerts.first().sender)
    }

    @Test
    fun noAlertsWithoutAccount() {
        val insights = PacketInsights()
        assertNull(insights.receive("N0XYZ>APRS,TCPIP*::N0ABC    :Hi{1", null, 1))
    }
}

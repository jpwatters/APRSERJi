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

    @Test
    fun decodesTelemetryWithDefinitions() {
        val insights = PacketInsights()
        insights.receive("N0TLM>APRS,TCPIP*::N0TLM    :PARM.Volts,Temp,,,,Door", null, 1)
        insights.receive("N0TLM>APRS,TCPIP*::N0TLM    :UNIT.V,degF", null, 2)
        insights.receive("N0TLM>APRS,TCPIP*::N0TLM    :EQNS.0,0.1,0,0,1,0,0,1,0,0,1,0,0,1,0", null, 3)
        insights.receive("N0TLM>APRS,TCPIP*:T#005,138,072,000,000,000,10000000", null, 4)
        val report = insights.telemetry().getValue("N0TLM")
        assertEquals("005", report.sequence)
        assertEquals("Volts", report.channels[0].name)
        assertEquals("V", report.channels[0].unit)
        assertEquals(13.8, report.channels[0].value!!, 0.001)
        assertEquals("Door", report.bits[0].name)
        assertTrue(report.bits[0].set)
    }

    @Test
    fun keepsBulletinsAndTracks() {
        val insights = PacketInsights()
        insights.receive("N0BLN>APRS,TCPIP*::BLN1     :Net tonight 7 PM on 146.94", null, 1)
        assertEquals("Net tonight 7 PM on 146.94", insights.bulletins().single().text)

        insights.receive("N0CAR>APRS,TCPIP*:!4123.45N/08812.34W>", null, 10)
        insights.receive("N0CAR>APRS,TCPIP*:!4123.45N/08812.34W>", null, 20)
        assertTrue(insights.tracks().isEmpty())
        insights.receive("N0CAR>APRS,TCPIP*:!4124.45N/08812.34W>", null, 30)
        assertEquals(2, insights.tracks().getValue("N0CAR").size)
    }

    @Test
    fun reportsCoverageAndRadio() {
        val store = AprsStationStore()
        val insights = PacketInsights()
        val line = "N0DIG>APRS,WIDE2-1:!4123.45N/08812.34W#PHG5360 Digi"
        store.receive(line, 1)
        insights.receive(line, null, 1, radio = true)
        val detail = insights.details(store.snapshot(2), 2).single()
        assertNotNull(detail.coverageMeters)
        assertTrue(detail.heardOnRadio)
    }
}

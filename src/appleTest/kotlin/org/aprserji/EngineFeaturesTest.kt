// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.aprsfoundation.core.AprsFix

class EngineFeaturesTest {
    @Test
    fun passcodeMatchesTheKnownAlgorithm() {
        assertEquals(13023, AprsPasscode.of("N0CALL"))
        assertEquals(AprsPasscode.of("KC9KKO"), AprsPasscode.of("kc9kko-9"))
        assertEquals(19109, AprsPasscode.of("KC9KKO"))
    }

    @Test
    fun identifiesDevicesByTocallAndMicE() {
        assertTrue(DeviceIds.identify("APDW17", "!4123.45N/08812.34W-")!!.contains("Dire"))
        assertNotNull(DeviceIds.identify("APDR16", "=4123.45N/08812.34W>"))
        assertNull(DeviceIds.identify("ZZZZZZ", "!4123.45N/08812.34W-"))
        assertTrue(DeviceIds.count > 300)
    }

    @Test
    fun formatsWeatherFieldsInAprsUnits() {
        val w = LocalWeather("test", 0, 20.0, 55, 1013.2, 180, 4.4704, 8.9408, 2.54, 5.08, 1.27, null)
        assertEquals("180/010g020t068r010p020P005h55b10132", WeatherInput.aprsFields(w))
        val calm = LocalWeather("test", 0, -5.0, 100, null, null, null, null, null, null, null, null)
        assertEquals(".../...g...t023h00", WeatherInput.aprsFields(calm))
    }

    @Test
    fun readsTempestBroadcastsAndAccumulatesRain() {
        val input = WeatherInput()
        val obs = """{"serial_number":"ST-00000512","type":"obs_st","hub_sn":"HB-00013030","obs":[[1588948614,0.18,0.22,0.27,144,6,1017.57,22.37,50.26,328,0.03,3,0.5,0,0,0,2.410,1]],"firmware_revision":129}"""
        assertTrue(input.tempestUdp(obs, 1_000_000_000_000, 0))
        assertTrue(input.tempestUdp(obs, 1_000_000_060_000, 0))
        val w = input.current(1_000_000_060_000)!!
        assertEquals(22.37, w.temperatureC!!, 0.001)
        assertEquals(50, w.humidity)
        assertEquals(144, w.windDegrees)
        assertEquals(1.0, w.rainHourMm!!, 0.001)
        val rapid = """{"serial_number":"SK-00008453","type":"rapid_wind","hub_sn":"HB-00000001","ob":[1493322445,2.3,128]}"""
        input.tempestUdp(rapid, 1_000_000_061_000, 0)
        assertEquals(128, input.current(1_000_000_062_000)!!.windDegrees)
    }

    @Test
    fun readsWxnowText() {
        val input = WeatherInput()
        assertTrue(input.text("Nov 24 2026 10:00\n272/010g006t069r010p030P020h61b10150", 0))
        val w = input.latest!!
        assertEquals(272, w.windDegrees)
        assertEquals(61, w.humidity)
        assertEquals(1015.0, w.pressureHpa!!, 0.01)
        assertEquals(20.555, w.temperatureC!!, 0.01)
    }

    @Test
    fun propagatesTheIssToALowEarthOrbit() {
        val tle = """
            ISS (ZARYA)
            1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927
            2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537
        """.trimIndent()
        val sats = Satellites()
        assertEquals(1, sats.load(tle))
        val info = sats.list.single()
        assertTrue(info.nearEarth)
        assertTrue(abs(info.periodMinutes - 91.6) < 1)
        val epoch = info.epochMillis
        val p = sats.position("ISS (ZARYA)", epoch + 3_600_000, 41.0, -88.0, 200.0)!!
        assertTrue(p.altitudeKm in 300.0..450.0, "altitude ${p.altitudeKm}")
        assertTrue(abs(p.latitude) <= 52.0)
        assertTrue(p.footprintKm in 2000.0..2500.0)
        val passes = sats.passes("ISS (ZARYA)", epoch, 41.0, -88.0, 200.0, 24, 0.0, 10)
        assertTrue(passes.isNotEmpty())
        assertTrue(passes.all { it.losMillis > it.aosMillis && it.maxElevation > 0 })
    }

    @Test
    fun buildsObjectsWithShapesAndTelemetry() {
        val e = OwnEntity("1", "NETCTL", false, 41.5, -88.1, "/", "o", "Net control", false, true, true, 600, true, false,
            "", "41.5,-88.1;41.51,-88.12;41.49,-88.13", true, "j")
        val info = EntityPackets.entity("KC9KKO", e, AprsFix(41.5, -88.1, 0), 0, true)
        assertTrue(info.startsWith(";NETCTL   *"))
        assertTrue(info.contains(" }j0"))
        assertEquals("T#007,1,2,3,255,0,10000000", EntityPackets.telemetry(7, listOf(1, 2, 3, 300, -4), "10000000"))
        val defs = EntityPackets.definitions("KC9KKO", TelemetrySettings(true, 10, List(5) { "rf" },
            listOf("RF", "IS", "Digi", "Gated", "Msgs"), listOf("pkt", "pkt", "pkt", "pkt", "msg"), emptyList(),
            listOf("APRS-IS", "Radio"), "APRSERJi", true, false))
        assertTrue(defs.first().startsWith(":KC9KKO   :PARM.RF,IS,Digi,Gated,Msgs,APRS-IS,Radio"))
    }

    @Test
    fun answersQueriesAndAwayMessagesWithoutLooping() {
        val r = Responder()
        val facts = Responder.Facts("1.0", listOf("N0ABC"), listOf("NETCTL"), "<IGATE,MSG_CNT=0,LOC_CNT=1", true, false) { "$it not heard" }
        assertTrue(r.directed("N0XYZ", "?APRSP", "WIDE1-1", 0, facts).single() is Responder.Answer.Position)
        val ver = r.directed("N0XYZ", "?VER", "", 0, facts).single() as Responder.Answer.Message
        assertEquals("APRSERJi 1.0", ver.text)
        r.settings = r.settings.copy(autoReply = true)
        assertEquals(1, r.directed("N0XYZ", "Hello", "", 0, facts).size)
        assertEquals(0, r.directed("N0XYZ", "Hello again", "", 60_000, facts).size)
        assertEquals(0, r.directed("N0XYZ", "AA: away too", "", 4_000_000, facts).size)
        assertEquals(0, r.directed("ANSRVR", "Joined group", "", 0, facts).size)
        assertEquals(1, r.broadcast("?APRS?", 0, facts).size)
        assertEquals(0, r.broadcast("?APRS?", 60_000, facts).size)
    }
}

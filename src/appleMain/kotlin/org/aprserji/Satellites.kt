// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import kotlin.math.*
import kotlinx.datetime.LocalDate

/** A satellite from a TLE set. [nearEarth] is false for deep-space orbits (period 225 min or more), which are not propagated. */
data class SatelliteInfo(val name: String, val catalog: String, val epochMillis: Long, val nearEarth: Boolean, val periodMinutes: Double)

/** Where a satellite is now and how it looks from the observer. Angles in degrees. */
data class SatellitePosition(
    val name: String, val latitude: Double, val longitude: Double, val altitudeKm: Double,
    /** Radius of the area on the ground that can see the satellite. */
    val footprintKm: Double,
    val azimuth: Double, val elevation: Double, val rangeKm: Double,
)

/** One pass over the observer: acquisition, highest point and loss of signal. */
data class SatellitePass(
    val name: String, val aosMillis: Long, val losMillis: Long, val maxElevation: Double, val maxMillis: Long,
    val aosAzimuth: Double, val losAzimuth: Double,
)

/**
 * Two-line element sets propagated with SGP4 (near-earth model, WGS-72 constants, Spacetrack Report #3).
 * Accurate to a few kilometres for fresh elements — plenty for maps, footprints and pass times.
 */
class Satellites {
    private class Elements(val info: SatelliteInfo, val sgp4: Sgp4)
    private val sats = LinkedHashMap<String, Elements>()

    val list: List<SatelliteInfo> get() = sats.values.map { it.info }

    /** Replaces the set with the TLEs in [text] (name line + two element lines each). Returns how many loaded. */
    fun load(text: String): Int {
        val lines = text.lines().map { it.trimEnd() }.filter { it.isNotBlank() }
        val next = LinkedHashMap<String, Elements>()
        var i = 0
        while (i < lines.size) {
            if (i + 1 < lines.size && lines[i].startsWith("1 ") && lines[i + 1].startsWith("2 ")) {
                parse("SAT " + lines[i].substring(2, 7).trim(), lines[i], lines[i + 1])?.let { next[it.info.name] = it }
                i += 2
            } else if (i + 2 < lines.size && lines[i + 1].startsWith("1 ") && lines[i + 2].startsWith("2 ")) {
                parse(lines[i].removePrefix("0 ").trim(), lines[i + 1], lines[i + 2])?.let { next[it.info.name] = it }
                i += 3
            } else i++
        }
        if (next.isNotEmpty()) { sats.clear(); sats.putAll(next) }
        return next.size
    }

    fun position(name: String, nowMillis: Long, latitude: Double, longitude: Double, altitudeMeters: Double): SatellitePosition? {
        val e = sats[name] ?: return null
        if (!e.info.nearEarth) return null
        val eci = e.sgp4.positionKm((nowMillis - e.info.epochMillis) / 60_000.0) ?: return null
        return look(name, eci, nowMillis, latitude, longitude, altitudeMeters)
    }

    /** Passes in the next [hours] hours above [minimumElevation] degrees, at most [maximum]. */
    fun passes(name: String, nowMillis: Long, latitude: Double, longitude: Double, altitudeMeters: Double,
               hours: Int, minimumElevation: Double, maximum: Int): List<SatellitePass> {
        val e = sats[name] ?: return emptyList()
        if (!e.info.nearEarth) return emptyList()
        fun elevation(t: Long) = e.sgp4.positionKm((t - e.info.epochMillis) / 60_000.0)
            ?.let { look(name, it, t, latitude, longitude, altitudeMeters) }
        val result = mutableListOf<SatellitePass>()
        val step = 30_000L
        var t = nowMillis
        val end = nowMillis + hours.coerceIn(1, 72) * 3_600_000L
        var previous = elevation(t)?.elevation ?: return emptyList()
        var aos: Long? = if (previous > 0) t else null
        var best = previous to t
        while (t < end && result.size < maximum) {
            t += step
            val now = elevation(t)?.elevation ?: break
            if (aos == null && now > 0 && previous <= 0) {
                aos = refine(t - step, t) { elevation(it)?.elevation ?: -90.0 }
                best = now to t
            }
            if (aos != null && now > best.first) best = now to t
            if (aos != null && now <= 0 && previous > 0) {
                val los = refine(t - step, t) { -(elevation(it)?.elevation ?: -90.0) }
                if (best.first >= minimumElevation) {
                    result += SatellitePass(name, aos, los, best.first, best.second,
                        elevation(aos)?.azimuth ?: 0.0, elevation(los)?.azimuth ?: 0.0)
                }
                aos = null
                best = -90.0 to t
            }
            previous = now
        }
        return result
    }

    /** Bisection for the moment [f] crosses zero going up, to the second. */
    private fun refine(low: Long, high: Long, f: (Long) -> Double): Long {
        var a = low
        var b = high
        while (b - a > 1000) {
            val mid = (a + b) / 2
            if (f(mid) > 0) b = mid else a = mid
        }
        return b
    }

    private fun look(name: String, eci: DoubleArray, timeMillis: Long, latitude: Double, longitude: Double,
                     altitudeMeters: Double): SatellitePosition {
        val gmst = gmst(timeMillis)
        val r = sqrt(eci[0] * eci[0] + eci[1] * eci[1])
        var lon = atan2(eci[1], eci[0]) - gmst
        lon = ((lon + 3 * PI) % (2 * PI)) - PI
        // Geodetic latitude, iterated on the WGS-84 ellipsoid.
        val a = 6378.137
        val f = 1 / 298.257223563
        val e2 = f * (2 - f)
        var lat = atan2(eci[2], r)
        var c = 1.0
        repeat(10) {
            c = 1 / sqrt(1 - e2 * sin(lat).pow(2))
            lat = atan2(eci[2] + a * c * e2 * sin(lat), r)
        }
        val height = r / cos(lat) - a * c
        // Observer position in the same inertial frame.
        val olat = latitude * PI / 180
        val olon = longitude * PI / 180 + gmst
        val oc = 1 / sqrt(1 - e2 * sin(olat).pow(2))
        val oh = altitudeMeters / 1000
        val ox = (a * oc + oh) * cos(olat) * cos(olon)
        val oy = (a * oc + oh) * cos(olat) * sin(olon)
        val oz = (a * oc * (1 - e2) + oh) * sin(olat)
        val rx = eci[0] - ox
        val ry = eci[1] - oy
        val rz = eci[2] - oz
        val s = sin(olat) * cos(olon) * rx + sin(olat) * sin(olon) * ry - cos(olat) * rz
        val e = -sin(olon) * rx + cos(olon) * ry
        val z = cos(olat) * cos(olon) * rx + cos(olat) * sin(olon) * ry + sin(olat) * rz
        val range = sqrt(rx * rx + ry * ry + rz * rz)
        val elevation = asin(z / range) * 180 / PI
        val azimuth = (atan2(e, -s) * 180 / PI + 360) % 360
        val footprint = 6371.0 * acos((6371.0 / (6371.0 + height.coerceAtLeast(0.0))).coerceIn(-1.0, 1.0))
        return SatellitePosition(name, lat * 180 / PI, lon * 180 / PI, height, footprint, azimuth, elevation, range)
    }

    companion object {
        /** Greenwich mean sidereal time in radians. */
        fun gmst(timeMillis: Long): Double {
            val jd = timeMillis / 86_400_000.0 + 2440587.5
            val degrees = 280.46061837 + 360.98564736629 * (jd - 2451545.0)
            return ((degrees % 360 + 360) % 360) * PI / 180
        }

        private fun checksum(line: String): Boolean {
            if (line.length < 69) return false
            val sum = line.take(68).sumOf { c -> if (c.isDigit()) c - '0' else if (c == '-') 1 else 0 }
            return sum % 10 == line[68] - '0'
        }

        /** "12345-3" style TLE exponent fields (implied decimal point). */
        private fun exponent(text: String): Double {
            val t = text.trim()
            if (t.isEmpty() || t.all { it == '0' || it == '-' || it == '+' }) return 0.0
            val sign = if (t.startsWith('-')) -1 else 1
            val body = t.trimStart('-', '+')
            val split = body.indexOfAny(charArrayOf('-', '+'))
            val mantissa = ("0." + if (split > 0) body.substring(0, split) else body).toDouble()
            val power = if (split > 0) body.substring(split).toInt() else 0
            return sign * mantissa * 10.0.pow(power)
        }

        private fun parse(name: String, l1: String, l2: String): Elements? = runCatching {
            require(checksum(l1) && checksum(l2))
            val yy = l1.substring(18, 20).trim().toInt()
            val day = l1.substring(20, 32).trim().toDouble()
            val year = if (yy < 57) 2000 + yy else 1900 + yy
            val epoch = LocalDate(year, 1, 1).toEpochDays().toLong() * 86_400_000L + ((day - 1) * 86_400_000.0).toLong()
            val bstar = exponent(l1.substring(53, 61))
            val incl = l2.substring(8, 16).trim().toDouble() * PI / 180
            val raan = l2.substring(17, 25).trim().toDouble() * PI / 180
            val ecc = ("0." + l2.substring(26, 33).trim()).toDouble()
            val argp = l2.substring(34, 42).trim().toDouble() * PI / 180
            val mean = l2.substring(43, 51).trim().toDouble() * PI / 180
            val revs = l2.substring(52, 63).trim().toDouble()
            val sgp4 = Sgp4(revs * 2 * PI / 1440.0, incl, raan, ecc, argp, mean, bstar)
            val period = 2 * PI / sgp4.meanMotion
            Elements(SatelliteInfo(name.take(24), l1.substring(2, 7).trim(), epoch, period < 225, period), sgp4)
        }.getOrNull()
    }
}

/** SGP4 near-earth propagator. Positions are inertial (TEME) kilometres. */
internal class Sgp4(xno: Double, private val xincl: Double, private val xnodeo: Double, private val eo: Double,
                    private val omegao: Double, private val xmo: Double, private val bstar: Double) {
    private val xke = 0.0743669161
    private val ck2 = 5.413080e-4
    private val ck4 = 0.62098875e-6
    private val xj3 = -0.253881e-5
    private val xkmper = 6378.135
    private val ae = 1.0
    private val tothrd = 2.0 / 3.0

    val meanMotion: Double
    private val aodp: Double
    private val cosio = cos(xincl)
    private val sinio = sin(xincl)
    private val x3thm1: Double
    private val x1mth2: Double
    private val x7thm1: Double
    private val isimp: Boolean
    private val eta: Double
    private val c1: Double
    private val c4: Double
    private val c5: Double
    private val d2: Double
    private val d3: Double
    private val d4: Double
    private val t2cof: Double
    private val t3cof: Double
    private val t4cof: Double
    private val t5cof: Double
    private val xmdot: Double
    private val omgdot: Double
    private val xnodot: Double
    private val omgcof: Double
    private val xmcof: Double
    private val xnodcf: Double
    private val xlcof: Double
    private val aycof: Double
    private val delmo: Double
    private val sinmo: Double

    init {
        val a1 = (xke / xno).pow(tothrd)
        val theta2 = cosio * cosio
        x3thm1 = 3 * theta2 - 1
        val eosq = eo * eo
        val betao2 = 1 - eosq
        val betao = sqrt(betao2)
        val del1 = 1.5 * ck2 * x3thm1 / (a1 * a1 * betao * betao2)
        val ao = a1 * (1 - del1 * (0.5 * tothrd + del1 * (1 + 134.0 / 81.0 * del1)))
        val delo = 1.5 * ck2 * x3thm1 / (ao * ao * betao * betao2)
        meanMotion = xno / (1 + delo)
        aodp = ao / (1 - delo)
        isimp = aodp * (1 - eo) / ae < 220 / xkmper + ae
        var s4 = 1.01222928
        var qoms24 = 1.88027916e-9
        val perige = (aodp * (1 - eo) - ae) * xkmper
        if (perige < 156) {
            s4 = if (perige <= 98) 20.0 else perige - 78
            qoms24 = ((120 - s4) * ae / xkmper).pow(4)
            s4 = s4 / xkmper + ae
        }
        val pinvsq = 1 / (aodp * aodp * betao2 * betao2)
        val tsi = 1 / (aodp - s4)
        eta = aodp * eo * tsi
        val etasq = eta * eta
        val eeta = eo * eta
        val psisq = abs(1 - etasq)
        val coef = qoms24 * tsi.pow(4)
        val coef1 = coef / psisq.pow(3.5)
        val c2 = coef1 * meanMotion * (aodp * (1 + 1.5 * etasq + eeta * (4 + etasq)) +
            0.75 * ck2 * tsi / psisq * x3thm1 * (8 + 3 * etasq * (8 + etasq)))
        c1 = bstar * c2
        val a3ovk2 = -xj3 / ck2 * ae.pow(3)
        val c3 = if (eo > 1e-4) coef * tsi * a3ovk2 * meanMotion * ae * sinio / eo else 0.0
        x1mth2 = 1 - theta2
        c4 = 2 * meanMotion * coef1 * aodp * betao2 * (eta * (2 + 0.5 * etasq) + eo * (0.5 + 2 * etasq) -
            2 * ck2 * tsi / (aodp * psisq) * (-3 * x3thm1 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta)) +
                0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * cos(2 * omegao)))
        c5 = 2 * coef1 * aodp * betao2 * (1 + 2.75 * (etasq + eeta) + eeta * etasq)
        val theta4 = theta2 * theta2
        val temp1 = 3 * ck2 * pinvsq * meanMotion
        val temp2 = temp1 * ck2 * pinvsq
        val temp3 = 1.25 * ck4 * pinvsq * pinvsq * meanMotion
        xmdot = meanMotion + 0.5 * temp1 * betao * x3thm1 + 0.0625 * temp2 * betao * (13 - 78 * theta2 + 137 * theta4)
        val x1m5th = 1 - 5 * theta2
        omgdot = -0.5 * temp1 * x1m5th + 0.0625 * temp2 * (7 - 114 * theta2 + 395 * theta4) +
            temp3 * (3 - 36 * theta2 + 49 * theta4)
        val xhdot1 = -temp1 * cosio
        xnodot = xhdot1 + (0.5 * temp2 * (4 - 19 * theta2) + 2 * temp3 * (3 - 7 * theta2)) * cosio
        omgcof = bstar * c3 * cos(omegao)
        xmcof = if (eo > 1e-4) -tothrd * coef * bstar * ae / eeta else 0.0
        xnodcf = 3.5 * betao2 * xhdot1 * c1
        t2cof = 1.5 * c1
        xlcof = 0.125 * a3ovk2 * sinio * (3 + 5 * cosio) / (1 + cosio)
        aycof = 0.25 * a3ovk2 * sinio
        delmo = (1 + eta * cos(xmo)).pow(3)
        sinmo = sin(xmo)
        x7thm1 = 7 * theta2 - 1
        if (!isimp) {
            val c1sq = c1 * c1
            d2 = 4 * aodp * tsi * c1sq
            val temp = d2 * tsi * c1 / 3
            d3 = (17 * aodp + s4) * temp
            d4 = 0.5 * temp * aodp * tsi * (221 * aodp + 31 * s4) * c1
            t3cof = d2 + 2 * c1sq
            t4cof = 0.25 * (3 * d3 + c1 * (12 * d2 + 10 * c1sq))
            t5cof = 0.2 * (3 * d4 + 12 * c1 * d3 + 6 * d2 * d2 + 15 * c1sq * (2 * d2 + c1sq))
        } else {
            d2 = 0.0; d3 = 0.0; d4 = 0.0; t3cof = 0.0; t4cof = 0.0; t5cof = 0.0
        }
    }

    /** Position [x, y, z] in km, [tsince] minutes after epoch; null if the orbit has decayed. */
    fun positionKm(tsince: Double): DoubleArray? {
        val xmdf = xmo + xmdot * tsince
        val omgadf = omegao + omgdot * tsince
        val xnoddf = xnodeo + xnodot * tsince
        var omega = omgadf
        var xmp = xmdf
        val tsq = tsince * tsince
        val xnode = xnoddf + xnodcf * tsq
        var tempa = 1 - c1 * tsince
        var tempe = bstar * c4 * tsince
        var templ = t2cof * tsq
        if (!isimp) {
            val delomg = omgcof * tsince
            val delm = xmcof * ((1 + eta * cos(xmdf)).pow(3) - delmo)
            val temp = delomg + delm
            xmp = xmdf + temp
            omega = omgadf - temp
            val tcube = tsq * tsince
            val tfour = tsince * tcube
            tempa = tempa - d2 * tsq - d3 * tcube - d4 * tfour
            tempe += bstar * c5 * (sin(xmp) - sinmo)
            templ += t3cof * tcube + tfour * (t4cof + tsince * t5cof)
        }
        val a = aodp * tempa * tempa
        val e = eo - tempe
        if (a < 1 || e !in 0.0..0.999) return null
        val xl = xmp + omega + xnode + meanMotion * templ
        val beta = sqrt(1 - e * e)
        val xn = xke / a.pow(1.5)
        val axn = e * cos(omega)
        var temp = 1 / (a * beta * beta)
        val xll = temp * xlcof * axn
        val aynl = temp * aycof
        val xlt = xl + xll
        val ayn = e * sin(omega) + aynl
        val capu = ((xlt - xnode) % (2 * PI) + 2 * PI) % (2 * PI)
        var temp2 = capu
        var sinepw = 0.0
        var cosepw = 0.0
        var temp3 = 0.0
        var temp4 = 0.0
        var temp5 = 0.0
        var temp6 = 0.0
        for (i in 0 until 10) {
            sinepw = sin(temp2)
            cosepw = cos(temp2)
            temp3 = axn * sinepw
            temp4 = ayn * cosepw
            temp5 = axn * cosepw
            temp6 = ayn * sinepw
            val epw = (capu - temp4 + temp3 - temp2) / (1 - temp5 - temp6) + temp2
            if (abs(epw - temp2) <= 1e-6) { temp2 = epw; break }
            temp2 = epw
        }
        sinepw = sin(temp2)
        cosepw = cos(temp2)
        val ecose = axn * cosepw + ayn * sinepw
        val esine = axn * sinepw - ayn * cosepw
        val elsq = axn * axn + ayn * ayn
        temp = 1 - elsq
        val pl = a * temp
        if (pl <= 0) return null
        val r = a * (1 - ecose)
        var temp1 = 1 / r
        temp2 = a * temp1
        val betal = sqrt(temp)
        temp3 = 1 / (1 + betal)
        val cosu = temp2 * (cosepw - axn + ayn * esine * temp3)
        val sinu = temp2 * (sinepw - ayn - axn * esine * temp3)
        val u = atan2(sinu, cosu)
        val sin2u = 2 * sinu * cosu
        val cos2u = 2 * cosu * cosu - 1
        temp = 1 / pl
        temp1 = ck2 * temp
        temp2 = temp1 * temp
        val rk = r * (1 - 1.5 * temp2 * betal * x3thm1) + 0.5 * temp1 * x1mth2 * cos2u
        val uk = u - 0.25 * temp2 * x7thm1 * sin2u
        val xnodek = xnode + 1.5 * temp2 * cosio * sin2u
        val xinck = xincl + 1.5 * temp2 * cosio * sinio * cos2u
        val sinuk = sin(uk)
        val cosuk = cos(uk)
        val sinik = sin(xinck)
        val cosik = cos(xinck)
        val sinnok = sin(xnodek)
        val cosnok = cos(xnodek)
        val xmx = -sinnok * cosik
        val xmy = cosnok * cosik
        val ux = xmx * sinuk + cosnok * cosuk
        val uy = xmy * sinuk + sinnok * cosuk
        val uz = sinik * sinuk
        return doubleArrayOf(rk * ux * xkmper, rk * uy * xkmper, rk * uz * xkmper)
    }
}

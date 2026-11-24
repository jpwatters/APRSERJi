// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

/** Automatic answers: standard APRS queries, an away message, a QRU object server and an information kiosk. */
data class ResponderSettings(
    /** Answer ?APRS? / ?IGATE? / ?WX? broadcasts and directed ?APRSP, ?APRSS, ?APRST, ?PING?, ?VER, ?APRSD, ?APRSH, ?APRSM, ?APRSO, ?IGATE. */
    val queries: Boolean,
    /** Reply "AA:" + [autoReplyText] to messages while you are away, once per sender per [autoReplyMinutes]. */
    val autoReply: Boolean,
    val autoReplyText: String,
    val autoReplyMinutes: Int,
    /** Answer QRU queries ("GROUP radius" sent to QRU) with nearby objects in that group. */
    val qru: Boolean,
    val qruDefaultKm: Int,
    val qruMaximum: Int,
    /** Reply [kioskText] to messages saying INFO, HELP or ?. */
    val kiosk: Boolean,
    val kioskText: String,
)

/** Decides what to say back; the engine sends it. Not thread-safe; used on the engine's insight thread. */
internal class Responder {
    var settings = ResponderSettings(true, false, "Away from the radio; I'll reply later.", 30, false, 50, 5, false, "")
    private val lastAutoReply = LinkedHashMap<String, Long>()
    private val lastBroadcastAnswer = LinkedHashMap<String, Long>()

    /** Services and bots never get an away reply, so two automatic stations cannot ping-pong. */
    private val services = setOf("ANSRVR", "EMAIL", "EMAIL-2", "WLNK-1", "QRU", "WXBOT", "SMSGTE", "REPEAT", "WHO-IS", "MPAD", "APRSPH", "NWS")

    sealed class Answer {
        class Message(val text: String) : Answer()
        object Position : Answer()
        object Status : Answer()
        object Weather : Answer()
        /** Re-send our outstanding messages to the asker. */
        object Requeue : Answer()
    }

    /** A directed query or message to us. [facts] supplies what the answers report. */
    fun directed(sender: String, text: String, path: String, nowMillis: Long, facts: Facts): List<Answer> {
        val t = text.trim()
        val upper = t.uppercase()
        val s = settings
        if (s.queries && upper.startsWith("?")) {
            val arg = upper.substringAfter(' ', "").trim()
            return when {
                upper.startsWith("?APRSP") -> listOf(Answer.Position)
                upper.startsWith("?APRSS") -> listOf(Answer.Status)
                upper.startsWith("?APRST") || upper.startsWith("?PING") -> listOf(Answer.Message("$sender>$path".take(67)))
                upper.startsWith("?VER") -> listOf(Answer.Message("APRSERJi ${facts.version}"))
                upper.startsWith("?APRSD") -> listOf(Answer.Message(("Directs= " + facts.directs.take(12).joinToString(" ")).take(67)))
                upper.startsWith("?APRSH") -> listOf(Answer.Message(facts.heard(arg).take(67)))
                upper.startsWith("?APRSM") -> listOf(Answer.Requeue)
                upper.startsWith("?APRSO") -> listOf(Answer.Message(("Objects= " + facts.objects.joinToString(" ")).take(67)))
                upper.startsWith("?IGATE") -> listOf(Answer.Message(facts.igate.take(67)))
                upper.startsWith("?WX") -> listOf(Answer.Weather)
                else -> emptyList()
            }
        }
        if (s.kiosk && s.kioskText.isNotBlank() && upper in setOf("INFO", "HELP", "?")) {
            return s.kioskText.trim().chunked(67).take(3).map { Answer.Message(it) }
        }
        if (s.autoReply && s.autoReplyText.isNotBlank() && sender.uppercase() !in services && !upper.startsWith("AA:") &&
            !upper.startsWith("ACK") && !upper.startsWith("REJ") && !t.startsWith(")")) {
            val last = lastAutoReply[sender]
            if (last == null || nowMillis - last >= s.autoReplyMinutes.coerceAtLeast(1) * 60_000L) {
                lastAutoReply[sender] = nowMillis
                while (lastAutoReply.size > 500) lastAutoReply.remove(lastAutoReply.keys.first())
                return listOf(Answer.Message(("AA:" + s.autoReplyText.trim()).take(67)))
            }
        }
        return emptyList()
    }

    /** A broadcast query (?APRS?, ?IGATE?, ?WX?) — answered at most once every five minutes each. */
    fun broadcast(payload: String, nowMillis: Long, facts: Facts): List<Answer> {
        if (!settings.queries) return emptyList()
        val q = payload.uppercase()
        val kind = when {
            q.startsWith("?APRS?") -> "APRS"
            q.startsWith("?IGATE?") -> if (facts.isIgate) "IGATE" else return emptyList()
            q.startsWith("?WX?") -> if (facts.hasWeather) "WX" else return emptyList()
            else -> return emptyList()
        }
        val last = lastBroadcastAnswer[kind]
        if (last != null && nowMillis - last < 300_000) return emptyList()
        lastBroadcastAnswer[kind] = nowMillis
        return when (kind) {
            "APRS" -> listOf(Answer.Position)
            "IGATE" -> listOf(Answer.Status)
            else -> listOf(Answer.Weather)
        }
    }

    /** What the answers need to know about this station. */
    class Facts(
        val version: String,
        val directs: List<String>,
        val objects: List<String>,
        val igate: String,
        val isIgate: Boolean,
        val hasWeather: Boolean,
        val heard: (String) -> String,
    )
}

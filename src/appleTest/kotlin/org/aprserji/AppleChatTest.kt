// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.aprsfoundation.core.AprsMessage
import org.aprsfoundation.core.AprsMessageTransport
import org.aprsfoundation.core.ChatSession
import platform.Foundation.NSFileManager
import platform.Foundation.NSTemporaryDirectory
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AppleChatTest {
    @Test
    fun outboxSurvivesReopenAndSharedSessionHandlesBothDirections() = runBlocking {
        val path = NSTemporaryDirectory() + "aprserji-chat-${Random.nextLong()}.sqlite"
        val account = "N0ABC-1"
        val peer = "N0XYZ-2"
        var now = 1_000_000L
        try {
            val initial = AppleChatStore(path) { now }
            try {
                initial.enqueue(account, peer, "Remember this")
                val pending = initial.pending(account).single()
                assertTrue(initial.claim(pending.row))
                initial.transmitted(pending.row, false)
            } finally {
                initial.shutdown()
            }

            val reopened = AppleChatStore(path) { now }
            try {
                assertEquals("QUEUED", reopened.rows(account, peer).single().status)
                assertTrue(reopened.pending(account).isEmpty())
                now += 30_001
                val radio = TestRadio()
                val chat = ChatSession(account, radio, reopened, this)
                try {
                    withTimeout(8_000) {
                        val sent = radio.outgoing.await()
                        assertEquals("Remember this", sent.text)
                        assertEquals(peer, sent.recipient)
                        radio.input.send(AprsMessage(peer, account, "", acknowledgement = sent.id))
                        radio.input.send(AprsMessage(peer, account, "Reply", id = "42"))
                        assertEquals("42", radio.acknowledged.await())
                        while (reopened.rows(account, peer).none { it.status == "ACKNOWLEDGED" }) delay(20)
                        val rows = reopened.rows(account, peer)
                        assertTrue(rows.any { it.body == "Reply" && it.status == "RECEIVED" })
                        assertEquals(2, rows.single { it.outgoing }.attempts)
                        assertTrue(reopened.rows("N0ABC-2", peer).isEmpty())
                    }
                } finally {
                    chat.close()
                }
            } finally {
                reopened.shutdown()
            }
        } finally {
            NSFileManager.defaultManager.removeItemAtPath(path, error = null)
        }
        Unit
    }

    private class TestRadio : AprsMessageTransport {
        val input = Channel<AprsMessage>(4)
        val outgoing = CompletableDeferred<AprsMessage>()
        val acknowledged = CompletableDeferred<String>()
        override val messages = input.receiveAsFlow()

        override fun canSend() = true

        override suspend fun sendMessage(account: String, recipient: String, text: String, id: String) {
            outgoing.complete(AprsMessage(account, recipient, text, id))
        }

        override suspend fun acknowledge(account: String, recipient: String, id: String) {
            acknowledged.complete(id)
        }
    }
}

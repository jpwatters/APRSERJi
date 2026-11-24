// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.Foundation.create
import platform.posix.memcpy

/** NSData bridges so Swift can pass serial and Bluetooth bytes without KotlinByteArray. */
@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
object AppleBytes {
    fun toData(bytes: ByteArray): NSData = bytes.usePinned { pinned ->
        NSData.create(bytes = if (bytes.isEmpty()) null else pinned.addressOf(0), length = bytes.size.toULong())
    }

    fun fromData(data: NSData): ByteArray {
        val size = data.length.toInt()
        val bytes = ByteArray(size)
        if (size > 0) bytes.usePinned { pinned -> memcpy(pinned.addressOf(0), data.bytes, data.length) }
        return bytes
    }
}

/** Serial and Bluetooth port helpers taking NSData. */
suspend fun AppleAprs.externalReceivedData(id: String, data: NSData) = externalReceived(id, AppleBytes.fromData(data))
fun AppleAprs.externalTakeOutgoingData(id: String): NSData? = externalTakeOutgoing(id)?.let(AppleBytes::toData)
fun AppleAprs.externalOpeningData(id: String): List<NSData> = externalOpening(id).map(AppleBytes::toData)

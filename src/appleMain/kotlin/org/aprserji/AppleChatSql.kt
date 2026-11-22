// SPDX-License-Identifier: AGPL-3.0-only
package org.aprserji

import cnames.structs.sqlite3
import cnames.structs.sqlite3_stmt
import kotlinx.cinterop.*
import kotlinx.datetime.Clock
import org.aprserji.sqlite.*
import org.aprsfoundation.core.ChatSql
import org.aprsfoundation.core.ChatSqlRow
import org.aprsfoundation.core.ChatStore
internal class AppleChatStore private constructor(private val storage: AppleChatSql, now: () -> Long) :
    ChatStore(storage, now, expireAfterMillis = null) {
    constructor(path: String, now: () -> Long = { Clock.System.now().toEpochMilliseconds() }) :
        this(AppleChatSql(path), now)
    suspend fun shutdown() = closeStorage(storage::close)
}

@OptIn(ExperimentalForeignApi::class)
internal class AppleChatSql(path: String) : ChatSql {
    private val db: CPointer<sqlite3> = memScoped {
        val result = alloc<CPointerVar<sqlite3>>()
        val code = sqlite3_open_v2(
            path, result.ptr, SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_FULLMUTEX, null
        )
        val handle = result.value
        if (code != SQLITE_OK || handle == null) {
            handle?.let { sqlite3_close_v2(it) }
            error("Unable to open the chat database")
        }
        handle
    }

    init {
        checkResult(sqlite3_busy_timeout(db, 5000))
    }

    override fun execute(sql: String, vararg values: Any?): Int = statement(sql, values.asList()) {
        checkResult(sqlite3_step(it), SQLITE_DONE)
        sqlite3_changes(db)
    }

    override fun <T> query(sql: String, values: List<Any?>, read: (ChatSqlRow) -> T): List<T> =
        statement(sql, values) { cursor ->
            val row = object : ChatSqlRow {
                override fun text(index: Int): String =
                    checkNotNull(sqlite3_column_text(cursor, index)).reinterpret<ByteVar>().toKString()
                override fun number(index: Int): Long = sqlite3_column_int64(cursor, index)
            }
            buildList {
                var result = sqlite3_step(cursor)
                while (result == SQLITE_ROW) {
                    add(read(row))
                    result = sqlite3_step(cursor)
                }
                checkResult(result, SQLITE_DONE)
            }
        }

    override fun <T> transaction(block: () -> T): T {
        execute("BEGIN IMMEDIATE")
        try {
            val value = block()
            execute("COMMIT")
            return value
        } catch (failure: Throwable) {
            runCatching { execute("ROLLBACK") }.exceptionOrNull()?.let(failure::addSuppressed)
            throw failure
        }
    }

    fun close() { checkResult(sqlite3_close_v2(db)) }

    private inline fun <T> statement(sql: String, values: List<Any?>, block: (CPointer<sqlite3_stmt>) -> T): T =
        memScoped {
            val result = alloc<CPointerVar<sqlite3_stmt>>()
            checkResult(sqlite3_prepare_v2(db, sql, -1, result.ptr, null))
            val cursor = checkNotNull(result.value)
            try {
                for ((offset, value) in values.withIndex()) {
                    val index = offset + 1
                    val code = when (value) {
                        null -> sqlite3_bind_null(cursor, index)
                        is Number -> sqlite3_bind_int64(cursor, index, value.toLong())
                        is String -> aprs_bind_text(cursor, index, value)
                        else -> error("Unsupported chat SQL parameter")
                    }
                    checkResult(code)
                }
                block(cursor)
            } finally {
                sqlite3_finalize(cursor)
            }
        }

    private fun checkResult(code: Int, expected: Int = SQLITE_OK) {
        check(code == expected) { "Chat database error ($code)" }
    }
}

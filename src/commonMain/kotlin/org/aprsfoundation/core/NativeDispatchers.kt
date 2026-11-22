package org.aprsfoundation.core

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO as nativeIO

// The pinned JVM core references the member spelling; on Apple it is an extension.
internal val Dispatchers.IO: CoroutineDispatcher
    get() = this.nativeIO

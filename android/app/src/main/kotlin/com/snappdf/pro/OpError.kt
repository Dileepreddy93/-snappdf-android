package com.snappdf.pro

/**
 * Error with a stable code understood by the Dart layer
 * (see lib/core/platform/native_errors.dart).
 */
class OpError(val code: String, message: String, cause: Throwable? = null) : Exception(message, cause) {
    companion object {
        const val PASSWORD_REQUIRED = "PASSWORD_REQUIRED"
        const val WRONG_PASSWORD = "WRONG_PASSWORD"
        const val INVALID_FILE = "INVALID_FILE"
        const val UNSUPPORTED = "UNSUPPORTED"
        const val IO = "IO"
        const val CANCELLED = "CANCELLED"
        const val OUT_OF_MEMORY = "OUT_OF_MEMORY"
        const val TOO_LARGE = "TOO_LARGE"
        const val UNAVAILABLE = "UNAVAILABLE"
        const val RESTRICTED = "RESTRICTED"
        const val BAD_ARGS = "BAD_ARGS"
        const val INTERNAL = "INTERNAL"

        fun badArgs(message: String) = OpError(BAD_ARGS, message)
    }
}

/** Progress reporting and cooperative cancellation for long operations. */
interface OpContext {
    /** Throws [OpError] with code CANCELLED if the job has been cancelled. */
    fun checkCancelled()
    fun progress(done: Int, total: Int, message: String? = null)

    companion object {
        val NONE: OpContext = object : OpContext {
            override fun checkCancelled() {}
            override fun progress(done: Int, total: Int, message: String?) {}
        }
    }
}

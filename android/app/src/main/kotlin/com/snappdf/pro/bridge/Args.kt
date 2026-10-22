package com.snappdf.pro.bridge

import com.snappdf.pro.OpError
import io.flutter.plugin.common.MethodCall

/** Typed accessors for method-channel arguments with clear errors. */
class Args(private val map: Map<*, *>) {
    constructor(call: MethodCall) : this((call.arguments as? Map<*, *>) ?: emptyMap<String, Any>())

    fun has(key: String) = map[key] != null
    fun string(key: String): String = map[key] as? String ?: throw OpError.badArgs("Missing argument '$key'.")
    fun stringOrNull(key: String): String? = map[key] as? String
    fun bool(key: String, default: Boolean = false): Boolean = map[key] as? Boolean ?: default
    fun int(key: String, default: Int? = null): Int = (map[key] as? Number)?.toInt() ?: default
        ?: throw OpError.badArgs("Missing argument '$key'.")
    fun intOrNull(key: String): Int? = (map[key] as? Number)?.toInt()
    fun long(key: String, default: Long): Long = (map[key] as? Number)?.toLong() ?: default
    fun double(key: String, default: Double? = null): Double = (map[key] as? Number)?.toDouble() ?: default
        ?: throw OpError.badArgs("Missing argument '$key'.")
    fun doubleOrNull(key: String): Double? = (map[key] as? Number)?.toDouble()
    fun float(key: String, default: Float? = null): Float = (map[key] as? Number)?.toFloat() ?: default
        ?: throw OpError.badArgs("Missing argument '$key'.")
    fun strings(key: String): List<String> = (map[key] as? List<*>)?.map { it as? String ?: throw OpError.badArgs("Bad '$key'.") }
        ?: throw OpError.badArgs("Missing argument '$key'.")
    fun stringsOrNull(key: String): List<String>? = (map[key] as? List<*>)?.mapNotNull { it as? String }
    fun ints(key: String): List<Int>? = (map[key] as? List<*>)?.map { (it as? Number)?.toInt() ?: throw OpError.badArgs("Bad '$key'.") }
    fun doubles(key: String): List<Double>? = (map[key] as? List<*>)?.map { (it as? Number)?.toDouble() ?: throw OpError.badArgs("Bad '$key'.") }
    fun obj(key: String): Args = Args(map[key] as? Map<*, *> ?: throw OpError.badArgs("Missing argument '$key'."))
    fun objOrNull(key: String): Args? = (map[key] as? Map<*, *>)?.let { Args(it) }
    fun objects(key: String): List<Args> = (map[key] as? List<*>)?.map { Args(it as? Map<*, *> ?: throw OpError.badArgs("Bad '$key'.")) }
        ?: throw OpError.badArgs("Missing argument '$key'.")
    fun raw(key: String): Any? = map[key]
    fun bytes(key: String): ByteArray = map[key] as? ByteArray ?: throw OpError.badArgs("Missing argument '$key'.")
}

package com.james.easysave

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object DownloadControl {
    private val claims = DownloadClaims()
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "easysave/download_control").setMethodCallHandler { call, result ->
            when (call.method) {
                "reserve" -> result.success(claims.reserve(call.argument<String>("batch")!!,
                    call.argument<List<String>>("keys")!!, call.argument<Map<String, String>>("existing") ?: emptyMap()))
                "release" -> { claims.release(call.argument<String>("batch")!!); result.success(null) }
                "cancelPost" -> result.success(claims.cancelPost(call.argument<String>("prefix")!!))
                "isCancelled" -> result.success(claims.isCancelled(call.argument<String>("batch")!!))
                else -> result.notImplemented()
            }
        }
    }
}

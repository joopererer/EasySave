package com.james.easysave

import android.content.Context
import android.content.Intent
import java.net.URI

/** Local external-handler policy. Remote site manifests cannot add target packages. */
object ExternalHandlers {
    const val SEAL_PACKAGE = "com.junkfood.seal"
    private val urls = Regex("""https?://[^\s<>"'，。！？；：）】”　]+|(?<![a-zA-Z0-9_@./:-])(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:[/\?#][^\s<>"'，。！？；：）】”　]*)?""", RegexOption.IGNORE_CASE)

    fun extract(text: String?): String? = text?.let {
        urls.findAll(it).map { m -> m.value.trimEnd(')', ']', '}', ',', '.', ';', '!', '?') }
            .map { raw -> if (raw.contains("://")) raw else "https://$raw" }
            .firstOrNull(::accepts)
    }

    fun accepts(url: String): Boolean {
        val u = runCatching { URI(url) }.getOrNull() ?: return false
        if (u.scheme?.lowercase() !in setOf("http", "https") || u.userInfo != null) return false
        val h = u.host?.lowercase() ?: return false
        if (h == "youtu.be" || h.endsWith(".youtu.be")) return !u.path.isNullOrEmpty() && u.path != "/"
        if (listOf("youtube.com", "youtube-nocookie.com").none { h == it || h.endsWith(".$it") }) return false
        return (u.path == "/watch" && u.rawQuery.orEmpty().split('&').any { it.startsWith("v=") && it.length > 2 }) ||
            u.path.orEmpty().matches(Regex("^/shorts/[^/]+/?$"))
    }

    internal fun route(text: String?, installed: (String) -> Boolean,
                       launch: (String, String) -> Unit, missing: (String) -> Unit): Boolean {
        val url = extract(text) ?: return false
        if (installed(SEAL_PACKAGE)) launch(SEAL_PACKAGE, url) else missing(url)
        return true
    }

    fun handle(context: Context, text: String?): Boolean = route(text,
        installed = { pkg -> runCatching { context.packageManager.getPackageInfo(pkg, 0) }.isSuccess },
        launch = { pkg, url ->
            runCatching {
                context.startActivity(Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"; setPackage(pkg); putExtra(Intent.EXTRA_TEXT, url)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                })
            }.onFailure { showGuidance(context, url) }
        },
        missing = { url -> showGuidance(context, url) })

    private fun showGuidance(context: Context, url: String) {
        context.startActivity(Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_SEND; type = "text/plain"; putExtra(Intent.EXTRA_TEXT, url)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        })
    }
}

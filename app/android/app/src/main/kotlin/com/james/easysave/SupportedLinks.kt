package com.james.easysave

import android.content.Context
import java.io.File
import java.net.URI
import org.json.JSONObject

/** Entrance hints only. Flutter independently verifies and authorizes parsing. */
object SupportedLinks {
    internal var recognitionOverride: String? = null
    private val urls = Regex("""https?://[^\s<>"'，。！？；：）】”　]+|(?<![a-zA-Z0-9_@./:-])(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:[/\?#][^\s<>"'，。！？；：）】”　]*)?""", RegexOption.IGNORE_CASE)

    private fun readView(context: Context?): JSONObject? {
        recognitionOverride?.let { return runCatching { JSONObject(it) }.getOrNull() }
        if (context == null) return null
        val file = File(context.filesDir, "parser_v2/link-recognition.json")
        val cached = runCatching { if (file.isFile && file.length() <= 1024 * 1024) file.readText() else null }.getOrNull()
        return viewFromSources(cached) {
            context.assets.open("link-recognition.json").bufferedReader().use { it.readText() }
        }
    }

    internal fun viewFromSources(cached: String?, builtin: () -> String): JSONObject? {
        if (cached != null) runCatching { JSONObject(cached).also(::validate) }.getOrNull()?.let { return it }
        return runCatching { JSONObject(builtin()).also(::validate) }.getOrNull()
    }

    private fun validate(view: JSONObject) {
        val sites = view.getJSONArray("sites")
        for (i in 0 until sites.length()) {
            val site = sites.getJSONObject(i)
            site.getString("id")
            val routes = site.getJSONArray("routes")
            for (j in 0 until routes.length()) {
                val route = routes.getJSONObject(j)
                val hosts = route.getJSONArray("hosts")
                for (k in 0 until hosts.length()) {
                    hosts.getJSONObject(k).getString("domain")
                    hosts.getJSONObject(k).getBoolean("includeSubdomains")
                }
                val paths = route.getJSONArray("pathPatterns")
                for (k in 0 until paths.length()) Regex(paths.getString(k))
            }
        }
    }

    internal fun siteId(url: String, view: JSONObject): String? {
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.userInfo != null) return null
        val host = uri.host?.lowercase() ?: return null
        val sites = view.getJSONArray("sites")
        for (i in 0 until sites.length()) {
            val site = sites.getJSONObject(i)
            val routes = site.getJSONArray("routes")
            for (j in 0 until routes.length()) {
                val route = routes.getJSONObject(j)
                val hosts = route.getJSONArray("hosts")
                val hostMatch = (0 until hosts.length()).any { k ->
                    val rule = hosts.getJSONObject(k)
                    val domain = rule.getString("domain")
                    host == domain || (rule.getBoolean("includeSubdomains") && host.endsWith(".$domain"))
                }
                val patterns = route.getJSONArray("pathPatterns")
                if (hostMatch && (0 until patterns.length()).any { k ->
                    Regex(patterns.getString(k)).containsMatchIn(uri.path ?: "")
                }) return site.getString("id")
            }
        }
        return null
    }

    fun extractUrls(text: String?, context: Context? = null): List<String> {
        if (text == null) return emptyList()
        val view = readView(context) ?: return emptyList()
        return urls.findAll(text).mapNotNull { match ->
            val raw = match.value.trimEnd(')', ']', '}', ',', '.', ';', '!', '?')
            val normalized = if (raw.contains("://")) raw else "https://$raw"
            if (siteId(normalized, view) != null) normalized else null
        }.distinct().toList()
    }
    fun containsSupportedUrl(text: String?, context: Context? = null): Boolean = extractUrls(text, context).isNotEmpty()
}

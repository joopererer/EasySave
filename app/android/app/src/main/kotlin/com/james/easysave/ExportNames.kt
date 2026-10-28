package com.james.easysave

object ExportNames {
    private const val ID = "[A-Za-z0-9_-]+"
    private const val EXT = "jpg|jpeg|png|webp|mp4|mov"
    private const val UUID = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private val clean = Regex("^($ID)_([1-9][0-9]*)\\.($EXT)$")
    private val legacy = Regex("^($ID)_([1-9][0-9]*)_($UUID)\\.($EXT)$")
    fun requireClean(name: String): String { require(clean.matches(name)); return name }
    fun albumPath(album: String): String {
        require(album.isNotBlank() && album !in setOf(".", "..") && album.none { it == '/' || it == '\\' || it == '\u0000' })
        return "Pictures/$album/"
    }
    fun repairScopes(albums: List<String>): List<String> = listOf(C2paStoragePolicy.RELATIVE_PATH) +
        albums.mapNotNull { runCatching { albumPath(it) }.getOrNull() }.distinct()
    fun legacyTarget(name: String): String? {
        val m = legacy.matchEntire(name) ?: return null
        return "${m.groupValues[1]}_${m.groupValues[2]}.${m.groupValues[4]}"
    }
    data class Repair(val status: String, val target: String? = null, val errorClass: String? = null)
    fun repair(name: String, requireSidecar: Boolean, exists: (String) -> Boolean, rename: (String, String) -> Boolean): Repair {
        val target = legacyTarget(name) ?: return Repair("ignored")
        var moved = false
        try {
            val sidecar = exists("$name.xmp")
            if (requireSidecar && !sidecar) return Repair("missing_sidecar", target)
            if (exists(target) || exists("$target.xmp")) return Repair("target_exists", target)
            check(rename(name, target)) { "Media rename failed" }; moved = true
            if (sidecar) check(rename("$name.xmp", "$target.xmp")) { "Sidecar rename failed" }
            return Repair("renamed", target)
        } catch (e: Exception) {
            if (moved) {
                val restored = runCatching { rename(target, name) }.getOrDefault(false)
                if (!restored) return Repair("rollback_failed", target, e.javaClass.simpleName)
            }
            return Repair("error", target, e.javaClass.simpleName)
        }
    }
}

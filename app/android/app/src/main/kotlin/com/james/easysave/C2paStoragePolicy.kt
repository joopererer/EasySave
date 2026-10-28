package com.james.easysave

object C2paStoragePolicy {
    const val RELATIVE_PATH = "Download/EasySave/"
    const val DIRECTORY_NAME = "EasySave"
    const val MEDIA_SELECTION = "relative_path = ? AND is_pending = 0"

    fun isFixedMedia(relativePath: String?, mime: String?): Boolean =
        relativePath == RELATIVE_PATH &&
            (mime?.startsWith("image/") == true || mime?.startsWith("video/") == true)

    fun mediaType(relativePath: String?, mime: String?): Int? {
        val normalized = mime?.lowercase(java.util.Locale.ROOT)
        if (!isFixedMedia(relativePath, normalized)) return null
        return if (normalized!!.startsWith("image/")) 1 else 2
    }

    fun <T> finishDelete(approved: Boolean, sidecars: List<T>, delete: (T) -> Unit): Boolean {
        if (!approved) return false
        sidecars.forEach(delete)
        return true
    }
}

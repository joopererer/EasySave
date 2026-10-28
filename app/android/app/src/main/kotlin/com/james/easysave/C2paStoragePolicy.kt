package com.james.easysave

object C2paStoragePolicy {
    const val RELATIVE_PATH = "Download/EasySave/"
    const val DIRECTORY_NAME = "EasySave"
    const val MEDIA_SELECTION = "relative_path = ? AND media_type IN (1, 3)"

    fun isFixedMedia(relativePath: String?, mime: String?): Boolean =
        relativePath == RELATIVE_PATH &&
            (mime?.startsWith("image/") == true || mime?.startsWith("video/") == true)

    fun <T> finishDelete(approved: Boolean, sidecars: List<T>, delete: (T) -> Unit): Boolean {
        if (!approved) return false
        sidecars.forEach(delete)
        return true
    }
}

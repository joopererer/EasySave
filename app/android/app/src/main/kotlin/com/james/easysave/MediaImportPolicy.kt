package com.james.easysave

/**
 * Containers an album import may write, and what provenance means for them.
 *
 * The download pipeline saves a still in the format its own header declares.
 * provenance_dart can only write XMP into JPEG, PNG, WebP and MP4/MOV, so a
 * HEIC / HEIF / AVIF / GIF still is imported unchanged: no sidecar, no
 * embedded metadata, pairing identity from the history row only. The whitelist
 * therefore keeps every real photo container instead of restricting the import
 * to the writable ones (that restriction is what made a HEIC original fail
 * with `inspectTarget: IllegalArgumentException: Failed requirement.`).
 *
 * Android-free so the import decision is unit-testable without a device.
 */
object MediaImportPolicy {
    private val imageMimes = setOf(
        "image/jpeg", "image/png", "image/webp", "image/gif",
        "image/heic", "image/heif", "image/avif",
    )
    private val videoMimes = setOf("video/mp4", "video/quicktime")

    /** Containers provenance_dart can write XMP into. */
    private val provenanceMimes = setOf(
        "image/jpeg", "image/png", "image/webp", "video/mp4", "video/quicktime",
    )

    val allowedMimes: Set<String> = imageMimes + videoMimes

    fun isAllowed(mime: String): Boolean = mime in imageMimes || mime in videoMimes

    fun isImage(mime: String): Boolean = mime in imageMimes

    /** The container itself carries provenance; a still that does not is
     * imported as-is and needs no sidecar. */
    fun provenanceEmbeddable(mime: String): Boolean = mime in provenanceMimes

    /**
     * Gate of both writers. [mime] comes from the finished file's own header,
     * never from the URL, so a HEIC answered to a `.jpg` candidate is imported
     * as HEIC instead of being refused.
     */
    fun requireAllowed(mime: String): String {
        require(isAllowed(mime)) { "Unsupported media type" }
        return mime
    }
}

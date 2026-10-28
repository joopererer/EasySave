package com.james.easysave

/** Android-free decisions used by the pair writer and JVM tests. */
object PairSavePolicy {
    // Downloads accepts arbitrary binary files; avoid providers mapping RDF MIME
    // to .rdf/.xml and changing the full-filename .xmp pairing convention.
    const val SIDECAR_MIME = "application/octet-stream"

    fun mediaName(original: String, unique: String): String {
        ProvenancePairWriter.sidecarName(original) // validate before constructing
        require(unique.matches(Regex("[a-zA-Z0-9-]+")))
        val dot = original.lastIndexOf('.')
        require(dot > 0 && dot < original.lastIndex)
        return original.substring(0, dot) + "_" + unique + original.substring(dot)
    }

    fun errorMessage(step: String, error: Exception): String {
        // Do not attach the Throwable to Log.w: its stack/cause may hold credentials.
        val message = (error.message ?: "无详细消息")
            .replace(Regex("(?i)cookie[^\\r\\n]*"), "[redacted]")
            .replace(Regex("(?i)(https?://[^\\s?#]+)[?#][^\\s]*"), "$1[redacted]")
            .replace(Regex("[\\r\\n]+"), " ")
        return "$step: ${error.javaClass.simpleName}: $message"
    }
}

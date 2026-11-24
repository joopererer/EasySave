package com.james.easysave.transfer

import com.james.easysave.MediaImportPolicy
import java.io.File
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets

object MediaSniffer {

    private val HEIC_BRANDS = setOf(
        "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"
    )
    private val AVIF_BRANDS = setOf("avif", "avis")
    private val VIDEO_BRANDS = setOf(
        "isom", "iso2", "iso3", "iso4", "iso5", "iso6", "iso8", "iso9",
        "mp41", "mp42", "avc1", "dash", "M4V ", "M4VH", "M4VP", "MSNV", "mmp4",
        "3gp4", "3gp5", "3gp6", "3g2a", "qt  "
    )
    private val MOVIE_BOX_TYPES = setOf(
        "ftyp", "styp", "moov", "mdat", "free", "skip", "wide", "junk", "pnot",
        "sidx", "moof", "mfra", "meta", "uuid", "udta"
    )

    fun sniff(file: File): String? {
        if (!file.exists() || file.length() < 3) return null
        val header = ByteArray(64)
        val readCount = RandomAccessFile(file, "r").use { raf -> raf.read(header) }
        if (readCount < 3) return null

        // JPEG: 0xFF 0xD8 0xFF
        if ((header[0].toInt() and 0xFF) == 0xFF &&
            (header[1].toInt() and 0xFF) == 0xD8 &&
            (header[2].toInt() and 0xFF) == 0xFF
        ) {
            return "image/jpeg"
        }

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if (readCount >= 8 &&
            (header[0].toInt() and 0xFF) == 0x89 &&
            header[1] == 0x50.toByte() &&
            header[2] == 0x4E.toByte() &&
            header[3] == 0x47.toByte() &&
            header[4] == 0x0D.toByte() &&
            header[5] == 0x0A.toByte() &&
            header[6] == 0x1A.toByte() &&
            header[7] == 0x0A.toByte()
        ) {
            return "image/png"
        }

        // WebP: RIFF .... WEBP
        if (readCount >= 12 &&
            header[0] == 'R'.code.toByte() && header[1] == 'I'.code.toByte() &&
            header[2] == 'F'.code.toByte() && header[3] == 'F'.code.toByte() &&
            header[8] == 'W'.code.toByte() && header[9] == 'E'.code.toByte() &&
            header[10] == 'B'.code.toByte() && header[11] == 'P'.code.toByte()
        ) {
            return "image/webp"
        }

        // GIF: GIF87a or GIF89a
        if (readCount >= 6 &&
            header[0] == 'G'.code.toByte() && header[1] == 'I'.code.toByte() &&
            header[2] == 'F'.code.toByte() && header[3] == '8'.code.toByte()
        ) {
            return "image/gif"
        }

        // ISO-BMFF
        if (readCount >= 8) {
            val type = String(header, 4, 4, StandardCharsets.US_ASCII)
            if (MOVIE_BOX_TYPES.contains(type)) {
                if (type != "ftyp") {
                    return "video/mp4"
                }
                if (readCount >= 12) {
                    val majorBrand = String(header, 8, 4, StandardCharsets.US_ASCII)
                    val brands = mutableListOf(majorBrand)
                    val boxSize = (((header[0].toInt() and 0xFF) shl 24) or
                            ((header[1].toInt() and 0xFF) shl 16) or
                            ((header[2].toInt() and 0xFF) shl 8) or
                            (header[3].toInt() and 0xFF))
                    val end = if (boxSize in 16..readCount) boxSize else readCount
                    var offset = 16
                    while (offset + 4 <= end) {
                        brands.add(String(header, offset, 4, StandardCharsets.US_ASCII))
                        offset += 4
                    }

                    if (brands.any { it in AVIF_BRANDS }) return "image/avif"
                    if (brands.any { it in HEIC_BRANDS }) return "image/heic"
                    if (brands.firstOrNull() == "qt  ") return "video/quicktime"
                    if (brands.any { it in VIDEO_BRANDS }) return "video/mp4"
                    return "video/mp4"
                }
            }
        }

        return null
    }

    fun matches(expectedMime: String?, sniffedMime: String?): Boolean {
        if (sniffedMime == null) return false
        if (!MediaImportPolicy.isAllowed(sniffedMime)) return false
        if (expectedMime.isNullOrBlank() || expectedMime == "*/*") return true

        val exp = expectedMime.lowercase().trim()
        val act = sniffedMime.lowercase().trim()
        if (exp == act) return true

        if (exp == "video/mp4" && act == "video/quicktime") return true
        if (exp == "video/quicktime" && act == "video/mp4") return true
        if (exp == "image/heic" && act == "image/heif") return true
        if (exp == "image/heif" && act == "image/heic") return true

        if (exp == "image/*" && act.startsWith("image/")) return true
        if (exp == "video/*" && act.startsWith("video/")) return true

        return false
    }
}


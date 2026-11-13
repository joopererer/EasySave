package com.james.easysave

import org.junit.Assert.assertNotNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * Decode table of the HEIC samples that broke the album on Android 12.
 *
 * Drop the samples into `src/test/resources/fixtures/heic/` (`.heic`, `.heif`
 * or `.avif`) and the table below lists, for every file, what the platform
 * probe answers. Only files that exist are read; the directory is never
 * written, and nothing outside it is touched.
 *
 * LIMITATION — this is not the device answer. Robolectric's `BitmapFactory`
 * shadow returns a fabricated bitmap for any input, so an emulated run says
 * "decodable" for every sample. The real table comes from the read-only
 * on-device self-check (`EASYSAVE_HEIC_SELFCHECK`, see
 * `docs/tasks/v1.10.3-heic-video-hotfix.md`), which runs the same
 * [ImageDecodeProbe] against the real HEIF decoder of the phone. This test
 * therefore only asserts that the probe is total and self-consistent.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class HeicSampleDecodeTableTest {
    private val samples: List<File> by lazy {
        val dir = File(javaClass.classLoader?.getResource("fixtures/heic")?.toURI() ?: return@lazy emptyList())
        (dir.listFiles() ?: emptyArray())
            .filter { it.extension.lowercase() in setOf("heic", "heif", "avif") }
            .sortedBy { it.name }
    }

    @Test
    fun `every sample yields a complete probe answer`() {
        assumeTrue("no HEIC samples dropped into fixtures/heic/", samples.isNotEmpty())
        val rows = samples.map { file ->
            val outcome = ImageDecodeProbe.probeFile(file)
            "sample name=${file.name} bytes=${file.length()} " +
                "bounds=${outcome.width}x${outcome.height} " +
                "sample=${outcome.sampleWidth}x${outcome.sampleHeight} " +
                "decoder=${outcome.decoder} decodable=${outcome.decodable} reason=${outcome.reason}"
        }
        println(rows.joinToString("\n", prefix = "HEIC decode table (emulated, not the device answer)\n"))
        for (outcome in samples.map { ImageDecodeProbe.probeFile(it) }) {
            assertNotNull(outcome.reason)
            if (!outcome.decodable) continue
            // A decodable answer must carry both the declared and the sampled size.
            assert(outcome.width > 0 && outcome.height > 0)
            assert(outcome.sampleWidth > 0 && outcome.sampleHeight > 0)
        }
    }
}

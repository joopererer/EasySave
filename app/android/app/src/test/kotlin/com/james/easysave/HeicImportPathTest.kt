package com.james.easysave

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class HeicImportPathTest {
    /** In-memory MediaStore honouring insert / query / openFile / update / delete. */
    class FakeMediaStore : ContentProvider() {
        class Row(val id: String, val values: ContentValues, val file: File)

        val rows = mutableListOf<Row>()
        private var next = 0

        fun reset() {
            rows.clear()
            next = 0
        }

        override fun onCreate(): Boolean = true

        override fun insert(uri: Uri, values: ContentValues?): Uri {
            val id = (++next).toString()
            val file = File(context!!.cacheDir, "media-$id.bin").apply { writeBytes(ByteArray(0)) }
            rows.add(Row(id, ContentValues(values), file))
            return uri.buildUpon().appendPath(id).build()
        }

        override fun query(
            uri: Uri,
            projection: Array<out String>?,
            selection: String?,
            selectionArgs: Array<out String>?,
            sortOrder: String?,
        ): Cursor {
            val wanted = uri.lastPathSegment?.takeIf { segment -> segment.all(Char::isDigit) }
            val columns = projection ?: arrayOf("_id", "_display_name", "mime_type")
            val cursor = MatrixCursor(columns)
            for (row in rows) {
                if (wanted != null && row.id != wanted) continue
                cursor.addRow(columns.map { column ->
                    when (column) {
                        "_id" -> row.id
                        "_display_name" -> row.values.getAsString("_display_name")
                        "mime_type" -> row.values.getAsString("mime_type")
                        "relative_path" -> row.values.getAsString("relative_path")
                        else -> null
                    }
                })
            }
            return cursor
        }

        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
            val id = uri.lastPathSegment!!.takeIf { segment -> segment.all(Char::isDigit) }!!
            val file = rows.first { it.id == id }.file
            val writing = mode.contains('w')
            val flags = if (writing) {
                ParcelFileDescriptor.MODE_READ_WRITE or
                    ParcelFileDescriptor.MODE_CREATE or
                    ParcelFileDescriptor.MODE_TRUNCATE
            } else {
                ParcelFileDescriptor.MODE_READ_ONLY
            }
            return ParcelFileDescriptor.open(file, flags)
        }

        override fun update(
            uri: Uri,
            values: ContentValues?,
            selection: String?,
            selectionArgs: Array<out String>?,
        ): Int {
            val id = uri.lastPathSegment ?: return 0
            val row = rows.firstOrNull { it.id == id } ?: return 0
            values?.let { row.values.putAll(it) }
            return 1
        }

        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
            val id = uri.lastPathSegment ?: return 0
            val row = rows.firstOrNull { it.id == id } ?: return 0
            row.file.delete()
            rows.remove(row)
            return 1
        }

        override fun getType(uri: Uri): String? = null
    }
    private lateinit var store: FakeMediaStore
    private lateinit var cacheDir: File

    @Before
    fun setUp() {
        store = Robolectric.setupContentProvider(FakeMediaStore::class.java, "media")
        store.reset()
        cacheDir = RuntimeEnvironment.getApplication().cacheDir
    }

    private fun fixture(vararg candidates: String): ByteArray {
        for (path in candidates) {
            val file = File(path)
            if (file.isFile) return file.readBytes()
        }
        val resource = candidates.firstOrNull()?.let {
            javaClass.getResourceAsStream("/${it.substringAfterLast('/')}")
        }
        if (resource != null) return resource.use { it.readBytes() }
        fail("fixture not found: ${candidates.toList()}")
        error("unreachable")
    }

    private fun heicBytes(): ByteArray = fixture(
        "src/test/resources/fixtures/xhs_live_still.heic",
        "android/app/src/test/resources/fixtures/xhs_live_still.heic",
        "app/android/app/src/test/resources/fixtures/xhs_live_still.heic",
    )

    private fun webpBytes(): ByteArray = fixture(
        "../../../docs/provenance-spec/test-vectors/x-single.webp",
        "../../docs/provenance-spec/test-vectors/x-single.webp",
        "../docs/provenance-spec/test-vectors/x-single.webp",
        "docs/provenance-spec/test-vectors/x-single.webp",
        "D:/workspace/IdeaProjects/EasySave/docs/provenance-spec/test-vectors/x-single.webp",
    )

    private fun writeTemp(bytes: ByteArray, suffix: String): File {
        val file = File(cacheDir, "staging-${System.nanoTime()}.$suffix").apply { writeBytes(bytes) }
        file.deleteOnExit()
        return file
    }

    private fun insertedRow(): FakeMediaStore.Row {
        assertEquals(1, store.rows.size)
        return store.rows.single()
    }

    @Test
    fun `heic still is written with its own extension and image-heic mime`() {
        val bytes = heicBytes()
        assertTrue("HEIC fixture must be non-trivial", bytes.size > 64)
        val name = "6aeff4780000000010011312_1.heic"
        val source = writeTemp(bytes, "heic")

        val result = PublicMediaWriter.save(
            RuntimeEnvironment.getApplication(),
            source,
            "image/heic",
            "EasySave",
            name,
        )

        val row = insertedRow()
        assertEquals(name, row.values.getAsString("_display_name"))
        assertEquals("image/heic", row.values.getAsString("mime_type"))
        assertEquals("Pictures/EasySave/", row.values.getAsString("relative_path"))
        assertEquals(name, result["title"])
        assertEquals(row.id, result["mediaId"])
        // Storage must hold the original container bytes, not a re-encoded still.
        assertTrue(row.file.readBytes().contentEquals(bytes))
    }

    @Test
    fun `webp still is written with its own extension and image-webp mime`() {
        val bytes = webpBytes()
        assertTrue("WebP fixture must be non-trivial", bytes.size > 32)
        val name = "69b6a20000000000210399a5_1.webp"
        val source = writeTemp(bytes, "webp")

        val result = PublicMediaWriter.save(
            RuntimeEnvironment.getApplication(),
            source,
            "image/webp",
            "EasySave",
            name,
        )

        val row = insertedRow()
        assertEquals(name, row.values.getAsString("_display_name"))
        assertEquals("image/webp", row.values.getAsString("mime_type"))
        assertEquals(name, result["title"])
        assertTrue(row.file.readBytes().contentEquals(bytes))
    }

    @Test
    fun `album naming accepts every container a still may keep`() {
        for (extension in listOf("heic", "heif", "avif", "webp", "png", "gif", "jpg")) {
            val name = "6aeff4780000000010011312_1.$extension"
            assertEquals(name, ExportNames.requireClean(name))
        }
        for (mime in listOf("image/heic", "image/heif", "image/avif", "image/webp", "image/png", "image/gif")) {
            assertEquals(mime, MediaImportPolicy.requireAllowed(mime))
        }
    }

    @Test
    fun `unknown containers are not importable`() {
        val source = writeTemp(byteArrayOf(1, 2, 3), "bin")
        try {
            PublicMediaWriter.save(
                RuntimeEnvironment.getApplication(),
                source,
                "image/tiff",
                "EasySave",
                "6aeff4780000000010011312_1.tiff",
            )
            fail("image/tiff must not pass the import gate")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message!!.isNotEmpty())
        }
    }
}


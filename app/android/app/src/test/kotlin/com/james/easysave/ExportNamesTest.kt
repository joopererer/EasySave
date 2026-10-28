package com.james.easysave
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class ExportNamesTest {
    private val old = "7674898126922140959_1_d16e3f95-5dcb-43f4-b0dd-9cea903110b6.jpg"
    private val clean = "7674898126922140959_1.jpg"
    @Test fun exactLegacyPatternAndCleanFinalNames() {
        assertEquals(clean, ExportNames.legacyTarget(old))
        assertEquals(clean, ExportNames.requireClean(clean))
        assertTrue(runCatching { ExportNames.requireClean(old) }.isFailure)
        for (name in listOf("$old.xmp", "backup.json", "123_1_abc.jpg", "123_0_d16e3f95-5dcb-43f4-b0dd-9cea903110b6.jpg", "../$old"))
            assertNull(name, ExportNames.legacyTarget(name))
    }
    @Test fun scopeDoesNotExtendOutsideFixedAndUsedPictureAlbums() {
        assertEquals(listOf("Download/EasySave/", "Pictures/EasySave/"), ExportNames.repairScopes(listOf("EasySave", "EasySave", "../Other", "", "Android/data")))
    }
    @Test fun realPairRenamePreservesEveryByte() {
        val dir = Files.createTempDirectory("export-pair-").toFile()
        try {
            dir.resolve(old).writeText("unchanged signed image")
            dir.resolve("$old.xmp").writeText("unchanged XMP capture fields")
            val result = ExportNames.repair(old, true, { dir.resolve(it).exists() }, { a, b -> dir.resolve(a).renameTo(dir.resolve(b)) })
            assertEquals("renamed", result.status)
            assertEquals("unchanged signed image", dir.resolve(clean).readText())
            assertEquals("unchanged XMP capture fields", dir.resolve("$clean.xmp").readText())
            assertFalse(dir.resolve(old).exists()); assertFalse(dir.resolve("$old.xmp").exists())
        } finally { dir.deleteRecursively() }
    }
    @Test fun eitherTargetCollisionSkipsBothWithoutCallingRename() {
        for (target in listOf(clean, "$clean.xmp")) {
            val names = setOf(old, "$old.xmp", target)
            val result = ExportNames.repair(old, true, { it in names }, { _, _ -> error("Must not rename on collision") })
            assertEquals("target_exists", result.status)
        }
    }
    @Test fun failedSecondRenameRollsBackFirst() {
        val names = mutableSetOf(old, "$old.xmp")
        val result = ExportNames.repair(old, true, { it in names }, { from, to ->
            if (from == "$old.xmp") false else { check(names.remove(from)); names.add(to); true }
        })
        assertEquals("error", result.status); assertEquals(setOf(old, "$old.xmp"), names)
    }
    @Test fun downloadRequiresSidecarButOrdinaryPictureVideoCanBeRepairedAlone() {
        assertEquals("missing_sidecar", ExportNames.repair(old, true, { it == old }, { _, _ -> error("Must not rename incomplete pair") }).status)
        val video = old.replace(".jpg", ".mp4")
        val names = mutableSetOf(video)
        assertEquals("renamed", ExportNames.repair(video, false, { it in names }, { a, b -> names.remove(a); names.add(b); true }).status)
        assertEquals(setOf(clean.replace(".jpg", ".mp4")), names)
    }
    @Test fun failedRollbackIsReportedRatherThanSuccessfulRepair() {
        var calls = 0
        val result = ExportNames.repair(old, true, { it == old || it == "$old.xmp" }, { _, _ -> ++calls == 1 })
        assertEquals("rollback_failed", result.status)
    }
}

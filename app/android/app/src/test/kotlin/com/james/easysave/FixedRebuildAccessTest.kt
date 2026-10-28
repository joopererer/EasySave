package com.james.easysave
import org.junit.Assert.*
import org.junit.Test
class FixedRebuildAccessTest {
    @Test fun onlyExactFixedPublicTreeIsAccepted() {
        assertTrue(FixedRebuildAccess.validTreeId("primary:Download/EasySave"))
        for (id in listOf("primary:", "primary:Download", "primary:Android/data", "primary:Download/EasySave/sub", "primary:Download/EasySave/.."))
            assertFalse(id, FixedRebuildAccess.validTreeId(id))
    }
    @Test fun namesCannotEscapePublicDirectory() {
        assertTrue(FixedRebuildAccess.validName("123_1.jpg.xmp"))
        for (name in listOf("", ".", "..", "../private", "a/b", "a\\b", "x\u0000y")) assertFalse(name, FixedRebuildAccess.validName(name))
    }
    @Test fun mediaEnumerationExcludesBinarySidecarsAndBackups() {
        assertEquals("image/jpeg", FixedRebuildAccess.mime("123_1.jpg"))
        assertEquals("video/mp4", FixedRebuildAccess.mime("123_1.mp4"))
        assertNull(FixedRebuildAccess.mime("123_1.jpg.xmp"))
        assertNull(FixedRebuildAccess.mime("easysave-backup-20261028-010101.json"))
    }
}

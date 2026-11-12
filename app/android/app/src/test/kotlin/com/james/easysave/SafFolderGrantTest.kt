package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A backup folder may only be declared lost when the system confirmed the
 * persisted grant is gone. An unanswered probe must stay UNKNOWN so the saved
 * setting (switch + folder) is never cleared by a transient failure.
 */
class SafFolderGrantTest {
    @Test fun healthyFolderIsOk() {
        val decision = SafFolderGrant.decide(
            uriValid = true,
            persistedGrants = 1,
            matched = true,
            documentExists = true,
            isDirectory = true,
            writable = true,
            probeFailed = false,
        )
        assertEquals(SafFolderGrant.State.OK, decision.state)
        assertEquals("ok", decision.reason)
    }

    @Test fun missingGrantIsLost() {
        val decision = SafFolderGrant.decide(
            uriValid = true,
            persistedGrants = 0,
            matched = false,
            documentExists = false,
            isDirectory = false,
            writable = false,
            probeFailed = false,
        )
        assertEquals(SafFolderGrant.State.LOST, decision.state)
        assertEquals("grant_missing", decision.reason)
    }

    @Test fun aGrantThatNoLongerMatchesIsLost() {
        val decision = SafFolderGrant.decide(
            uriValid = true,
            persistedGrants = 3,
            matched = false,
            documentExists = true,
            isDirectory = true,
            writable = true,
            probeFailed = false,
        )
        assertEquals(SafFolderGrant.State.LOST, decision.state)
        assertEquals("grant_missing", decision.reason)
    }

    @Test fun aDeletedFolderIsLost() {
        val decision = SafFolderGrant.decide(
            uriValid = true,
            persistedGrants = 1,
            matched = true,
            documentExists = false,
            isDirectory = false,
            writable = false,
            probeFailed = false,
        )
        assertEquals(SafFolderGrant.State.LOST, decision.state)
        assertEquals("directory_missing", decision.reason)
    }

    @Test fun aFailedProbeIsUnknownNotLost() {
        val decision = SafFolderGrant.decide(
            uriValid = true,
            persistedGrants = 0,
            matched = false,
            documentExists = false,
            isDirectory = false,
            writable = false,
            probeFailed = true,
        )
        assertEquals(SafFolderGrant.State.UNKNOWN, decision.state)
        assertEquals("probe_failed", decision.reason)
    }

    @Test fun anInvalidUriIsLostWithoutProbing() {
        val decision = SafFolderGrant.decide(
            uriValid = false,
            persistedGrants = 0,
            matched = false,
            documentExists = false,
            isDirectory = false,
            writable = false,
            probeFailed = false,
        )
        assertEquals(SafFolderGrant.State.LOST, decision.state)
        assertEquals("invalid_uri", decision.reason)
    }
}

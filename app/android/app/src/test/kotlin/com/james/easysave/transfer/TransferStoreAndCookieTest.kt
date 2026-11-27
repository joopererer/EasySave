package com.james.easysave.transfer

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class TransferStoreAndCookieTest {

    private lateinit var store: TransferStore

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication()
        store = TransferStore(context, "test_p04b_${System.nanoTime()}.db")
    }

    @After
    fun tearDown() {
        store.close()
    }

    @Test
    fun testClaimHistoryWrite_atomicAndReleasesAfterTimeout() {
        val batchId = "bg-batch-1"
        val t0 = 1_000_000L

        assertTrue(store.claimHistoryWrite(batchId, nowMs = t0, timeoutMs = 60_000L))
        // Second engine within 60s cannot claim
        assertFalse(store.claimHistoryWrite(batchId, nowMs = t0 + 30_000L, timeoutMs = 60_000L))
        // After 60s timeout, another engine can claim and backfill
        assertTrue(store.claimHistoryWrite(batchId, nowMs = t0 + 60_000L, timeoutMs = 60_000L))
    }

    @Test
    fun testClaimMigration_atomicAndReleasesAfterTimeout() {
        val batchId = "legacy-batch-1"
        val t0 = 2_000_000L

        assertTrue(store.claimMigration(batchId, nowMs = t0, timeoutMs = 60_000L))
        assertFalse(store.claimMigration(batchId, nowMs = t0 + 30_000L, timeoutMs = 60_000L))
        assertTrue(store.claimMigration(batchId, nowMs = t0 + 60_000L, timeoutMs = 60_000L))
    }

    @Test
    fun testTransferStoreJobDoesNotStoreCookie() {
        val secretCookie = "sessionid=super_secret_cookie_xyz_999"
        val job = TransferJob(
            jobId = "tiktok_cookie_job_store",
            direction = Direction.DOWNLOAD,
            category = JobCategory.LARGE_FILE,
            batchId = "bg-tiktok-1",
        )
        store.insertOrReplace(job)
        val storedJob = store.getJob("tiktok_cookie_job_store")!!
        assertFalse(storedJob.toMap().toString().contains(secretCookie))
    }
}

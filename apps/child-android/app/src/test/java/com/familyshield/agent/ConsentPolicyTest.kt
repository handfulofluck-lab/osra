package com.familyshield.agent

import com.familyshield.agent.data.ConsentPolicy
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Response

/** ADR-0008 §3: the agent pauses on consent withdrawal and resumes on re-grant, from either signal. */
class ConsentPolicyTest {

    @Test
    fun `consent_revoked pauses and consent_granted resumes`() {
        assertTrue(ConsentPolicy.afterCommand(paused = false, type = "consent_revoked"))
        assertFalse(ConsentPolicy.afterCommand(paused = true, type = "consent_granted"))
    }

    @Test
    fun `other commands leave the state untouched`() {
        assertFalse(ConsentPolicy.afterCommand(paused = false, type = "lock"))
        assertTrue(ConsentPolicy.afterCommand(paused = true, type = "rules_updated"))
    }

    @Test
    fun `a 428 poll pauses and a 2xx poll resumes`() {
        assertTrue(ConsentPolicy.afterPoll(paused = false, httpStatus = 428))
        assertFalse(ConsentPolicy.afterPoll(paused = true, httpStatus = 200))
        assertFalse(ConsentPolicy.afterPoll(paused = true, httpStatus = 204))
    }

    @Test
    fun `401, 5xx and network failures say nothing about consent`() {
        assertTrue(ConsentPolicy.afterPoll(paused = true, httpStatus = 401))
        assertTrue(ConsentPolicy.afterPoll(paused = true, httpStatus = 503))
        assertFalse(ConsentPolicy.afterPoll(paused = false, httpStatus = 500))
        assertFalse(ConsentPolicy.afterPoll(paused = false, httpStatus = 401))
    }

    @Test
    fun `http status is extracted from retrofit failures only`() {
        val body = "{}".toResponseBody("application/json".toMediaType())
        val http = HttpException(Response.error<Any>(428, body))
        assertEquals(428, ConsentPolicy.httpStatusOf(http))
        assertNull(ConsentPolicy.httpStatusOf(java.io.IOException("offline")))
    }
}

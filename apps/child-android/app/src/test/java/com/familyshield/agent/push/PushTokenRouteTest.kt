package com.familyshield.agent.push

import com.familyshield.agent.network.ApiService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import retrofit2.http.POST

/**
 * Issue #319: pins the route and the body field the agent publishes its FCM token on.
 *
 * Claude's Decision 1 (#319, 2026-10-23), binding: the client uses the **existing**
 * `POST /v1/devices/:id/push-token` — device-only, body `{ token: string }` (20–4096 characters),
 * response `204`. The server half is PR #320. An earlier revision of this branch invented
 * `.../push-token/self` and renamed the body field to `pushToken`; either one misses the decided
 * contract, so this test exists to fail on exactly that revert.
 *
 * Retrofit annotations are readable at runtime, so the contract is pinned structurally rather than by
 * grepping the source. What is out of reach here: the server accepting a device JWT on that route —
 * that is the API suite's and the probe's row (PR #320), plus the hardware row for "a lock lands with
 * the app backgrounded". Suspend functions compile with a trailing `Continuation`, so the method is
 * matched by name, as `CommandPollAckCapabilityTest` does for the poll.
 */
class PushTokenRouteTest {

    private val method = ApiService::class.java.declaredMethods
        .firstOrNull { it.name == "postPushToken" }
        ?: error("ApiService.postPushToken is missing")

    /**
     * Mutant: annotate the method `v1/devices/{id}/push-token/self` (or any other path) and this fails
     * with that value while the DTO half stays green — the exact revert this test exists to catch.
     */
    @Test
    fun `the agent publishes its token on the decided device route`() {
        val post = method.getAnnotation(POST::class.java)
        assertNotNull("postPushToken must stay a POST", post)
        assertEquals(
            "the child agent must publish on the existing v1/devices/{id}/push-token route decided " +
                "for #319 (device-only, {token}, 204; server half PR #320) — repointing it at " +
                "v1/devices/{id}/push-token/self is not the decided contract and the token never " +
                "reaches Device.pushToken",
            "v1/devices/{id}/push-token",
            post!!.value,
        )
    }

    @Test
    fun `the device id is a path parameter, so the token cannot be written to another device's row`() {
        val pathParam = method.parameters.firstOrNull {
            it.isAnnotationPresent(retrofit2.http.Path::class.java)
        }
        assertNotNull("postPushToken must carry the device id as a path parameter", pathParam)
        assertEquals("id", pathParam!!.getAnnotation(retrofit2.http.Path::class.java)!!.value)
    }

    /**
     * The other half of the same contract (#319): the server's `PushTokenSchema` reads `token`
     * (`services/api/src/routes/devices.ts`, 20–4096 characters). The branch briefly named the field
     * `pushToken`, so a correct route and path still met a `400` on every upload.
     *
     * Mutant: rename the property to `pushToken` and this fails with `{"pushToken":"fcm-319"}` while
     * the path assertion above stays green — the two tests are independent halves of one wire contract.
     */
    @Test
    fun `the body field is the name the server's PushTokenSchema reads`() {
        val moshi = com.squareup.moshi.Moshi.Builder()
            .add(com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory())
            .build()
        val json = moshi.adapter(com.familyshield.agent.network.dto.PushTokenDto::class.java)
            .toJson(com.familyshield.agent.network.dto.PushTokenDto("fcm-319"))
        assertEquals(
            "the agent's body must match PushTokenSchema ({ token }) or the upload is a 400",
            """{"token":"fcm-319"}""",
            json,
        )
    }
}

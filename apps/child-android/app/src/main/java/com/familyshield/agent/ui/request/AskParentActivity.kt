package com.familyshield.agent.ui.request

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import com.familyshield.agent.R
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.ui.theme.OsraTheme
import dagger.hilt.android.AndroidEntryPoint
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * C-03 Ask a parent (#1179): standalone calm Compose activity for requesting +15 or +30 minutes
 * of whole-day screen time (G2/G3, no per-app scope, no child note per #1185, idempotent dedupe key).
 *
 * K31 #1196 findings addressed:
 * - Launched from C-02 `BlockActivity` when daily-limit extra time can be asked for.
 * - Sets `SENT` and writes the 2-hour pending preference ONLY after `api.postInternalAlert` succeeds;
 *   failures keep the screen retryable without latching the 2-hour window.
 * - Expired pending state clears automatically, and `clearPendingRequest` clears on unpair/re-pair.
 * - Isolates numeric minutes via `AskParentPolicy.ltrIsolate(...)` in both preview and pending strings.
 */
@AndroidEntryPoint
class AskParentActivity : ComponentActivity() {

    @Inject lateinit var api: ApiService
    @Inject lateinit var settings: AgentSettings
    @Inject lateinit var rules: RuleRepository

    private val sessionIdempotencyToken: String = UUID.randomUUID().toString()
    private var sendState by mutableStateOf(AskSendState.IDLE)
    private var uiCopy by mutableStateOf<AskParentCopy?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        requestWindowFeature(android.view.Window.FEATURE_NO_TITLE)
        super.onCreate(savedInstanceState)
        actionBar?.hide()
        WindowCompat.setDecorFitsSystemWindows(window, false)

        uiCopy = buildCopy()
        setContent {
            val darkTheme = isSystemInDarkTheme()
            SideEffect {
                val controller = WindowCompat.getInsetsController(window, window.decorView)
                controller.isAppearanceLightStatusBars = !darkTheme
                controller.isAppearanceLightNavigationBars = !darkTheme
            }
            OsraTheme.OsraTheme(darkTheme = darkTheme) {
                val currentCopy = uiCopy ?: buildCopy()
                AskParentScreen(
                    copy = currentCopy,
                    sendState = sendState,
                    onSend = { minutes -> sendRequest(minutes) },
                    onClose = { finish() },
                )
            }
        }
    }

    private fun buildCopy(): AskParentCopy {
        val isArabic = resources.configuration.locales[0]?.language == "ar"
        val adultNames = rules.cachedRules()?.adultNames.orEmpty()
        val adultsAddressing = AskParentPolicy.formatAdults(
            names = adultNames,
            fallback = getString(R.string.c03_adults_fallback_addressing),
            isArabic = isArabic,
        )
        val adultsSpeaking = AskParentPolicy.formatAdults(
            names = adultNames,
            fallback = getString(R.string.c03_adults_fallback_speaking),
            isArabic = isArabic,
        )
        val hasDailyLimit = (rules.cachedRules()?.screenTime?.dailyLimitMinutes ?: 0) > 0
        val pendingMinutes = pendingRequestMinutes()
        val pendingAtMs = pendingRequestSentAtMs()
        val nowMs = System.currentTimeMillis()
        val pendingActive = pendingMinutes != null &&
            pendingAtMs > 0L &&
            (nowMs - pendingAtMs) < PENDING_WINDOW_MS
        if (!pendingActive && (pendingMinutes != null || pendingAtMs > 0L)) {
            clearPendingRequest(this)
        }

        val options = listOf(
            AskDurationOptionUi(
                minutes = 15,
                eyebrow = getString(R.string.c03_option_15_eyebrow),
                amountLabel = getString(R.string.c03_option_15_amount),
                previewSentence = getString(
                    R.string.c03_preview_sentence,
                    AskParentPolicy.ltrIsolate("15"),
                ),
            ),
            AskDurationOptionUi(
                minutes = 30,
                eyebrow = getString(R.string.c03_option_30_eyebrow),
                amountLabel = getString(R.string.c03_option_30_amount),
                previewSentence = getString(
                    R.string.c03_preview_sentence,
                    AskParentPolicy.ltrIsolate("30"),
                ),
            ),
        )

        val sentTimeStr = if (pendingActive && pendingAtMs > 0L) {
            AskParentPolicy.ltrIsolate(
                Instant.ofEpochMilli(pendingAtMs)
                    .atZone(ZoneId.systemDefault())
                    .toLocalTime()
                    .format(HH_MM),
            )
        } else {
            AskParentPolicy.ltrIsolate(
                Instant.now().atZone(ZoneId.systemDefault()).toLocalTime().format(HH_MM),
            )
        }
        val isolatedPendingMins = AskParentPolicy.ltrIsolate((pendingMinutes ?: 15).toString())

        return AskParentCopy(
            title = getString(R.string.c03_title, adultsSpeaking),
            closeLabel = getString(R.string.c03_close),
            questionLabel = getString(R.string.c03_question_label),
            selectedBadge = getString(R.string.c03_selected_badge),
            options = options,
            previewEyebrow = getString(R.string.c03_preview_eyebrow, adultsAddressing),
            goesToLine = getString(R.string.c03_goes_to, adultsAddressing),
            sendButtonLabel = getString(R.string.c03_send_request),
            sendingButtonLabel = getString(R.string.c03_sending),
            sendFailedLine = getString(R.string.c03_send_failed),
            pendingTitle = getString(R.string.c03_pending_title, isolatedPendingMins),
            pendingWaitingBadge = getString(R.string.c03_waiting_reply),
            pendingSentLine = getString(R.string.c03_sent_to_line, adultsSpeaking, sentTimeStr),
            noDailyLimitLine = getString(R.string.c03_no_daily_limit),
            footerHonestNote = getString(R.string.c03_footer_honest),
            hasDailyLimit = hasDailyLimit,
            alreadyPending = pendingActive,
        )
    }

    private fun sendRequest(minutes: Int) {
        if (sendState == AskSendState.SENDING || sendState == AskSendState.SENT) return
        val normalized = AskParentPolicy.normalizeMinutes(minutes)
        val payload = AskParentPolicy.buildTimeRequest(
            requestedMinutes = normalized,
            idempotencyToken = sessionIdempotencyToken,
        )
        sendState = AskSendState.SENDING
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    api.postInternalAlert(
                        AlertDto(
                            childId = settings.childId(),
                            deviceId = settings.deviceId(),
                            severity = "info",
                            category = "app_blocked",
                            title = payload.title,
                            body = payload.body,
                            metadata = payload.metadata,
                            dedupeKey = payload.dedupeKey,
                        ),
                    )
                }
            }
            result.onSuccess {
                recordPendingRequest(normalized, System.currentTimeMillis())
                uiCopy = buildCopy()
                sendState = AskSendState.SENT
            }.onFailure { err ->
                Log.w(TAG, "C-03 time request POST failed; leaving retryable", err)
                sendState = AskSendState.FAILED
            }
        }
    }

    private fun prefs() = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun recordPendingRequest(minutes: Int, sentAtMs: Long) {
        prefs().edit()
            .putInt(KEY_PENDING_MINUTES, minutes)
            .putLong(KEY_PENDING_SENT_AT, sentAtMs)
            .apply()
    }

    private fun pendingRequestMinutes(): Int? {
        val v = prefs().getInt(KEY_PENDING_MINUTES, -1)
        return v.takeIf { it > 0 }
    }

    private fun pendingRequestSentAtMs(): Long = prefs().getLong(KEY_PENDING_SENT_AT, 0L)

    companion object {
        private const val TAG = "AskParentActivity"
        private const val PREFS_NAME = "osra_c03_request_v1"
        private const val KEY_PENDING_MINUTES = "pending_minutes"
        private const val KEY_PENDING_SENT_AT = "pending_sent_at_ms"
        private const val PENDING_WINDOW_MS = 2L * 60L * 60L * 1000L
        private val HH_MM: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm", Locale.US)

        fun intent(context: Context): Intent =
            Intent(context, AskParentActivity::class.java)

        fun clearPendingRequest(context: Context) {
            context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .apply()
        }
    }
}

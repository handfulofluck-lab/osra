package com.familyshield.agent.ui.request

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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

/**
 * C-03 Ask a parent (#1179): standalone calm Compose activity for requesting +15 or +30 minutes
 * of whole-day screen time (G2/G3, no per-app scope, no child note per #1185, idempotent dedupe key).
 */
@AndroidEntryPoint
class AskParentActivity : ComponentActivity() {

    @Inject lateinit var api: ApiService
    @Inject lateinit var settings: AgentSettings
    @Inject lateinit var rules: RuleRepository

    private val sessionIdempotencyToken: String = UUID.randomUUID().toString()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        val copy = buildCopy()
        setContent {
            OsraTheme.OsraTheme {
                AskParentScreen(
                    copy = copy,
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
        val pendingActive = pendingMinutes != null &&
            pendingAtMs > 0L &&
            (System.currentTimeMillis() - pendingAtMs) < PENDING_WINDOW_MS

        val options = listOf(
            AskDurationOptionUi(
                minutes = 15,
                eyebrow = getString(R.string.c03_option_15_eyebrow),
                amountLabel = getString(R.string.c03_option_15_amount),
                previewSentence = getString(R.string.c03_preview_sentence, 15),
            ),
            AskDurationOptionUi(
                minutes = 30,
                eyebrow = getString(R.string.c03_option_30_eyebrow),
                amountLabel = getString(R.string.c03_option_30_amount),
                previewSentence = getString(R.string.c03_preview_sentence, 30),
            ),
        )

        val sentTimeStr = if (pendingAtMs > 0L) {
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
            pendingTitle = getString(R.string.c03_pending_title, pendingMinutes ?: 15),
            pendingWaitingBadge = getString(R.string.c03_waiting_reply),
            pendingSentLine = getString(R.string.c03_sent_to_line, adultsSpeaking, sentTimeStr),
            noDailyLimitLine = getString(R.string.c03_no_daily_limit),
            footerHonestNote = getString(R.string.c03_footer_honest),
            hasDailyLimit = hasDailyLimit,
            alreadyPending = pendingActive,
        )
    }

    private fun sendRequest(minutes: Int) {
        val payload = AskParentPolicy.buildTimeRequest(
            requestedMinutes = minutes,
            idempotencyToken = sessionIdempotencyToken,
        )
        recordPendingRequest(AskParentPolicy.normalizeMinutes(minutes), System.currentTimeMillis())
        lifecycleScope.launch(Dispatchers.IO) {
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
        private const val PREFS_NAME = "osra_c03_request_v1"
        private const val KEY_PENDING_MINUTES = "pending_minutes"
        private const val KEY_PENDING_SENT_AT = "pending_sent_at_ms"
        private const val PENDING_WINDOW_MS = 2L * 60L * 60L * 1000L
        private val HH_MM: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm", Locale.US)

        fun intent(context: Context): Intent =
            Intent(context, AskParentActivity::class.java)
    }
}

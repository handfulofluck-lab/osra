package com.familyshield.agent.commands

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.NotificationManagerCompat
import com.familyshield.agent.R
import dagger.hilt.android.AndroidEntryPoint
import java.time.Instant
import javax.inject.Inject
import kotlinx.coroutines.delay

/**
 * ADR-0031, the child's half of the family witness: the full-screen notice carrying the 8-digit code
 * a locked-out parent types into the parent app.
 *
 * Shown by [CommandDispatcher] when a `show_reset_code` command arrives — the same
 * `startActivity(NEW_TASK)` idiom as [LockActivity] / [RingActivity], so it works while the app is in
 * the background. It restricts nothing (safe-direction under ADR-0019): Back and Close both leave, and
 * the notice never blocks the child from the rest of the phone.
 *
 * **The code is not persisted.** It lives in [ResetCodeState] only, is never put in an intent extra,
 * DataStore, Room, saved-instance state or a log. Process death loses it; the server row remains
 * `delivered` until an ack or the code's expiry clears it.
 *
 * **Expiry is the payload's own `expiresAt`**, checked once a second while the notice is composed —
 * not a hardcoded ten minutes and not a background timer, and the expired copy is shown only for a
 * notice this screen itself watched run out. **Withdrawal** comes from the existing command poll: the
 * API clears the payload, the same row is redelivered as `{}`, and [CommandDispatcher] clears
 * [ResetCodeState]. Withdrawal usually means the parent just used the code, so the notice simply
 * closes instead of telling the child to ask their parent to start again.
 *
 * **Ack is deferred** (see [CommandOutcome.Deferred]): the row stays `delivered` while the notice is
 * up, so a withdrawal can still reach the device on the 120-second redelivery. It is acked `ok` when
 * the notice ends — `detail.screen = expired|dismissed` — or by the dispatcher as `withdrawn`. Acking
 * at display time would clear the payload server-side before the parent had read it and would stop
 * the redelivery that carries the withdrawal. The ack goes through [CommandDispatcher.ackResetCode],
 * which owns the application scope and the log-once rule, rather than a second ack path here.
 */
@AndroidEntryPoint
class ResetCodeActivity : ComponentActivity() {

    @Inject lateinit var dispatcher: CommandDispatcher

    /** Command ids already acked by this instance; the same row can be redelivered every 120 s. */
    private val ackedCommandIds = mutableSetOf<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        // The notice is harmless but time-sensitive: wake a dimmed screen so the parent can read it.
        // Deliberately no showWhenLocked / FLAG_SHOW_WHEN_LOCKED — issue #87's lesson is that drawing
        // over the keyguard hides the owner's PIN pad. The screen starts behind the keyguard instead.
        window.addFlags(WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)

        if (ResetCodeState.notice.value == null) {
            // Nothing to show (already withdrawn, expired or dismissed): do not sit on a blank screen.
            finish()
            return
        }

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() = closeAndFinish()
            },
        )

        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize(), color = Color(0xFF131318)) {
                    ResetCodeScreen(
                        onExpired = { notice ->
                            acknowledge(notice, ResetCodeEnd.EXPIRED)
                            ResetCodeState.clearIfCurrent(notice.requestId)
                            cancelResetCodeNotification()
                        },
                        onWithdrawn = ::finish,
                        onClose = ::closeAndFinish,
                    )
                }
            }
        }
    }

    /** Close/Back: the notice is safe-direction, so leaving is allowed; the row is acked dismiss. */
    private fun closeAndFinish() {
        ResetCodeState.notice.value?.let { notice ->
            acknowledge(notice, ResetCodeEnd.DISMISSED)
            ResetCodeState.clearIfCurrent(notice.requestId)
        }
        cancelResetCodeNotification()
        finish()
    }

    /**
     * One ack per command row. `ok` means the notice was on screen (see [CommandAckPolicy]) and
     * `detail.screen` says how it ended. A lost ack is logged once and not retried (see
     * [CommandAckSender]): the row stays `delivered`, the row's expiry still clears the payload, and
     * issue #231's rule is not bent here. The code itself is never logged.
     */
    private fun acknowledge(notice: ResetCodeNotice, end: ResetCodeEnd) {
        val commandId = notice.commandId ?: return
        if (!ackedCommandIds.add(commandId)) return
        dispatcher.ackResetCode(commandId, end)
    }

    /** The notification is a lock-screen hint, not a second notice: it goes when this one does. */
    private fun cancelResetCodeNotification() {
        runCatching {
            NotificationManagerCompat.from(this).cancel(CommandDispatcher.RESET_CODE_NOTIFICATION_ID)
        }
    }
}

/** One-second tick: expiry follows `expiresAt` even if the device clock is changed. */
private const val RESET_CODE_TICK_MS = 1_000L

@Composable
private fun ResetCodeScreen(
    onExpired: (ResetCodeNotice) -> Unit,
    onWithdrawn: () -> Unit,
    onClose: () -> Unit,
) {
    val notice by ResetCodeState.notice.collectAsState()
    var now by remember { mutableStateOf(Instant.now()) }
    // Set only by this screen's own expiry tick, so a notice that disappears for any other reason
    // (witness passed, request superseded or cancelled) is told apart from one that ran out.
    var expiredHere by remember { mutableStateOf(false) }

    LaunchedEffect(notice?.requestId) {
        val current = notice ?: return@LaunchedEffect
        expiredHere = false
        while (true) {
            val at = Instant.now()
            now = at
            if (ResetCodePolicy.isExpired(current.expiresAt, at)) {
                expiredHere = true
                onExpired(current)
                break
            }
            delay(RESET_CODE_TICK_MS)
        }
    }

    if (ResetCodePolicy.viewOf(notice, expiredHere) == ResetCodeView.CLOSED) {
        // Withdrawn: the code is dead server-side, most often because the parent just used it, so
        // "ask your parent to start again" would be wrong. The notice simply closes.
        LaunchedEffect(Unit) { onWithdrawn() }
        return
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (notice == null) {
            Text(
                text = stringResource(R.string.reset_code_expired_title),
                style = MaterialTheme.typography.headlineSmall,
                color = Color.White,
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = stringResource(R.string.reset_code_expired_body),
                style = MaterialTheme.typography.bodyLarge,
                color = Color(0xFFAEB0B8),
                textAlign = TextAlign.Center,
            )
        } else {
            val current = notice!!
            Text(
                text = stringResource(R.string.reset_code_title),
                style = MaterialTheme.typography.headlineSmall,
                color = Color.White,
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = if (current.parentName.isEmpty()) {
                    stringResource(R.string.reset_code_intro_unnamed)
                } else {
                    stringResource(R.string.reset_code_intro, current.parentName)
                },
                style = MaterialTheme.typography.bodyLarge,
                color = Color(0xFFD6D7DD),
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = Modifier.height(28.dp))
            Text(
                text = ResetCodePolicy.formatCode(current.code),
                // `1234 5678` has no strong character to fix its direction, so an Arabic (RTL)
                // paragraph would reorder the two digit runs. The code is a number, always LTR.
                style = LocalTextStyle.current.copy(textDirection = TextDirection.Ltr),
                fontSize = 40.sp,
                lineHeight = 48.sp,
                letterSpacing = 4.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                color = Color.White,
                maxLines = 1,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 320.dp),
            )
            Spacer(modifier = Modifier.height(10.dp))
            val minutes = ResetCodePolicy.remainingMinutes(current.expiresAt, now)
            Text(
                text = pluralStringResource(R.plurals.reset_code_valid_for, minutes, minutes),
                style = MaterialTheme.typography.titleMedium,
                color = Color(0xFF9AD1A0),
            )
            Spacer(modifier = Modifier.height(28.dp))
            Text(
                text = stringResource(R.string.reset_code_instruction),
                style = MaterialTheme.typography.titleMedium,
                color = Color.White,
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = stringResource(R.string.reset_code_safety),
                style = MaterialTheme.typography.bodyMedium,
                color = Color(0xFFAEB0B8),
                textAlign = TextAlign.Center,
            )
        }
        Spacer(modifier = Modifier.height(32.dp))
        TextButton(onClick = onClose) {
            Text(text = stringResource(R.string.reset_code_close), color = Color.White)
        }
    }
}

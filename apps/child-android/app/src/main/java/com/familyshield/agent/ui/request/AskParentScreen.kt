package com.familyshield.agent.ui.request

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import com.familyshield.agent.R
import com.familyshield.agent.ui.theme.OsraTheme
import com.familyshield.agent.ui.theme.OsraTokens

/** One selectable duration tile on C-03 (+15 min or +30 min). */
data class AskDurationOptionUi(
    val minutes: Int,
    val amountLabel: String,
    val previewSentence: String,
)

/** U84 (#650): pure visual and TalkBack-semantics contract for a C-03 duration chip. */
internal data class DurationTilePresentation(
    val showCheckIcon: Boolean,
    val announceSelected: Boolean,
)

internal fun durationTilePresentation(selected: Boolean): DurationTilePresentation =
    DurationTilePresentation(
        showCheckIcon = selected,
        announceSelected = selected,
    )

/** Localised copy for C-03 Ask a parent (#1179). Every string is resolved from XML resources. */
data class AskParentCopy(
    val title: String,
    val closeLabel: String,
    val questionLabel: String,
    val options: List<AskDurationOptionUi>,
    val previewEyebrow: String,
    val goesToLine: String,
    val sendButtonLabel: String,
    val sendingButtonLabel: String,
    val sendFailedLine: String,
    val pendingTitle: String,
    val pendingWaitingBadge: String,
    val pendingSentLine: String,
    val noDailyLimitLine: String,
    val footerHonestNote: String,
    val hasDailyLimit: Boolean,
    val alreadyPending: Boolean,
)

/**
 * C-03 Ask a parent (#1179).
 *
 * Calm, two-tap screen for a child using OSRA design tokens exclusively (`LocalOsraPalette`,
 * `LocalOsraRadii`, `OsraTokens.spaces`, light + dark, RTL mirror, 320 px / 200% responsive):
 * - Big duration tiles (+15 min, +30 min — whole-day screen time only per G3; no +1 h per Codex 7193611894).
 * - Live preview card showing the exact sentence parents will see + named recipients ("Goes to {adults}").
 * - No free-text note field (#1185), no "online" presence claim, no voice-note button.
 * - One request at a time: if a request is already pending (or just sent), shows the calm waiting
 *   state instead of allowing duplicate sends.
 */
@Composable
fun AskParentScreen(
    copy: AskParentCopy,
    sendState: AskSendState = AskSendState.IDLE,
    onSend: (Int) -> Unit,
    onClose: () -> Unit,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val spaces = OsraTokens.spaces
    val fontScale = LocalDensity.current.fontScale

    val defaultMinutes = copy.options.firstOrNull()?.minutes ?: 15
    var selectedMinutes by remember { mutableIntStateOf(defaultMinutes) }

    val activeOption = copy.options.firstOrNull { it.minutes == selectedMinutes } ?: copy.options.first()
    val hasPending = copy.alreadyPending || sendState == AskSendState.SENT
    val isSending = sendState == AskSendState.SENDING
    val canSend = AskParentPolicy.canSend(
        hasDailyLimit = copy.hasDailyLimit,
        hasPendingWaiting = hasPending,
        isSending = isSending,
    )

    val cardShape = RoundedCornerShape(radii.card)
    val controlShape = RoundedCornerShape(radii.control)
    val cardBorder = if (palette.cardBorder == OsraTheme.Transparent) {
        null
    } else {
        BorderStroke(1.dp, palette.cardBorder)
    }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = palette.page,
        contentColor = palette.ink,
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            val compact = maxWidth < 360.dp || fontScale >= 1.5f
            val viewportHeight = maxHeight

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .heightIn(min = viewportHeight)
                    .padding(horizontal = spaces.lg, vertical = if (compact) spaces.md else spaces.lg),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(if (compact) spaces.md else spaces.lg),
                ) {
                    // Top bar: title + close button (>= 48 dp).
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = copy.title,
                            modifier = Modifier.weight(1f).padding(end = spaces.sm),
                            style = MaterialTheme.typography.headlineSmall.copy(
                                textDirection = TextDirection.Content,
                            ),
                            color = palette.ink,
                        )
                        TextButton(
                            onClick = onClose,
                            modifier = Modifier.heightIn(min = 48.dp),
                        ) {
                            Text(
                                text = copy.closeLabel,
                                style = MaterialTheme.typography.labelLarge.copy(
                                    textDirection = TextDirection.Content,
                                ),
                                color = palette.primary,
                            )
                        }
                    }

                    if (hasPending) {
                        // One request at a time: show the calm waiting card when already pending or sent.
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = cardShape,
                            color = palette.warnContainer,
                            contentColor = palette.onWarnContainer,
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(spaces.lg),
                                verticalArrangement = Arrangement.spacedBy(spaces.sm),
                            ) {
                                Text(
                                    text = copy.pendingTitle,
                                    style = MaterialTheme.typography.titleMedium.copy(
                                        textDirection = TextDirection.Content,
                                    ),
                                )
                                Text(
                                    text = copy.pendingSentLine,
                                    style = MaterialTheme.typography.bodySmall.copy(
                                        textDirection = TextDirection.Content,
                                    ),
                                )
                                Surface(
                                    shape = controlShape,
                                    color = palette.card,
                                    contentColor = palette.warn,
                                ) {
                                    Text(
                                        text = copy.pendingWaitingBadge,
                                        modifier = Modifier.padding(horizontal = spaces.md, vertical = spaces.xs),
                                        style = MaterialTheme.typography.labelMedium.copy(
                                            fontWeight = FontWeight.SemiBold,
                                            textDirection = TextDirection.Content,
                                        ),
                                    )
                                }
                            }
                        }
                    } else if (!copy.hasDailyLimit) {
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = cardShape,
                            color = palette.card,
                            border = cardBorder,
                        ) {
                            Text(
                                text = copy.noDailyLimitLine,
                                modifier = Modifier.padding(spaces.lg),
                                style = MaterialTheme.typography.bodyMedium.copy(
                                    textDirection = TextDirection.Content,
                                ),
                                color = palette.muted,
                            )
                        }
                    } else {
                        // Section eyebrow: "How much more time?"
                        Text(
                            text = copy.questionLabel,
                            style = MaterialTheme.typography.labelMedium.copy(
                                fontWeight = FontWeight.SemiBold,
                                textDirection = TextDirection.Content,
                            ),
                            color = palette.muted,
                        )

                        // Big selectable tiles (+15 min, +30 min; stacks cleanly at 320px/200%).
                        if (compact) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .selectableGroup(),
                                verticalArrangement = Arrangement.spacedBy(spaces.sm),
                            ) {
                                copy.options.forEach { option ->
                                    DurationTile(
                                        option = option,
                                        selected = option.minutes == selectedMinutes,
                                        shape = cardShape,
                                        modifier = Modifier.fillMaxWidth(),
                                        onClick = { selectedMinutes = option.minutes },
                                    )
                                }
                            }
                        } else {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .selectableGroup(),
                                horizontalArrangement = Arrangement.spacedBy(spaces.md),
                            ) {
                                copy.options.forEach { option ->
                                    DurationTile(
                                        option = option,
                                        selected = option.minutes == selectedMinutes,
                                        shape = cardShape,
                                        modifier = Modifier.weight(1f),
                                        onClick = { selectedMinutes = option.minutes },
                                    )
                                }
                            }
                        }

                        // Preview card: exact sentence parents will see + "Goes to {adults}".
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = cardShape,
                            color = palette.tint,
                            border = cardBorder,
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(spaces.lg),
                                verticalArrangement = Arrangement.spacedBy(spaces.sm),
                            ) {
                                Text(
                                    text = copy.previewEyebrow,
                                    style = MaterialTheme.typography.labelMedium.copy(
                                        fontWeight = FontWeight.SemiBold,
                                        textDirection = TextDirection.Content,
                                    ),
                                    color = palette.muted,
                                )
                                Text(
                                    text = activeOption.previewSentence,
                                    style = MaterialTheme.typography.titleMedium.copy(
                                        textDirection = TextDirection.Content,
                                    ),
                                    color = palette.ink,
                                )
                                Text(
                                    text = copy.goesToLine,
                                    style = MaterialTheme.typography.bodySmall.copy(
                                        textDirection = TextDirection.Content,
                                    ),
                                    color = palette.muted,
                                )
                            }
                        }
                    }
                }

                // Bottom CTA + honest footer (B2 #1196: navigationBarsPadding + bottom clearance so
                // the second line of footerHonestNote always clears the gesture bar at 320 px / 200%).
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(
                            top = if (compact) spaces.md else spaces.xl,
                            bottom = spaces.lg,
                        ),
                    verticalArrangement = Arrangement.spacedBy(spaces.sm),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    if (!hasPending && copy.hasDailyLimit) {
                        if (sendState == AskSendState.FAILED) {
                            Surface(
                                modifier = Modifier.fillMaxWidth(),
                                shape = controlShape,
                                color = palette.warnContainer,
                                contentColor = palette.onWarnContainer,
                            ) {
                                Text(
                                    text = copy.sendFailedLine,
                                    modifier = Modifier.padding(horizontal = spaces.md, vertical = spaces.sm),
                                    style = MaterialTheme.typography.bodySmall.copy(
                                        textDirection = TextDirection.Content,
                                    ),
                                    textAlign = TextAlign.Center,
                                )
                            }
                        }
                        Button(
                            onClick = {
                                if (canSend) {
                                    onSend(activeOption.minutes)
                                }
                            },
                            enabled = canSend,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = OsraTokens.sizes.primaryButtonHeight),
                            shape = controlShape,
                            colors = ButtonDefaults.buttonColors(
                                containerColor = palette.primary,
                                contentColor = palette.onPrimary,
                            ),
                        ) {
                            Text(
                                text = if (isSending) copy.sendingButtonLabel else copy.sendButtonLabel,
                                style = MaterialTheme.typography.labelLarge.copy(
                                    textDirection = TextDirection.Content,
                                ),
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                    Text(
                        text = copy.footerHonestNote,
                        style = MaterialTheme.typography.bodySmall.copy(
                            textDirection = TextDirection.Content,
                        ),
                        color = palette.muted,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

@Composable
private fun DurationTile(
    option: AskDurationOptionUi,
    selected: Boolean,
    shape: RoundedCornerShape,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val spaces = OsraTokens.spaces
    val presentation = durationTilePresentation(selected)
    val border = if (selected) {
        BorderStroke(2.dp, palette.primary)
    } else {
        BorderStroke(1.dp, palette.border)
    }

    Surface(
        modifier = modifier
            .heightIn(min = 68.dp)
            .clip(shape)
            .selectable(
                selected = presentation.announceSelected,
                role = Role.RadioButton,
                onClick = onClick,
            ),
        shape = shape,
        color = if (selected) palette.tint else palette.card,
        border = border,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(spaces.lg),
            horizontalArrangement = Arrangement.spacedBy(spaces.sm, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (presentation.showCheckIcon) {
                Icon(
                    painter = painterResource(id = R.drawable.ic_check_24),
                    contentDescription = null,
                    tint = palette.primary,
                    modifier = Modifier.size(20.dp),
                )
            }
            Text(
                text = option.amountLabel,
                style = MaterialTheme.typography.titleLarge.copy(
                    fontWeight = FontWeight.Bold,
                    textDirection = TextDirection.Content,
                ),
                color = palette.ink,
            )
        }
    }
}

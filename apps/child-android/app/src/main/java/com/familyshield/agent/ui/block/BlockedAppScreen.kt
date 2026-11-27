package com.familyshield.agent.ui.block

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import com.familyshield.agent.ui.theme.OsraTheme
import com.familyshield.agent.ui.theme.OsraTokens

/** One app entry inside the C-02 "Still open for you" card. */
data class StillOpenAppUi(
    val packageId: String?,
    val label: String,
    val badge: String,
)

/** Localised copy for C-02 Time's up / blocked (#1179). Every string is resolved from XML resources. */
data class BlockedAppCopy(
    val brandLabel: String,
    val reasonPill: String,
    val monogram: String,
    val headline: String,
    val subtitle: String,
    val backAgainLabel: String,
    val backAtValue: String?,
    val stillOpenLabel: String,
    val stillOpenApps: List<StillOpenAppUi>,
    val primaryRequestLabel: String,
    val requestSentTitle: String,
    val requestWaitingLine: String,
    val callParentLabel: String,
    val seeMyRulesLabel: String,
    val sendSosLabel: String,
    val exitHomeLabel: String,
    val emergencyNote: String,
    val rulesSheetTitle: String,
    val rulesSheetLines: List<String>,
    val rulesSheetEmpty: String,
    val rulesSheetClose: String,
)

/**
 * C-02 Time's up / app blocked screen (#1179).
 *
 * Calm, honest full screen using OSRA design tokens (light + dark), supporting 320 px / 200% font
 * scale via scrolling and responsive stacking, with:
 * - exact rule reason pill + paused headline + factual subtitle (never generic "Time's up"),
 * - "Back again" card only when a deterministic return time exists (later of all active rules),
 * - "Still open for you" list (always-allowed apps + Messages and calls),
 * - G3-compliant primary CTA ("Ask for 15 more minutes of screen time" for daily limit only;
 *   "Ask to open {app}" for every other reason),
 * - "Call a parent" + "See my rules" (in-screen rules summary sheet),
 * - calm outlined "Send SOS to my parents" row (Build Condition 5 / Karim 26 Nov 10:27 — never red),
 * - "Exit to Home screen" + plain "Emergency calls always work" note.
 */
@Composable
fun BlockedAppScreen(
    copy: BlockedAppCopy,
    onPrimaryRequest: () -> Unit,
    onOpenAllowedApp: (String?) -> Unit,
    onCallParent: () -> Unit,
    onSendSos: () -> Unit,
    onExitHome: () -> Unit,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val spaces = OsraTokens.spaces
    val fontScale = LocalDensity.current.fontScale

    var requestSent by remember { mutableStateOf(false) }
    var showRulesDialog by remember { mutableStateOf(false) }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = palette.page,
        contentColor = palette.ink,
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing),
        ) {
            val compactLayout = maxWidth < 360.dp || fontScale >= 1.5f
            val viewportHeight = maxHeight
            val cardShape = RoundedCornerShape(radii.card)
            val controlShape = RoundedCornerShape(radii.control)
            val cardBorder = if (palette.cardBorder == OsraTheme.Transparent) {
                null
            } else {
                BorderStroke(1.dp, palette.cardBorder)
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .heightIn(min = viewportHeight)
                    .padding(horizontal = spaces.lg, vertical = spaces.lg),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(spaces.lg),
                ) {
                    // Top bar: brand wordmark + exact reason pill (stacks gracefully on 320px/200%).
                    if (compactLayout) {
                        Column(
                            modifier = Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(spaces.sm),
                        ) {
                            Text(
                                text = copy.brandLabel,
                                style = MaterialTheme.typography.titleMedium.copy(
                                    fontWeight = FontWeight.Bold,
                                    textDirection = TextDirection.Content,
                                ),
                                color = palette.primary,
                            )
                            ReasonPill(text = copy.reasonPill)
                        }
                    } else {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = copy.brandLabel,
                                style = MaterialTheme.typography.titleMedium.copy(
                                    fontWeight = FontWeight.Bold,
                                    textDirection = TextDirection.Content,
                                ),
                                color = palette.primary,
                            )
                            ReasonPill(text = copy.reasonPill)
                        }
                    }

                    // Calm hero: monogram badge + paused headline + factual subtitle.
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = spaces.xs),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(spaces.sm),
                    ) {
                        Box(
                            modifier = Modifier
                                .size(56.dp)
                                .clip(cardShape)
                                .background(palette.tint),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = copy.monogram,
                                style = MaterialTheme.typography.headlineSmall.copy(
                                    fontWeight = FontWeight.Bold,
                                ),
                                color = palette.primary,
                            )
                        }
                        Text(
                            text = copy.headline,
                            style = MaterialTheme.typography.headlineMedium.copy(
                                textDirection = TextDirection.Content,
                            ),
                            color = palette.ink,
                            textAlign = TextAlign.Center,
                        )
                        Text(
                            text = copy.subtitle,
                            style = MaterialTheme.typography.bodyMedium.copy(
                                textDirection = TextDirection.Content,
                            ),
                            color = palette.muted,
                            textAlign = TextAlign.Center,
                        )
                    }

                    // Card 1: "Back again" — shown only when a deterministic return time exists.
                    if (!copy.backAtValue.isNullOrBlank()) {
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = cardShape,
                            color = palette.card,
                            border = cardBorder,
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(spaces.lg),
                                verticalArrangement = Arrangement.spacedBy(spaces.xs),
                            ) {
                                Text(
                                    text = copy.backAgainLabel,
                                    style = MaterialTheme.typography.labelMedium.copy(
                                        fontWeight = FontWeight.SemiBold,
                                        textDirection = TextDirection.Content,
                                    ),
                                    color = palette.muted,
                                )
                                Text(
                                    text = copy.backAtValue,
                                    style = MaterialTheme.typography.titleMedium.copy(
                                        textDirection = TextDirection.Content,
                                    ),
                                    color = palette.ink,
                                )
                            }
                        }
                    }

                    // Card 2: "Still open for you" — always-allowed apps + Messages and calls.
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        shape = cardShape,
                        color = palette.card,
                        border = cardBorder,
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(spaces.lg),
                            verticalArrangement = Arrangement.spacedBy(spaces.sm),
                        ) {
                            Text(
                                text = copy.stillOpenLabel,
                                style = MaterialTheme.typography.labelMedium.copy(
                                    fontWeight = FontWeight.SemiBold,
                                    textDirection = TextDirection.Content,
                                ),
                                color = palette.muted,
                            )
                            copy.stillOpenApps.forEachIndexed { index, item ->
                                if (index > 0) {
                                    HorizontalDivider(color = palette.line, thickness = 1.dp)
                                }
                                StillOpenRow(
                                    item = item,
                                    stacked = fontScale >= 1.6f,
                                    onClick = { onOpenAllowedApp(item.packageId) },
                                )
                            }
                        }
                    }
                }

                // Bottom action stack: Primary CTA -> Call/Rules -> Calm SOS row -> Exit + emergency note.
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = spaces.xl),
                    verticalArrangement = Arrangement.spacedBy(spaces.md),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    if (requestSent) {
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = controlShape,
                            color = palette.tint,
                            border = BorderStroke(1.dp, palette.ok),
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = spaces.lg, vertical = spaces.md),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(spaces.xxs),
                            ) {
                                Text(
                                    text = copy.requestSentTitle,
                                    style = MaterialTheme.typography.labelLarge.copy(
                                        textDirection = TextDirection.Content,
                                    ),
                                    color = palette.ok,
                                    textAlign = TextAlign.Center,
                                )
                                Text(
                                    text = copy.requestWaitingLine,
                                    style = MaterialTheme.typography.bodySmall.copy(
                                        textDirection = TextDirection.Content,
                                    ),
                                    color = palette.muted,
                                    textAlign = TextAlign.Center,
                                )
                            }
                        }
                    } else {
                        Button(
                            onClick = {
                                onPrimaryRequest()
                                requestSent = true
                            },
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
                                text = copy.primaryRequestLabel,
                                style = MaterialTheme.typography.labelLarge.copy(
                                    textDirection = TextDirection.Content,
                                ),
                                textAlign = TextAlign.Center,
                            )
                        }
                    }

                    // Secondary actions: Call a parent + See my rules (stacked on narrow/200%).
                    if (compactLayout) {
                        Column(
                            modifier = Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(spaces.sm),
                        ) {
                            SecondaryActionButton(
                                label = copy.callParentLabel,
                                shape = controlShape,
                                modifier = Modifier.fillMaxWidth(),
                                onClick = onCallParent,
                            )
                            SecondaryActionButton(
                                label = copy.seeMyRulesLabel,
                                shape = controlShape,
                                modifier = Modifier.fillMaxWidth(),
                                onClick = { showRulesDialog = true },
                            )
                        }
                    } else {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(spaces.sm),
                        ) {
                            SecondaryActionButton(
                                label = copy.callParentLabel,
                                shape = controlShape,
                                modifier = Modifier.weight(1f),
                                onClick = onCallParent,
                            )
                            SecondaryActionButton(
                                label = copy.seeMyRulesLabel,
                                shape = controlShape,
                                modifier = Modifier.weight(1f),
                                onClick = { showRulesDialog = true },
                            )
                        }
                    }

                    // Calm SOS row (Build Condition 5 / F5, Karim 26 Nov 10:27 — NEVER a red button).
                    OutlinedButton(
                        onClick = onSendSos,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp),
                        shape = controlShape,
                        border = BorderStroke(1.dp, palette.border),
                        colors = ButtonDefaults.outlinedButtonColors(
                            containerColor = palette.card,
                            contentColor = palette.ink,
                        ),
                    ) {
                        Text(
                            text = copy.sendSosLabel,
                            style = MaterialTheme.typography.labelLarge.copy(
                                textDirection = TextDirection.Content,
                            ),
                            textAlign = TextAlign.Center,
                        )
                    }

                    TextButton(
                        onClick = onExitHome,
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) {
                        Text(
                            text = copy.exitHomeLabel,
                            style = MaterialTheme.typography.labelLarge.copy(
                                textDirection = TextDirection.Content,
                            ),
                            color = palette.primary,
                            textAlign = TextAlign.Center,
                        )
                    }

                    Text(
                        text = copy.emergencyNote,
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

    if (showRulesDialog) {
        AlertDialog(
            onDismissRequest = { showRulesDialog = false },
            containerColor = palette.card,
            titleContentColor = palette.ink,
            textContentColor = palette.ink,
            title = {
                Text(
                    text = copy.rulesSheetTitle,
                    style = MaterialTheme.typography.titleMedium.copy(
                        textDirection = TextDirection.Content,
                    ),
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(spaces.sm)) {
                    if (copy.rulesSheetLines.isEmpty()) {
                        Text(
                            text = copy.rulesSheetEmpty,
                            style = MaterialTheme.typography.bodyMedium.copy(
                                textDirection = TextDirection.Content,
                            ),
                            color = palette.muted,
                        )
                    } else {
                        copy.rulesSheetLines.forEach { line ->
                            Text(
                                text = line,
                                style = MaterialTheme.typography.bodyMedium.copy(
                                    textDirection = TextDirection.Content,
                                ),
                                color = palette.ink,
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = { showRulesDialog = false },
                    modifier = Modifier.heightIn(min = 48.dp),
                ) {
                    Text(
                        text = copy.rulesSheetClose,
                        color = palette.primary,
                    )
                }
            },
        )
    }
}

@Composable
private fun ReasonPill(text: String) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val spaces = OsraTokens.spaces
    Surface(
        shape = RoundedCornerShape(radii.control),
        color = palette.warnContainer,
        contentColor = palette.onWarnContainer,
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(horizontal = spaces.md, vertical = spaces.xs),
            style = MaterialTheme.typography.bodySmall.copy(
                fontWeight = FontWeight.SemiBold,
                textDirection = TextDirection.Content,
            ),
        )
    }
}

@Composable
private fun StillOpenRow(
    item: StillOpenAppUi,
    stacked: Boolean,
    onClick: () -> Unit,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val spaces = OsraTokens.spaces
    val rowModifier = Modifier
        .fillMaxWidth()
        .heightIn(min = 48.dp)
        .clip(RoundedCornerShape(radii.control))
        .clickable(onClick = onClick)
        .padding(vertical = spaces.xs)

    if (stacked) {
        Column(
            modifier = rowModifier,
            verticalArrangement = Arrangement.spacedBy(spaces.xs),
        ) {
            Text(
                text = item.label,
                style = MaterialTheme.typography.titleSmall.copy(
                    textDirection = TextDirection.Content,
                ),
                color = palette.ink,
            )
            AlwaysOpenPill(text = item.badge)
        }
    } else {
        Row(
            modifier = rowModifier,
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = item.label,
                modifier = Modifier
                    .weight(1f)
                    .padding(end = spaces.sm),
                style = MaterialTheme.typography.titleSmall.copy(
                    textDirection = TextDirection.Content,
                ),
                color = palette.ink,
            )
            AlwaysOpenPill(text = item.badge)
        }
    }
}

@Composable
private fun AlwaysOpenPill(text: String) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val spaces = OsraTokens.spaces
    Surface(
        shape = RoundedCornerShape(radii.control),
        color = palette.tint,
        contentColor = palette.ok,
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(horizontal = spaces.sm, vertical = spaces.xs),
            style = MaterialTheme.typography.labelMedium.copy(
                fontWeight = FontWeight.SemiBold,
                textDirection = TextDirection.Content,
            ),
        )
    }
}

@Composable
private fun SecondaryActionButton(
    label: String,
    shape: RoundedCornerShape,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.heightIn(min = 48.dp),
        shape = shape,
        border = BorderStroke(1.dp, palette.border),
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = palette.raised,
            contentColor = palette.ink,
        ),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge.copy(
                textDirection = TextDirection.Content,
            ),
            textAlign = TextAlign.Center,
        )
    }
}

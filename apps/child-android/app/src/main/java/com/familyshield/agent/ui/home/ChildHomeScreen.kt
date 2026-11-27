package com.familyshield.agent.ui.home

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import com.familyshield.agent.ui.theme.OsraTheme
import com.familyshield.agent.ui.theme.OsraTokens

/** The three child tabs on C-01 (#1179). */
enum class ChildHomeTab { TODAY, REQUESTS, MESSAGES }

/** One decision item shown in the C-01 Messages tab / Today latest preview (G10). */
data class ChildDecisionItemUi(
    val title: String,
    val subtitle: String,
    val badge: String,
)

/** One per-app activity total shown inside the "My activity" dialog. */
data class ChildActivityItemUi(
    val appName: String,
    val durationText: String,
)

/** Full localised view model for C-01 Child home + C-01-RTL (#1179). */
data class ChildHomeCopy(
    val avatarInitial: String,
    val headerTitle: String,
    val callParentLabel: String,
    val windDownBanner: String?,
    val hasDailyLimit: Boolean,
    val ringNumber: String,
    val ringUnit: String,
    val ringFraction: Float,
    val timeLeftHeadline: String,
    val usedOfLimitLine: String,
    val askMoreTimeLabel: String,
    val nextLabel: String,
    val nextRoutineLine: String,
    val bedtimeLabel: String,
    val bedtimeValue: String?,
    val pendingTitle: String?,
    val pendingSentLine: String?,
    val pendingBadge: String?,
    val pendingIsWaiting: Boolean,
    val latestSectionLabel: String,
    val seeAllLabel: String,
    val latestDecision: ChildDecisionItemUi?,
    val whatAdultsSeeTitle: String,
    val whatAdultsSeeSubtitle: String,
    val myActivityTitle: String,
    val myActivitySubtitle: String,
    val openLabel: String,
    val sendSosLabel: String,
    val tabTodayLabel: String,
    val tabRequestsLabel: String,
    val tabMessagesLabel: String,
    val requestsHeaderTitle: String,
    val requestsGoesToLine: String,
    val request15Label: String,
    val request30Label: String,
    val requestsDisabledLine: String,
    val requestFailedLine: String = "",
    val messagesHeaderTitle: String,
    val messagesEmptyLine: String,
    val allDecisions: List<ChildDecisionItemUi>,
    val transparencyLines: List<String>,
    val openDeviceSetupLabel: String,
    val activityItems: List<ChildActivityItemUi>,
    val activityEmptyLine: String,
    val dialogCloseLabel: String,
)

/**
 * C-01 Child home + C-01-RTL (#1179).
 *
 * Uses OSRA tokens exclusively (`LocalOsraPalette`, `LocalOsraRadii`, `OsraTokens.spaces`),
 * adapts seamlessly to light/dark and RTL mirroring, supports 320 px / 200% font scale via
 * scrolling and responsive stacking, keeps 48 dp+ touch targets, hides "note from parents" (G10),
 * uses the shared G5 ring formula, and keeps SOS as a calm outlined row (never red — F5).
 */
@Composable
fun ChildHomeScreen(
    copy: ChildHomeCopy,
    onCallParent: () -> Unit,
    onRequestMoreTime: (Int) -> Unit,
    onSendSos: () -> Unit,
    onOpenDeviceSetup: () -> Unit,
    requestSendState: TimeRequestSendState = TimeRequestSendState.IDLE,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val spaces = OsraTokens.spaces
    val fontScale = LocalDensity.current.fontScale

    var activeTab by remember { mutableStateOf(ChildHomeTab.TODAY) }
    var showTransparencyDialog by remember { mutableStateOf(false) }
    var showActivityDialog by remember { mutableStateOf(false) }

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
        Column(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing),
        ) {
            BoxWithConstraints(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                val compact = maxWidth < 360.dp || fontScale >= 1.5f
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = spaces.lg, vertical = spaces.lg),
                    verticalArrangement = Arrangement.spacedBy(spaces.lg),
                ) {
                    when (activeTab) {
                        ChildHomeTab.TODAY -> TodayTabContent(
                            copy = copy,
                            compact = compact,
                            cardShape = cardShape,
                            controlShape = controlShape,
                            cardBorder = cardBorder,
                            onCallParent = onCallParent,
                            onAskMoreTime = { activeTab = ChildHomeTab.REQUESTS },
                            onSeeAllMessages = { activeTab = ChildHomeTab.MESSAGES },
                            onOpenTransparency = { showTransparencyDialog = true },
                            onOpenActivity = { showActivityDialog = true },
                            onSendSos = onSendSos,
                        )
                        ChildHomeTab.REQUESTS -> RequestsTabContent(
                            copy = copy,
                            compact = compact,
                            cardShape = cardShape,
                            controlShape = controlShape,
                            cardBorder = cardBorder,
                            requestSendState = requestSendState,
                            onRequestMoreTime = onRequestMoreTime,
                        )
                        ChildHomeTab.MESSAGES -> MessagesTabContent(
                            copy = copy,
                            cardShape = cardShape,
                            cardBorder = cardBorder,
                        )
                    }
                }
            }

            // Bottom 3-tab bar: Today / Requests / Messages (64 dp, mirrors automatically in RTL).
            Surface(
                modifier = Modifier.fillMaxWidth(),
                color = palette.card,
                border = cardBorder,
            ) {
                Column(modifier = Modifier.fillMaxWidth()) {
                    HorizontalDivider(color = palette.line, thickness = 1.dp)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = OsraTokens.sizes.bottomBarHeight)
                            .padding(horizontal = spaces.sm, vertical = spaces.xs),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        BottomTabButton(
                            label = copy.tabTodayLabel,
                            selected = activeTab == ChildHomeTab.TODAY,
                            shape = controlShape,
                            modifier = Modifier.weight(1f),
                            onClick = { activeTab = ChildHomeTab.TODAY },
                        )
                        BottomTabButton(
                            label = copy.tabRequestsLabel,
                            selected = activeTab == ChildHomeTab.REQUESTS,
                            shape = controlShape,
                            modifier = Modifier.weight(1f),
                            onClick = { activeTab = ChildHomeTab.REQUESTS },
                        )
                        BottomTabButton(
                            label = copy.tabMessagesLabel,
                            selected = activeTab == ChildHomeTab.MESSAGES,
                            shape = controlShape,
                            modifier = Modifier.weight(1f),
                            onClick = { activeTab = ChildHomeTab.MESSAGES },
                        )
                    }
                }
            }
        }
    }

    if (showTransparencyDialog) {
        AlertDialog(
            onDismissRequest = { showTransparencyDialog = false },
            containerColor = palette.card,
            titleContentColor = palette.ink,
            textContentColor = palette.ink,
            title = {
                Text(
                    text = copy.whatAdultsSeeTitle,
                    style = MaterialTheme.typography.titleMedium.copy(textDirection = TextDirection.Content),
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(spaces.sm)) {
                    copy.transparencyLines.forEach { line ->
                        Text(
                            text = line,
                            style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                            color = palette.ink,
                        )
                    }
                    Spacer(modifier = Modifier.height(spaces.xs))
                    OutlinedButton(
                        onClick = {
                            showTransparencyDialog = false
                            onOpenDeviceSetup()
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp),
                        shape = controlShape,
                        border = BorderStroke(1.dp, palette.border),
                    ) {
                        Text(
                            text = copy.openDeviceSetupLabel,
                            style = MaterialTheme.typography.labelLarge.copy(textDirection = TextDirection.Content),
                            color = palette.primary,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = { showTransparencyDialog = false },
                    modifier = Modifier.heightIn(min = 48.dp),
                ) {
                    Text(text = copy.dialogCloseLabel, color = palette.primary)
                }
            },
        )
    }

    if (showActivityDialog) {
        AlertDialog(
            onDismissRequest = { showActivityDialog = false },
            containerColor = palette.card,
            titleContentColor = palette.ink,
            textContentColor = palette.ink,
            title = {
                Text(
                    text = copy.myActivityTitle,
                    style = MaterialTheme.typography.titleMedium.copy(textDirection = TextDirection.Content),
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(spaces.sm)) {
                    if (copy.activityItems.isEmpty()) {
                        Text(
                            text = copy.activityEmptyLine,
                            style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                            color = palette.muted,
                        )
                    } else {
                        copy.activityItems.forEach { item ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = item.appName,
                                    modifier = Modifier.weight(1f).padding(end = spaces.sm),
                                    style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                                    color = palette.ink,
                                )
                                Text(
                                    text = item.durationText,
                                    style = MaterialTheme.typography.bodySmall.copy(textDirection = TextDirection.Content),
                                    color = palette.muted,
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = { showActivityDialog = false },
                    modifier = Modifier.heightIn(min = 48.dp),
                ) {
                    Text(text = copy.dialogCloseLabel, color = palette.primary)
                }
            },
        )
    }
}

@Composable
private fun TodayTabContent(
    copy: ChildHomeCopy,
    compact: Boolean,
    cardShape: RoundedCornerShape,
    controlShape: RoundedCornerShape,
    cardBorder: BorderStroke?,
    onCallParent: () -> Unit,
    onAskMoreTime: () -> Unit,
    onSeeAllMessages: () -> Unit,
    onOpenTransparency: () -> Unit,
    onOpenActivity: () -> Unit,
    onSendSos: () -> Unit,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val spaces = OsraTokens.spaces

    // Header: avatar + title + "Call a parent" button.
    if (compact) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(spaces.sm),
        ) {
            HeaderIdentity(avatarInitial = copy.avatarInitial, title = copy.headerTitle)
            CallParentPill(label = copy.callParentLabel, shape = controlShape, onClick = onCallParent)
        }
    } else {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            HeaderIdentity(avatarInitial = copy.avatarInitial, title = copy.headerTitle)
            CallParentPill(label = copy.callParentLabel, shape = controlShape, onClick = onCallParent)
        }
    }

    // Wind-down warning state (when active).
    if (!copy.windDownBanner.isNullOrBlank()) {
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = cardShape,
            color = palette.warnContainer,
            contentColor = palette.onWarnContainer,
        ) {
            Text(
                text = copy.windDownBanner,
                modifier = Modifier.padding(spaces.lg),
                style = MaterialTheme.typography.titleSmall.copy(textDirection = TextDirection.Content),
            )
        }
    }

    // Main screen-time ring card + one primary "Ask for more time" CTA.
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
            verticalArrangement = Arrangement.spacedBy(spaces.lg),
        ) {
            if (copy.hasDailyLimit) {
                if (compact) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(spaces.md),
                    ) {
                        TimeLeftRing(
                            fraction = copy.ringFraction,
                            number = copy.ringNumber,
                            unit = copy.ringUnit,
                            warning = !copy.windDownBanner.isNullOrBlank(),
                        )
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(spaces.xs),
                        ) {
                            Text(
                                text = copy.timeLeftHeadline,
                                style = MaterialTheme.typography.titleLarge.copy(textDirection = TextDirection.Content),
                                color = palette.ink,
                                textAlign = TextAlign.Center,
                            )
                            Text(
                                text = copy.usedOfLimitLine,
                                style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                                color = palette.muted,
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                } else {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(spaces.lg),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TimeLeftRing(
                            fraction = copy.ringFraction,
                            number = copy.ringNumber,
                            unit = copy.ringUnit,
                            warning = !copy.windDownBanner.isNullOrBlank(),
                        )
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(spaces.xs),
                        ) {
                            Text(
                                text = copy.timeLeftHeadline,
                                style = MaterialTheme.typography.titleLarge.copy(textDirection = TextDirection.Content),
                                color = palette.ink,
                            )
                            Text(
                                text = copy.usedOfLimitLine,
                                style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                                color = palette.muted,
                            )
                        }
                    }
                }

                Button(
                    onClick = onAskMoreTime,
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
                        text = copy.askMoreTimeLabel,
                        style = MaterialTheme.typography.labelLarge.copy(textDirection = TextDirection.Content),
                        textAlign = TextAlign.Center,
                    )
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(spaces.xs)) {
                    Text(
                        text = copy.timeLeftHeadline,
                        style = MaterialTheme.typography.titleMedium.copy(textDirection = TextDirection.Content),
                        color = palette.ink,
                    )
                    Text(
                        text = copy.usedOfLimitLine,
                        style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                        color = palette.muted,
                    )
                }
            }
        }
    }

    // Next routine + Bedtime tiles.
    if (compact || copy.bedtimeValue.isNullOrBlank()) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(spaces.sm),
        ) {
            InfoTileCard(
                eyebrow = copy.nextLabel,
                body = copy.nextRoutineLine,
                shape = cardShape,
                border = cardBorder,
                modifier = Modifier.fillMaxWidth(),
            )
            if (!copy.bedtimeValue.isNullOrBlank()) {
                InfoTileCard(
                    eyebrow = copy.bedtimeLabel,
                    body = copy.bedtimeValue,
                    shape = cardShape,
                    border = cardBorder,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    } else {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(spaces.sm),
        ) {
            InfoTileCard(
                eyebrow = copy.nextLabel,
                body = copy.nextRoutineLine,
                shape = cardShape,
                border = cardBorder,
                modifier = Modifier.weight(1f),
            )
            InfoTileCard(
                eyebrow = copy.bedtimeLabel,
                body = copy.bedtimeValue,
                shape = cardShape,
                border = cardBorder,
                modifier = Modifier.weight(1f),
            )
        }
    }

    // Pending request card (G10 — prevents duplicate requests; ages out after 2 h).
    if (!copy.pendingTitle.isNullOrBlank()) {
        PendingRequestCard(
            title = copy.pendingTitle,
            sentLine = copy.pendingSentLine.orEmpty(),
            badge = copy.pendingBadge.orEmpty(),
            isWaiting = copy.pendingIsWaiting,
            shape = cardShape,
        )
    }

    // Latest parent decision preview (G10 — no "note from parents" row; links to Messages).
    if (copy.latestDecision != null) {
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
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = copy.latestSectionLabel,
                        style = MaterialTheme.typography.labelMedium.copy(
                            fontWeight = FontWeight.SemiBold,
                            textDirection = TextDirection.Content,
                        ),
                        color = palette.muted,
                    )
                    TextButton(
                        onClick = onSeeAllMessages,
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) {
                        Text(text = copy.seeAllLabel, color = palette.primary)
                    }
                }
                Text(
                    text = copy.latestDecision.title,
                    style = MaterialTheme.typography.titleMedium.copy(textDirection = TextDirection.Content),
                    color = palette.ink,
                )
                Text(
                    text = copy.latestDecision.subtitle,
                    style = MaterialTheme.typography.bodySmall.copy(textDirection = TextDirection.Content),
                    color = palette.muted,
                )
            }
        }
    }

    // Transparency & Activity card: "What {adults} can see" + "My activity".
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = cardShape,
        color = palette.card,
        border = cardBorder,
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            NavigationListRow(
                title = copy.whatAdultsSeeTitle,
                subtitle = copy.whatAdultsSeeSubtitle,
                actionLabel = copy.openLabel,
                onClick = onOpenTransparency,
            )
            HorizontalDivider(
                modifier = Modifier.padding(horizontal = spaces.lg),
                color = palette.line,
                thickness = 1.dp,
            )
            NavigationListRow(
                title = copy.myActivityTitle,
                subtitle = copy.myActivitySubtitle,
                actionLabel = copy.openLabel,
                onClick = onOpenActivity,
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
            style = MaterialTheme.typography.labelLarge.copy(textDirection = TextDirection.Content),
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun RequestsTabContent(
    copy: ChildHomeCopy,
    compact: Boolean,
    cardShape: RoundedCornerShape,
    controlShape: RoundedCornerShape,
    cardBorder: BorderStroke?,
    requestSendState: TimeRequestSendState,
    onRequestMoreTime: (Int) -> Unit,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val spaces = OsraTokens.spaces

    Text(
        text = copy.requestsHeaderTitle,
        style = MaterialTheme.typography.headlineSmall.copy(textDirection = TextDirection.Content),
        color = palette.ink,
    )

    if (!copy.pendingTitle.isNullOrBlank()) {
        PendingRequestCard(
            title = copy.pendingTitle,
            sentLine = copy.pendingSentLine.orEmpty(),
            badge = copy.pendingBadge.orEmpty(),
            isWaiting = copy.pendingIsWaiting,
            shape = cardShape,
        )
    }

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
            verticalArrangement = Arrangement.spacedBy(spaces.md),
        ) {
            Text(
                text = copy.requestsGoesToLine,
                style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                color = palette.muted,
            )
            if (!copy.hasDailyLimit) {
                Text(
                    text = copy.requestsDisabledLine,
                    style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                    color = palette.muted,
                )
            } else {
                if (requestSendState == TimeRequestSendState.FAILED && copy.requestFailedLine.isNotBlank()) {
                    Text(
                        text = copy.requestFailedLine,
                        style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                        color = palette.warn,
                    )
                }
                // G2/G3 (Karim 17:02 + Codex 17:37): 15 or 30 min of daily screen time only (no 60 min, no per-app scope, no note).
                val enabled = !copy.pendingIsWaiting && requestSendState != TimeRequestSendState.SENDING
                if (compact) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(spaces.sm),
                    ) {
                        TimeOptionButton(
                            label = copy.request15Label,
                            enabled = enabled,
                            shape = controlShape,
                            modifier = Modifier.fillMaxWidth(),
                            onClick = { onRequestMoreTime(15) },
                        )
                        TimeOptionButton(
                            label = copy.request30Label,
                            enabled = enabled,
                            shape = controlShape,
                            modifier = Modifier.fillMaxWidth(),
                            onClick = { onRequestMoreTime(30) },
                        )
                    }
                } else {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(spaces.sm),
                    ) {
                        TimeOptionButton(
                            label = copy.request15Label,
                            enabled = enabled,
                            shape = controlShape,
                            modifier = Modifier.weight(1f),
                            onClick = { onRequestMoreTime(15) },
                        )
                        TimeOptionButton(
                            label = copy.request30Label,
                            enabled = enabled,
                            shape = controlShape,
                            modifier = Modifier.weight(1f),
                            onClick = { onRequestMoreTime(30) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MessagesTabContent(
    copy: ChildHomeCopy,
    cardShape: RoundedCornerShape,
    cardBorder: BorderStroke?,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val spaces = OsraTokens.spaces

    Text(
        text = copy.messagesHeaderTitle,
        style = MaterialTheme.typography.headlineSmall.copy(textDirection = TextDirection.Content),
        color = palette.ink,
    )

    if (copy.allDecisions.isEmpty()) {
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = cardShape,
            color = palette.card,
            border = cardBorder,
        ) {
            Text(
                text = copy.messagesEmptyLine,
                modifier = Modifier.padding(spaces.lg),
                style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                color = palette.muted,
            )
        }
    } else {
        copy.allDecisions.forEach { item ->
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
                        text = item.title,
                        style = MaterialTheme.typography.titleMedium.copy(textDirection = TextDirection.Content),
                        color = palette.ink,
                    )
                    Text(
                        text = item.subtitle,
                        style = MaterialTheme.typography.bodySmall.copy(textDirection = TextDirection.Content),
                        color = palette.muted,
                    )
                    Surface(
                        shape = RoundedCornerShape(radii.control),
                        color = palette.tint,
                        contentColor = palette.ok,
                    ) {
                        Text(
                            text = item.badge,
                            modifier = Modifier.padding(horizontal = spaces.sm, vertical = spaces.xs),
                            style = MaterialTheme.typography.labelMedium.copy(
                                fontWeight = FontWeight.SemiBold,
                                textDirection = TextDirection.Content,
                            ),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun HeaderIdentity(avatarInitial: String, title: String) {
    val palette = OsraTheme.LocalOsraPalette.current
    val spaces = OsraTokens.spaces
    Row(
        horizontalArrangement = Arrangement.spacedBy(spaces.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(OsraTokens.sizes.avatar)
                .clip(CircleShape)
                .background(palette.primary),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = avatarInitial,
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                color = palette.onPrimary,
            )
        }
        Text(
            text = title,
            style = MaterialTheme.typography.headlineSmall.copy(textDirection = TextDirection.Content),
            color = palette.ink,
        )
    }
}

@Composable
private fun CallParentPill(label: String, shape: RoundedCornerShape, onClick: () -> Unit) {
    val palette = OsraTheme.LocalOsraPalette.current
    OutlinedButton(
        onClick = onClick,
        modifier = Modifier.heightIn(min = 48.dp),
        shape = shape,
        border = BorderStroke(1.dp, palette.border),
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = palette.tint,
            contentColor = palette.primary,
        ),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge.copy(textDirection = TextDirection.Content),
        )
    }
}

@Composable
private fun TimeLeftRing(
    fraction: Float,
    number: String,
    unit: String,
    warning: Boolean,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val fontScale = LocalDensity.current.fontScale
    val trackColor = palette.track
    val activeColor = if (warning) palette.warn else palette.primary
    Box(
        modifier = Modifier.size(96.dp),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.fillMaxSize().padding(6.dp)) {
            val stroke = Stroke(width = 10.dp.toPx(), cap = StrokeCap.Round)
            drawArc(
                color = trackColor,
                startAngle = -90f,
                sweepAngle = 360f,
                useCenter = false,
                style = stroke,
            )
            drawArc(
                color = activeColor,
                startAngle = -90f,
                sweepAngle = 360f * fraction.coerceIn(0f, 1f),
                useCenter = false,
                style = stroke,
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = number,
                style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                color = palette.ink,
            )
            if (ChildHomePolicy.shouldShowRingCaption(fontScale) && unit.isNotBlank()) {
                Text(
                    text = unit,
                    style = MaterialTheme.typography.labelSmall.copy(textDirection = TextDirection.Content),
                    color = palette.muted,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun InfoTileCard(
    eyebrow: String,
    body: String,
    shape: RoundedCornerShape,
    border: BorderStroke?,
    modifier: Modifier,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val spaces = OsraTokens.spaces
    Surface(
        modifier = modifier,
        shape = shape,
        color = palette.card,
        border = border,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(spaces.lg),
            verticalArrangement = Arrangement.spacedBy(spaces.xs),
        ) {
            Text(
                text = eyebrow,
                style = MaterialTheme.typography.labelMedium.copy(
                    fontWeight = FontWeight.SemiBold,
                    textDirection = TextDirection.Content,
                ),
                color = palette.muted,
            )
            Text(
                text = body,
                style = MaterialTheme.typography.titleSmall.copy(textDirection = TextDirection.Content),
                color = palette.ink,
            )
        }
    }
}

@Composable
private fun PendingRequestCard(
    title: String,
    sentLine: String,
    badge: String,
    isWaiting: Boolean,
    shape: RoundedCornerShape,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val spaces = OsraTokens.spaces
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = shape,
        color = if (isWaiting) palette.warnContainer else palette.card,
        contentColor = if (isWaiting) palette.onWarnContainer else palette.ink,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(spaces.lg),
            verticalArrangement = Arrangement.spacedBy(spaces.xs),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall.copy(textDirection = TextDirection.Content),
            )
            if (sentLine.isNotBlank()) {
                Text(
                    text = sentLine,
                    style = MaterialTheme.typography.bodySmall.copy(textDirection = TextDirection.Content),
                    color = if (isWaiting) palette.onWarnContainer else palette.muted,
                )
            }
            if (badge.isNotBlank()) {
                Surface(
                    shape = RoundedCornerShape(radii.control),
                    color = palette.card,
                    contentColor = if (isWaiting) palette.warn else palette.muted,
                ) {
                    Text(
                        text = badge,
                        modifier = Modifier.padding(horizontal = spaces.sm, vertical = spaces.xs),
                        style = MaterialTheme.typography.labelMedium.copy(
                            fontWeight = FontWeight.SemiBold,
                            textDirection = TextDirection.Content,
                        ),
                    )
                }
            }
        }
    }
}

@Composable
private fun NavigationListRow(
    title: String,
    subtitle: String,
    actionLabel: String,
    onClick: () -> Unit,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val spaces = OsraTokens.spaces
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = spaces.lg, vertical = spaces.md),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(end = spaces.md),
            verticalArrangement = Arrangement.spacedBy(spaces.xxs),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall.copy(textDirection = TextDirection.Content),
                color = palette.ink,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall.copy(textDirection = TextDirection.Content),
                color = palette.muted,
            )
        }
        Text(
            text = actionLabel,
            style = MaterialTheme.typography.labelLarge.copy(textDirection = TextDirection.Content),
            color = palette.primary,
        )
    }
}

@Composable
private fun TimeOptionButton(
    label: String,
    enabled: Boolean,
    shape: RoundedCornerShape,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.heightIn(min = OsraTokens.sizes.primaryButtonHeight),
        shape = shape,
        colors = ButtonDefaults.buttonColors(
            containerColor = palette.primary,
            contentColor = palette.onPrimary,
        ),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge.copy(textDirection = TextDirection.Content),
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun BottomTabButton(
    label: String,
    selected: Boolean,
    shape: RoundedCornerShape,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val spaces = OsraTokens.spaces
    Surface(
        modifier = modifier
            .heightIn(min = 48.dp)
            .padding(horizontal = spaces.xs)
            .clip(shape)
            .clickable(onClick = onClick),
        shape = shape,
        color = if (selected) palette.tint else OsraTheme.Transparent,
        contentColor = if (selected) palette.primary else palette.muted,
    ) {
        Box(
            modifier = Modifier.fillMaxWidth().padding(horizontal = spaces.xs, vertical = spaces.sm),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge.copy(
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    textDirection = TextDirection.Content,
                ),
                textAlign = TextAlign.Center,
            )
        }
    }
}

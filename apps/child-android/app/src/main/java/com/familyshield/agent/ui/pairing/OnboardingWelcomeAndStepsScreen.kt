package com.familyshield.agent.ui.pairing

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.familyshield.agent.R
import com.familyshield.agent.ui.theme.OsraTheme
import com.familyshield.agent.ui.theme.OsraTokens

/**
 * Words passed into [OnboardingWelcomeScreen] from Android resources (`setup_welcome_*`),
 * so the composable holds no hardcoded strings and renders EN/AR identically.
 */
data class WelcomeCopy(
    val brandLabel: String,
    val title: String,
    val body: String,
    val start: String,
)

/**
 * Issue #1131: Android 13+ non-store install guidance shown on the Accessibility step until the
 * service is actually bound.
 */
data class RestrictedSettingsGuideCopy(
    val steps: List<String>,
    val openAppInfoButton: String,
    val waitingLine: String,
)

/**
 * Words passed into [OnboardingPermissionStepScreen] from Android resources
 * (`OnboardingPolicy.Grant.*`, `setup_grant_button`, etc.).
 */
data class PermissionStepCopy(
    val brandLabel: String,
    val progressLine: String,
    val title: String,
    val whyOneSentence: String,
    val grantButton: String,
    val optionalBadge: String? = null,
    val oemHint: String? = null,
    val restrictedSettingsGuide: RestrictedSettingsGuideCopy? = null,
    val skipLabel: String? = null,
    val checklistLabel: String? = null,
)

/**
 * U44 (#952): Branded first-launch welcome screen built on [OsraTheme] (`LocalOsraPalette`,
 * `LocalOsraRadii`, ADR-0038 page/primary tokens) with the OSRA mark, two-line max title,
 * concise body, and a 52 dp minHeight Start button.
 */
@Composable
fun OnboardingWelcomeScreen(
    copy: WelcomeCopy,
    onStart: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val scroll = rememberScrollState()

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(palette.page)
            .systemBarsPadding()
            .verticalScroll(scroll)
            .padding(horizontal = OsraTokens.spaces.xl, vertical = OsraTokens.spaces.xl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = OsraTokens.spaces.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            OsraBrandMark(brandLabel = copy.brandLabel)
            Spacer(modifier = Modifier.height(OsraTokens.spaces.xl))
            Text(
                text = copy.title,
                style = MaterialTheme.typography.headlineMedium.copy(
                    textDirection = TextDirection.Content,
                ),
                color = palette.ink,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(modifier = Modifier.height(OsraTokens.spaces.md))
            Text(
                text = copy.body,
                style = MaterialTheme.typography.bodyLarge.copy(
                    textDirection = TextDirection.Content,
                ),
                color = palette.muted,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        Spacer(modifier = Modifier.height(OsraTokens.spaces.xl))

        Button(
            onClick = onStart,
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = OsraTokens.sizes.primaryButtonHeight),
            shape = RoundedCornerShape(radii.control),
            colors = ButtonDefaults.buttonColors(
                containerColor = palette.primary,
                contentColor = palette.onPrimary,
            ),
        ) {
            Text(
                text = copy.start,
                style = MaterialTheme.typography.labelLarge.copy(
                    textDirection = TextDirection.Content,
                ),
                maxLines = 2,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/**
 * U44 (#952): Single-permission setup step screen on [OsraTheme] tokens, presenting the OSRA mark,
 * permission title, one-sentence explanation, optional OEM guidance, and primary 52 dp action.
 */
@Composable
fun OnboardingPermissionStepScreen(
    copy: PermissionStepCopy,
    onGrant: () -> Unit,
    onOpenAppInfo: (() -> Unit)? = null,
    onSkip: (() -> Unit)? = null,
    onOpenChecklist: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val scroll = rememberScrollState()

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(palette.page)
            .systemBarsPadding()
            .padding(horizontal = OsraTokens.spaces.lg, vertical = OsraTokens.spaces.md),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(scroll),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            OsraBrandMark(brandLabel = copy.brandLabel, compact = true)
            Spacer(modifier = Modifier.height(OsraTokens.spaces.sm))
            Text(
                text = copy.progressLine,
                style = MaterialTheme.typography.bodySmall.copy(
                    textDirection = TextDirection.Content,
                ),
                color = palette.primary,
                fontWeight = FontWeight.Medium,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(modifier = Modifier.height(OsraTokens.spaces.md))

            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .border(
                        width = 1.dp,
                        color = palette.cardBorder,
                        shape = RoundedCornerShape(radii.card),
                    ),
                color = palette.card,
                shape = RoundedCornerShape(radii.card),
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(OsraTokens.spaces.md),
                    verticalArrangement = Arrangement.spacedBy(OsraTokens.spaces.sm),
                ) {
                    copy.optionalBadge?.let { badge ->
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(radii.bar))
                                .background(palette.tint)
                                .padding(horizontal = OsraTokens.spaces.md, vertical = OsraTokens.spaces.xs),
                        ) {
                            Text(
                                text = badge,
                                style = MaterialTheme.typography.labelMedium.copy(
                                    textDirection = TextDirection.Content,
                                ),
                                color = palette.primary,
                            )
                        }
                    }

                    Text(
                        text = copy.title,
                        style = MaterialTheme.typography.titleLarge.copy(
                            textDirection = TextDirection.Content,
                        ),
                        color = palette.ink,
                    )

                    Text(
                        text = copy.whyOneSentence,
                        style = MaterialTheme.typography.bodyLarge.copy(
                            textDirection = TextDirection.Content,
                        ),
                        color = palette.muted,
                    )

                    copy.restrictedSettingsGuide?.let { guide ->
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(radii.control))
                                .background(palette.tint)
                                .border(1.dp, palette.border, RoundedCornerShape(radii.control))
                                .padding(OsraTokens.spaces.md),
                            verticalArrangement = Arrangement.spacedBy(OsraTokens.spaces.xs),
                        ) {
                            guide.steps.forEachIndexed { index, stepText ->
                                Text(
                                    text = "${index + 1}. $stepText",
                                    style = MaterialTheme.typography.bodySmall.copy(
                                        textDirection = TextDirection.Content,
                                    ),
                                    color = palette.ink,
                                )
                            }
                            if (onOpenAppInfo != null) {
                                Spacer(modifier = Modifier.height(OsraTokens.spaces.xs))
                                OutlinedButton(
                                    onClick = onOpenAppInfo,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .defaultMinSize(minHeight = OsraTokens.sizes.primaryButtonHeight),
                                    shape = RoundedCornerShape(radii.control),
                                ) {
                                    Text(
                                        text = guide.openAppInfoButton,
                                        style = MaterialTheme.typography.labelLarge.copy(
                                            textDirection = TextDirection.Content,
                                        ),
                                        textAlign = TextAlign.Center,
                                    )
                                }
                            }
                            Text(
                                text = guide.waitingLine,
                                style = MaterialTheme.typography.bodySmall.copy(
                                    textDirection = TextDirection.Content,
                                ),
                                color = palette.muted,
                            )
                        }
                    }

                    copy.oemHint?.let { hint ->
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(radii.control))
                                .background(palette.tint)
                                .border(1.dp, palette.border, RoundedCornerShape(radii.control))
                                .padding(OsraTokens.spaces.md),
                        ) {
                            Text(
                                text = hint,
                                style = MaterialTheme.typography.bodySmall.copy(
                                    textDirection = TextDirection.Content,
                                ),
                                color = palette.ink,
                            )
                        }
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(OsraTokens.spaces.md))

        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(OsraTokens.spaces.xs),
        ) {
            Button(
                onClick = onGrant,
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = OsraTokens.sizes.primaryButtonHeight),
                shape = RoundedCornerShape(radii.control),
                colors = ButtonDefaults.buttonColors(
                    containerColor = palette.primary,
                    contentColor = palette.onPrimary,
                ),
            ) {
                Text(
                    text = copy.grantButton,
                    style = MaterialTheme.typography.labelLarge.copy(
                        textDirection = TextDirection.Content,
                    ),
                    textAlign = TextAlign.Center,
                )
            }

            if (onSkip != null && copy.skipLabel != null) {
                OutlinedButton(
                    onClick = onSkip,
                    modifier = Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = OsraTokens.sizes.primaryButtonHeight),
                    shape = RoundedCornerShape(radii.control),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.ink),
                ) {
                    Text(
                        text = copy.skipLabel,
                        style = MaterialTheme.typography.labelLarge.copy(
                            textDirection = TextDirection.Content,
                        ),
                        textAlign = TextAlign.Center,
                    )
                }
            }

            if (onOpenChecklist != null && copy.checklistLabel != null) {
                TextButton(
                    onClick = onOpenChecklist,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = copy.checklistLabel,
                        style = MaterialTheme.typography.labelLarge.copy(
                            textDirection = TextDirection.Content,
                        ),
                        color = palette.primary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

@Composable
private fun OsraBrandMark(brandLabel: String, compact: Boolean = false) {
    val palette = OsraTheme.LocalOsraPalette.current
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(if (compact) OsraTokens.spaces.xs else OsraTokens.spaces.sm),
    ) {
        Box(
            modifier = Modifier
                .size(if (compact) 48.dp else 64.dp)
                .clip(CircleShape)
                .background(palette.tint)
                .border(1.5.dp, palette.primary, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                painter = painterResource(id = R.drawable.ic_app_foreground),
                contentDescription = brandLabel,
                modifier = Modifier.size(if (compact) 32.dp else 44.dp),
            )
        }
        Text(
            text = brandLabel,
            style = MaterialTheme.typography.labelLarge.copy(
                textDirection = TextDirection.Content,
            ),
            color = palette.primary,
            fontWeight = FontWeight.Bold,
        )
    }
}

/** Row model for [OnboardingChecklistScreen], carrying resolved strings and live OS status. */
data class ChecklistRowUi(
    val title: String,
    val whyOneSentence: String,
    val granted: Boolean,
    val required: Boolean,
    val optionalBadge: String?,
    val oemHint: String?,
    val grantLabel: String,
    val onGrant: () -> Unit,
)

/** Resolved words and actions for [OnboardingChecklistScreen]. */
data class ChecklistCopy(
    val brandLabel: String,
    val title: String,
    val progressLine: String,
    val canComplete: Boolean,
    val intro: String?,
    val rows: List<ChecklistRowUi>,
    val footerLabel: String?,
    val onFooterClick: (() -> Unit)?,
)

/** Branded Compose loading state rendered before pairing/welcome route resolves. */
@Composable
fun OnboardingLoadingScreen(
    brandLabel: String,
    title: String,
    modifier: Modifier = Modifier,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(palette.page)
            .systemBarsPadding()
            .padding(OsraTokens.spaces.xl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        OsraBrandMark(brandLabel = brandLabel)
        Spacer(modifier = Modifier.height(OsraTokens.spaces.lg))
        Text(
            text = title,
            style = MaterialTheme.typography.titleLarge.copy(textDirection = TextDirection.Content),
            color = palette.ink,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(OsraTokens.spaces.lg))
        CircularProgressIndicator(color = palette.primary)
    }
}

/**
 * U44 (#952): Branded checklist overview built on [OsraTheme] tokens (`LocalOsraPalette`,
 * `LocalOsraRadii`, `primaryButtonHeight`) — replaces the legacy bare system-colored list.
 */
@Composable
fun OnboardingChecklistScreen(
    copy: ChecklistCopy,
    modifier: Modifier = Modifier,
) {
    val palette = OsraTheme.LocalOsraPalette.current
    val radii = OsraTheme.LocalOsraRadii.current
    val scroll = rememberScrollState()

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(palette.page)
            .systemBarsPadding()
            .verticalScroll(scroll)
            .padding(horizontal = OsraTokens.spaces.xl, vertical = OsraTokens.spaces.lg),
        verticalArrangement = Arrangement.spacedBy(OsraTokens.spaces.md),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            OsraBrandMark(brandLabel = copy.brandLabel)
            Spacer(modifier = Modifier.height(OsraTokens.spaces.md))
            Text(
                text = copy.title,
                style = MaterialTheme.typography.headlineSmall.copy(textDirection = TextDirection.Content),
                color = palette.ink,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(modifier = Modifier.height(OsraTokens.spaces.xs))
            Text(
                text = copy.progressLine,
                style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                color = if (copy.canComplete) palette.ok else palette.danger,
                fontWeight = FontWeight.Medium,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        copy.intro?.let { intro ->
            Text(
                text = intro,
                style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                color = palette.muted,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        copy.rows.forEach { row ->
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .border(
                        width = 1.dp,
                        color = palette.cardBorder,
                        shape = RoundedCornerShape(radii.card),
                    ),
                color = palette.card,
                shape = RoundedCornerShape(radii.card),
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(OsraTokens.spaces.md),
                    verticalArrangement = Arrangement.spacedBy(OsraTokens.spaces.sm),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = row.title,
                            style = MaterialTheme.typography.titleMedium.copy(textDirection = TextDirection.Content),
                            color = when {
                                row.granted -> palette.ok
                                row.required -> palette.danger
                                else -> palette.ink
                            },
                            modifier = Modifier.weight(1f),
                        )
                        row.optionalBadge?.takeIf { !row.granted }?.let { badge ->
                            Box(
                                modifier = Modifier
                                    .padding(start = OsraTokens.spaces.sm)
                                    .clip(RoundedCornerShape(radii.bar))
                                    .background(palette.tint)
                                    .padding(horizontal = OsraTokens.spaces.sm, vertical = OsraTokens.spaces.xxs),
                            ) {
                                Text(
                                    text = badge,
                                    style = MaterialTheme.typography.labelSmall.copy(textDirection = TextDirection.Content),
                                    color = palette.primary,
                                )
                            }
                        }
                    }

                    if (!row.granted) {
                        Text(
                            text = row.whyOneSentence,
                            style = MaterialTheme.typography.bodyMedium.copy(textDirection = TextDirection.Content),
                            color = palette.muted,
                        )
                        row.oemHint?.let { hint ->
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(radii.control))
                                    .background(palette.tint)
                                    .border(1.dp, palette.border, RoundedCornerShape(radii.control))
                                    .padding(OsraTokens.spaces.sm),
                            ) {
                                Text(
                                    text = hint,
                                    style = MaterialTheme.typography.bodySmall.copy(textDirection = TextDirection.Content),
                                    color = palette.ink,
                                )
                            }
                        }
                        Button(
                            onClick = row.onGrant,
                            modifier = Modifier
                                .fillMaxWidth()
                                .defaultMinSize(minHeight = OsraTokens.sizes.primaryButtonHeight),
                            shape = RoundedCornerShape(radii.control),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = palette.primary,
                                contentColor = palette.onPrimary,
                            ),
                        ) {
                            Text(
                                text = row.grantLabel,
                                style = MaterialTheme.typography.labelLarge.copy(textDirection = TextDirection.Content),
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
            }
        }

        if (copy.footerLabel != null && copy.onFooterClick != null) {
            Spacer(modifier = Modifier.height(OsraTokens.spaces.xs))
            Button(
                onClick = copy.onFooterClick,
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = OsraTokens.sizes.primaryButtonHeight),
                shape = RoundedCornerShape(radii.control),
                colors = ButtonDefaults.buttonColors(
                    containerColor = palette.primary,
                    contentColor = palette.onPrimary,
                ),
            ) {
                Text(
                    text = copy.footerLabel,
                    style = MaterialTheme.typography.labelLarge.copy(textDirection = TextDirection.Content),
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

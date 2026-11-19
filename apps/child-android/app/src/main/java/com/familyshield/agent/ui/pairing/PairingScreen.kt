package com.familyshield.agent.ui.pairing

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.familyshield.agent.setup.PairingScreenState
import com.familyshield.agent.ui.theme.OsraTheme
import com.familyshield.agent.ui.theme.OsraTokens

/**
 * #728: the pairing screen, body only — the design's column, code cells, name field, button, reassurance box and
 * one error line, drawn on [OsraTheme] and driven by [PairingScreenState].
 *
 * **The copy is a parameter.** The design's words are the Arabic Language Bureau's, and this file invents none: a
 * caller passes [PairingCopy], which the wiring PR fills from `strings.xml`. A composable that hardcodes English
 * is a translation debt with a comment on it.
 *
 * **The code cells are always left to right**, in Arabic too — a six-digit code is a number, and the design says
 * so. Everything else takes its direction from the text: `TextDirection.Content` is what the composable sets, and
 * the platform resolves it from the locale.
 */
@Composable
fun PairingScreen(
    state: PairingScreenState,
    copy: PairingCopy,
    onDigit: (Char) -> Unit,
    onBackspace: () -> Unit,
    onName: (String) -> Unit,
    onSubmit: () -> Unit,
    onScan: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = MaterialTheme.colorScheme
    // The current theme's radii, not the light ones by name (Bureau, #807): naming `OsraTokens.lightRadii`
    // gave a dark screen the light corners, and the test below refuses the pattern from `ui/`.
    val radii = OsraTheme.LocalOsraRadii.current

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(palette.background)
            .padding(horizontal = OsraTokens.spaces.xl),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // 3. The title, and 4. the one sentence under it.
        Text(
            text = copy.title,
            style = MaterialTheme.typography.headlineMedium,
            color = palette.onBackground,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = OsraTokens.spaces.xxl),
        )
        Text(
            text = copy.subtitle,
            style = MaterialTheme.typography.bodyLarge,
            color = palette.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = OsraTokens.spaces.sm),
        )

        // 5. Scan first: it is the shorter road, and the design puts it above the divider.
        Button(
            onClick = onScan,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = OsraTokens.spaces.xl)
                .height(OsraTokens.sizes.primaryButtonHeight),
            shape = RoundedCornerShape(radii.control),
            colors = ButtonDefaults.buttonColors(
                containerColor = palette.primary,
                contentColor = palette.onPrimary,
            ),
        ) {
            Text(copy.scanButton, style = MaterialTheme.typography.labelLarge)
        }

        // 6. The divider's short label.
        Text(
            text = copy.orTypeIt,
            style = MaterialTheme.typography.labelMedium,
            color = palette.onSurfaceVariant,
            modifier = Modifier.padding(vertical = OsraTokens.spaces.lg),
        )

        // 7. The card: the six cells, the optional name, the button.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(palette.surfaceVariant, RoundedCornerShape(radii.card))
                .padding(OsraTokens.spaces.lg),
        ) {
            CodeCells(
                digits = state.digits,
                onDigit = onDigit,
                onBackspace = onBackspace,
                error = state.error,
            )

            Text(
                text = copy.nameLabel,
                style = MaterialTheme.typography.labelMedium,
                color = palette.onSurfaceVariant,
                modifier = Modifier.padding(top = OsraTokens.spaces.lg, bottom = OsraTokens.spaces.xs),
            )
            BasicTextField(
                value = state.deviceName,
                onValueChange = onName,
                singleLine = true,
                enabled = !state.waiting,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = palette.onSurface),
                cursorBrush = SolidColor(palette.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(OsraTokens.sizes.actionButtonHeight)
                    .background(palette.surface, RoundedCornerShape(radii.control))
                    .border(1.5.dp, palette.outline, RoundedCornerShape(radii.control))
                    .padding(horizontal = OsraTokens.spaces.md, vertical = OsraTokens.spaces.sm),
            )

            Button(
                onClick = onSubmit,
                enabled = state.canSubmit,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = OsraTokens.spaces.lg)
                    .height(OsraTokens.sizes.actionButtonHeight),
                shape = RoundedCornerShape(radii.control),
                colors = ButtonDefaults.buttonColors(
                    containerColor = palette.primary,
                    contentColor = palette.onPrimary,
                    disabledContainerColor = palette.surfaceVariant,
                    disabledContentColor = palette.onSurfaceVariant,
                ),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                    if (state.waiting) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = palette.onSurfaceVariant,
                        )
                        Box(Modifier.width(OsraTokens.spaces.sm))
                    }
                    Text(
                        text = if (state.waiting) copy.waiting else copy.submit,
                        style = MaterialTheme.typography.labelLarge,
                    )
                }
            }
        }

        // 8. The reassurance box. Its sentence is the caller's, because "true on that client" is a claim only the
        // wiring can make.
        Text(
            text = copy.reassurance,
            style = MaterialTheme.typography.bodySmall,
            color = palette.onBackground,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = OsraTokens.spaces.lg)
                .background(palette.surfaceVariant, RoundedCornerShape(radii.control))
                .padding(OsraTokens.spaces.md),
        )
    }
}

/**
 * Six cells, left to right in every language, with one hidden field behind them: a paste of six digits fills all
 * of them, and the active cell carries the primary colour at double the border width (the design's states).
 */
@Composable
private fun CodeCells(
    digits: String,
    onDigit: (Char) -> Unit,
    onBackspace: () -> Unit,
    error: String?,
) {
    val palette = MaterialTheme.colorScheme
    val radii = OsraTheme.LocalOsraRadii.current

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(OsraTokens.spaces.sm, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        digits.padEnd(PairingScreenState.CODE_LENGTH, ' ').forEachIndexed { index, digit ->
            // A wider gap after the third digit: six characters in one run are read, not counted.
            if (index == 3) Box(Modifier.width(OsraTokens.spaces.sm))
            val active = index == digits.length
            Box(
                modifier = Modifier
                    .size(width = CELL_WIDTH, height = CELL_HEIGHT)
                    .background(palette.surface, RoundedCornerShape(radii.control))
                    .border(
                        width = if (active) 2.dp else 1.5.dp,
                        color = if (active) palette.primary else palette.outline,
                        shape = RoundedCornerShape(radii.control),
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = if (digit == ' ') "" else digit.toString(),
                    style = TextStyle(
                        fontSize = 24.sp,
                        fontWeight = FontWeight.Bold,
                        textDirection = TextDirection.Ltr,
                        color = palette.onSurface,
                        // Tabular figures keep the six cells from shifting as digits land.
                        fontFeatureSettings = "tnum",
                    ),
                )
            }
        }
    }

    // The keyboard's input arrives at the caller: this composable draws the field but does not decide the code.
    BasicTextField(
        value = "",
        onValueChange = { text ->
            text.lastOrNull()?.let { if (it.isDigit()) onDigit(it) }
            if (text.isEmpty() && digits.isNotEmpty()) onBackspace()
        },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp),
    )

    // 9. One line, under the cells, never a toast.
    Text(
        text = error.orEmpty(),
        style = MaterialTheme.typography.bodySmall,
        color = palette.error,
        textAlign = TextAlign.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = OsraTokens.spaces.sm),
    )
}

/** The design's cell size: 42 by 52, with the digits at 24/700. */
private val CELL_WIDTH = 42.dp
private val CELL_HEIGHT = 52.dp

/** The design's words, supplied by the caller so this file holds none of them (the Bureau's, not mine). */
data class PairingCopy(
    val title: String,
    val subtitle: String,
    val scanButton: String,
    val orTypeIt: String,
    val nameLabel: String,
    val submit: String,
    val waiting: String,
    val reassurance: String,
)

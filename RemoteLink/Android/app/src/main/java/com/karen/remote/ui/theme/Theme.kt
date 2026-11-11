package com.karen.remote.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

private val DarkColorScheme = darkColorScheme(
    primary = KarenCyan,
    secondary = KarenIndigo,
    background = KarenDarkBg,
    surface = KarenSurface,
    surfaceVariant = KarenSurfaceVariant,
    onPrimary = KarenDarkBg,
    onSecondary = KarenDarkBg,
    onBackground = KarenTextPrimary,
    onSurface = KarenTextPrimary,
    onSurfaceVariant = KarenTextSecondary
)

@Composable
fun KarenRemoteTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = DarkColorScheme,
        content = content
    )
}


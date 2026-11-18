package com.quillnative.android

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.automirrored.outlined.DirectionsRun
import androidx.compose.material.icons.automirrored.outlined.Reply
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Flight
import androidx.compose.material.icons.outlined.MonitorWeight
import androidx.compose.material.icons.outlined.Photo
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.ui.graphics.vector.ImageVector
import com.quillnative.core.PostKind
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import android.text.format.DateUtils

val PostKind.icon: ImageVector get() = when (this) {
    PostKind.NOTE -> Icons.Outlined.EditNote
    PostKind.PHOTO -> Icons.Outlined.Photo
    PostKind.REPLY -> Icons.AutoMirrored.Outlined.Reply
    PostKind.ARTICLE -> Icons.AutoMirrored.Outlined.Article
    PostKind.BOOKMARK -> Icons.Outlined.BookmarkBorder
    PostKind.LIKE -> Icons.Outlined.FavoriteBorder
    PostKind.REPOST -> Icons.Outlined.Repeat
    PostKind.EVENT -> Icons.Outlined.Event
    PostKind.REVIEW -> Icons.Outlined.StarBorder
    PostKind.ITINERARY -> Icons.Outlined.Flight
    PostKind.CODE -> Icons.Outlined.Code
    PostKind.WEIGHT -> Icons.Outlined.MonitorWeight
    PostKind.EXERCISE -> Icons.AutoMirrored.Outlined.DirectionsRun
}

/** "3 hours ago", "Yesterday" and so on. */
fun relative(millis: Long): String =
    DateUtils.getRelativeTimeSpanString(millis, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS, DateUtils.FORMAT_ABBREV_RELATIVE).toString()

fun mediumDateTime(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withZone(zone).format(instant)

fun String.capitalizedWords(): String = split(' ').joinToString(" ") { it.replaceFirstChar(Char::uppercase) }

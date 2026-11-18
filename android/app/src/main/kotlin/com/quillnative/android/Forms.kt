package com.quillnative.android

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.quillnative.core.Iso8601
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime

/** A rounded group of rows, like an inset grouped list. */
@Composable
fun Group(title: String? = null, footer: String? = null, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        title?.let {
            Text(it, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 16.dp, bottom = 6.dp))
        }
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
            Column { content() }
        }
        footer?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp))
        }
    }
}

private val rowColors @Composable get() = ListItemDefaults.colors(containerColor = Color.Transparent)

@Composable
fun RowDivider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))

/** A row that does something, with an optional value on the right. */
@Composable
fun ActionRow(title: String, value: String? = null, color: Color = Color.Unspecified, enabled: Boolean = true,
              trailing: (@Composable () -> Unit)? = null, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(title, color = if (enabled) color else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)) },
        trailingContent = trailing ?: value?.let { { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis) } },
        colors = rowColors,
        modifier = Modifier.clickable(enabled = enabled, onClick = onClick),
    )
}

@Composable
fun InfoRow(title: String, value: String) {
    ListItem(headlineContent = { Text(title) }, trailingContent = { Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis) }, colors = rowColors)
}

@Composable
fun SwitchRow(title: String, checked: Boolean, subtitle: String? = null, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = subtitle?.let { { Text(it) } },
        trailingContent = { Switch(checked, onCheckedChange = null) },
        colors = rowColors,
        modifier = Modifier.clickable { onChange(!checked) },
    )
}

/** A row whose value is picked from a short list. */
@Composable
fun <T> PickerRow(title: String, value: T, options: List<Pair<T, String>>, onPick: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row {
        ListItem(
            headlineContent = { Text(title) },
            trailingContent = {
                Column {
                    Text(options.firstOrNull { it.first == value }?.second ?: value.toString(), color = MaterialTheme.colorScheme.primary)
                    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                        for ((option, label) in options) DropdownMenuItem(text = { Text(label) }, onClick = { open = false; onPick(option) })
                    }
                }
            },
            colors = rowColors,
            modifier = Modifier.clickable { open = true },
        )
    }
}

/** A labeled text field inside a row, with its value on the right like a settings form. */
@Composable
fun FieldRow(
    title: String, value: String, placeholder: String = "", onChange: (String) -> Unit,
    keyboard: KeyboardType = KeyboardType.Text, words: Boolean = false, suffix: String? = null,
) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = MaterialTheme.typography.bodyLarge)
        Spacer(Modifier.width(16.dp))
        PlainField(value, onChange, placeholder, Modifier.weight(1f), keyboard = keyboard, words = words, align = TextAlign.End)
        suffix?.let { Text(" $it", color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

/** A text field without a box, for forms and the composer. */
@Composable
fun PlainField(
    value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier,
    keyboard: KeyboardType = KeyboardType.Text, words: Boolean = true, align: TextAlign = TextAlign.Start,
    singleLine: Boolean = true, minLines: Int = 1, style: androidx.compose.ui.text.TextStyle = MaterialTheme.typography.bodyLarge,
) {
    androidx.compose.material3.TextField(
        value = value, onValueChange = onChange, modifier = modifier,
        placeholder = { Text(placeholder, style = style, textAlign = align, modifier = Modifier.fillMaxWidth()) },
        textStyle = style.copy(textAlign = align),
        singleLine = singleLine, minLines = minLines,
        keyboardOptions = KeyboardOptions(
            keyboardType = keyboard,
            capitalization = if (words && keyboard == KeyboardType.Text) KeyboardCapitalization.Sentences else KeyboardCapitalization.None,
            autoCorrectEnabled = words && keyboard == KeyboardType.Text,
        ),
        colors = androidx.compose.material3.TextFieldDefaults.colors(
            focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent, disabledContainerColor = Color.Transparent,
            focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent, disabledIndicatorColor = Color.Transparent,
        ),
    )
}

/** A date and time kept as an ISO 8601 string. A value keeps the offset it was written with; a new one uses this device's time zone. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DateRow(title: String, value: String, onChange: (String) -> Unit) {
    val zone: ZoneId = Iso8601.parseOffset(value)?.offset ?: ZoneId.systemDefault()
    val current = Iso8601.parse(value) ?: Instant.now()
    var picking by remember { mutableStateOf(0) } // 0 closed, 1 date, 2 time
    var day by remember { mutableStateOf<LocalDate?>(null) }
    ActionRow(title, value = if (value.isEmpty()) "None" else mediumDateTime(current, zone)) { picking = 1 }
    if (picking == 1) {
        // The date picker works in UTC midnights.
        val state = rememberDatePickerState(initialSelectedDateMillis = current.atZone(zone).toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
        DatePickerDialog(
            onDismissRequest = { picking = 0 },
            confirmButton = {
                TextButton(onClick = {
                    day = state.selectedDateMillis?.let { Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() }
                    picking = 2
                }) { Text("Next") }
            },
            dismissButton = { TextButton(onClick = { picking = 0 }) { Text("Cancel") } },
        ) { DatePicker(state) }
    }
    if (picking == 2) {
        val time = current.atZone(zone).toLocalTime()
        val state = rememberTimePickerState(time.hour, time.minute)
        AlertDialog(
            onDismissRequest = { picking = 0 },
            confirmButton = {
                TextButton(onClick = {
                    val date = day ?: current.atZone(zone).toLocalDate()
                    val picked = ZonedDateTime.of(date, LocalTime.of(state.hour, state.minute), zone)
                    onChange(Iso8601.format(picked.toInstant(), zone))
                    picking = 0
                }) { Text("Done") }
            },
            dismissButton = { TextButton(onClick = { picking = 0 }) { Text("Cancel") } },
            text = { TimePicker(state) },
        )
    }
}

/** A dialog with one text field. */
@Composable
fun TextDialog(title: String, initial: String, action: String = "Save", label: String = title, keyboard: KeyboardType = KeyboardType.Text,
               onDismiss: () -> Unit, onDone: (String) -> Unit) {
    var value by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(value, { value = it }, label = { Text(label) }, keyboardOptions = KeyboardOptions(keyboardType = keyboard)) },
        confirmButton = { TextButton(onClick = { onDone(value) }) { Text(action) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}


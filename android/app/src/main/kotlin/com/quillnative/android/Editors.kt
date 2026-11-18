package com.quillnative.android

import android.annotation.SuppressLint
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.quillnative.core.MarkdownSpan
import com.quillnative.core.MarkdownStyle
import org.json.JSONObject

/** An editor that can take the composer's formatting commands. */
interface FormattingTarget {
    fun bold()
    fun italic()
    fun heading()
    fun link(url: String)
}

/** Formatting commands for the article editor, sent from the composer's action bar. */
class RichTextController {
    var target: FormattingTarget? = null
    fun bold() { target?.bold() }
    fun italic() { target?.italic() }
    fun heading() { target?.heading() }
    fun link(url: String) { target?.link(url) }
}

/**
 * Edits Markdown source with its formatting shown in place: the text stays Markdown,
 * and bold, headings, links and the rest are styled as you type, with their syntax faded.
 */
@Composable
fun MarkdownEditor(text: String, onChange: (String) -> Unit, controller: RichTextController, modifier: Modifier = Modifier) {
    var value by remember { mutableStateOf(TextFieldValue(text)) }
    if (value.text != text) value = value.copy(text = text, selection = TextRange(text.length.coerceAtMost(value.selection.end)))
    val colors = MaterialTheme.colorScheme
    val style = remember(colors) { MarkdownTransformation(colors.primary, colors.onSurfaceVariant, colors.surfaceContainerHighest) }

    fun apply(next: String, start: Int, end: Int = start) {
        value = TextFieldValue(next, TextRange(start, end))
        onChange(next)
    }
    DisposableEffect(controller) {
        controller.target = object : FormattingTarget {
            override fun bold() { val (t, s, e) = MarkdownStyle.wrap(value.text, value.selection.min, value.selection.max, "**"); apply(t, s, e) }
            override fun italic() { val (t, s, e) = MarkdownStyle.wrap(value.text, value.selection.min, value.selection.max, "*"); apply(t, s, e) }
            override fun heading() { val (t, c) = MarkdownStyle.heading(value.text, value.selection.max); apply(t, c) }
            override fun link(url: String) { val (t, c) = MarkdownStyle.link(value.text, value.selection.min, value.selection.max, url); apply(t, c) }
        }
        onDispose { controller.target = null }
    }
    BasicTextField(
        value = value,
        onValueChange = { value = it; if (it.text != text) onChange(it.text) },
        textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.onSurface, lineHeight = 26.sp),
        cursorBrush = SolidColor(colors.primary),
        visualTransformation = style,
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
        modifier = modifier.padding(horizontal = 20.dp, vertical = 12.dp).semantics { contentDescription = "Article" }.testTag("article.content"),
        decorationBox = { inner ->
            if (value.text.isEmpty()) Text("Write in Markdown", style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
            inner()
        },
    )
}

/** Styles Markdown in place. The characters stay the same, so offsets map one to one. */
private class MarkdownTransformation(val accent: Color, val faded: Color, val codeBackground: Color) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val source = text.text
        val styled = AnnotatedString.Builder(source)
        // Block styles first, so the marks inside them can still fade.
        val order = listOf(
            MarkdownSpan.Kind.HEADING1, MarkdownSpan.Kind.HEADING2, MarkdownSpan.Kind.HEADING3, MarkdownSpan.Kind.QUOTE, MarkdownSpan.Kind.CODE_BLOCK,
            MarkdownSpan.Kind.STRONG, MarkdownSpan.Kind.EMPHASIS, MarkdownSpan.Kind.STRIKETHROUGH, MarkdownSpan.Kind.CODE, MarkdownSpan.Kind.LINK, MarkdownSpan.Kind.MARKER,
        )
        for (span in MarkdownStyle.spans(source).sortedBy { order.indexOf(it.kind) }) {
            if (span.start < 0 || span.end > source.length || span.start >= span.end) continue
            styled.addStyle(style(span.kind), span.start, span.end)
        }
        return TransformedText(styled.toAnnotatedString(), OffsetMapping.Identity)
    }

    private fun style(kind: MarkdownSpan.Kind): SpanStyle = when (kind) {
        MarkdownSpan.Kind.HEADING1 -> SpanStyle(fontSize = 26.sp, fontWeight = FontWeight.Bold)
        MarkdownSpan.Kind.HEADING2 -> SpanStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold)
        MarkdownSpan.Kind.HEADING3 -> SpanStyle(fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
        MarkdownSpan.Kind.QUOTE -> SpanStyle(color = faded, fontStyle = FontStyle.Italic)
        MarkdownSpan.Kind.CODE_BLOCK, MarkdownSpan.Kind.CODE -> SpanStyle(fontFamily = FontFamily.Monospace, background = codeBackground)
        MarkdownSpan.Kind.STRONG -> SpanStyle(fontWeight = FontWeight.Bold)
        MarkdownSpan.Kind.EMPHASIS -> SpanStyle(fontStyle = FontStyle.Italic)
        MarkdownSpan.Kind.STRIKETHROUGH -> SpanStyle(textDecoration = TextDecoration.LineThrough)
        MarkdownSpan.Kind.LINK -> SpanStyle(color = accent)
        MarkdownSpan.Kind.MARKER -> SpanStyle(color = faded.copy(alpha = 0.6f))
    }
}

/**
 * Edits HTML as formatted text, in a WebView with an editable body. The HTML it gives back is
 * the browser's own serialization, so formatting it can't show is better kept by editing as HTML.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun RichEditor(html: String, onChange: (String) -> Unit, controller: RichTextController, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val last = remember { arrayOf<String?>(null) }
    val current = remember { arrayOf(onChange) }
    current[0] = onChange
    fun css(color: Color) = "#%06X".format(color.toArgb() and 0xFFFFFF)
    AndroidView(
        modifier = modifier.fillMaxSize().semantics { contentDescription = "Article" }.testTag("article.content"),
        factory = { context ->
            WebView(context).apply {
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                settings.javaScriptEnabled = true
                // The page is the person's own post. Nothing loads from the network but its images.
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: android.webkit.WebResourceRequest) = true
                }
                addJavascriptInterface(object {
                    @JavascriptInterface fun changed(value: String) { post { last[0] = value; current[0](value) } }
                }, "Quill")
                val page = """
                    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
                    <style>
                    html,body{margin:0;background:transparent}
                    body{font:17px/1.55 sans-serif;color:${css(colors.onSurface)};padding:12px 20px 48px;min-height:80vh;outline:none;caret-color:${css(colors.primary)}}
                    a{color:${css(colors.primary)}} img{max-width:100%;height:auto} blockquote{margin:0;padding-left:12px;border-left:3px solid ${css(colors.outlineVariant)};color:${css(colors.onSurfaceVariant)}}
                    body:empty:before{content:"Write";color:${css(colors.onSurfaceVariant)}}
                    </style></head><body contenteditable="true"></body>
                    <script>
                    let saved = null;
                    document.addEventListener('selectionchange', () => { const s = getSelection(); if (s.rangeCount && document.activeElement === document.body) saved = s.getRangeAt(0).cloneRange(); });
                    document.body.addEventListener('input', () => Quill.changed(document.body.innerHTML));
                    function restore() { document.body.focus(); if (saved) { const s = getSelection(); s.removeAllRanges(); s.addRange(saved); } }
                    function run(command, value) { restore(); document.execCommand(command, false, value || null); Quill.changed(document.body.innerHTML); }
                    function heading() {
                      restore();
                      const block = (document.queryCommandValue('formatBlock') || '').toLowerCase();
                      run('formatBlock', block === 'h2' ? 'h3' : block === 'h3' ? 'p' : 'h2');
                    }
                    function setContent(html) { document.body.innerHTML = html; }
                    </script></html>
                """.trimIndent()
                loadDataWithBaseURL("https://localhost/", page, "text/html", "utf-8", null)
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: android.webkit.WebResourceRequest) = true
                    override fun onPageFinished(view: WebView, url: String?) {
                        last[0] = html
                        view.evaluateJavascript("setContent(${JSONObject.quote(html)})", null)
                    }
                }
                controller.target = object : FormattingTarget {
                    override fun bold() = evaluateJavascript("run('bold')", null)
                    override fun italic() = evaluateJavascript("run('italic')", null)
                    override fun heading() = evaluateJavascript("heading()", null)
                    override fun link(url: String) = evaluateJavascript("run('createLink', ${JSONObject.quote(url)})", null)
                }
            }
        },
        update = { view ->
            // Only changes from outside the editor, such as a voice note, replace what is shown.
            if (last[0] != null && last[0] != html) {
                last[0] = html
                view.evaluateJavascript("setContent(${JSONObject.quote(html)})", null)
            }
        },
    )
}

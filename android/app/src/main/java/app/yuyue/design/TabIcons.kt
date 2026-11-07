package app.yuyue.design

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/** The tab bar icons: a line drawing, and the filled one for the tab that is on. */
object TabIcons {
    private const val SHELF = "M3.95 4.25h2.1a1.2 1.2 0 0 1 1.2 1.2v13.1a1.2 1.2 0 0 1-1.2 1.2h-2.1a1.2 1.2 0 0 1-1.2-1.2V5.45a1.2 1.2 0 0 1 1.2-1.2z" +
        "M9.95 6.75h2.1a1.2 1.2 0 0 1 1.2 1.2v10.6a1.2 1.2 0 0 1-1.2 1.2h-2.1a1.2 1.2 0 0 1-1.2-1.2V7.95a1.2 1.2 0 0 1 1.2-1.2z" +
        "M17.67 19.75 21.73 18.66 18.31 5.91 14.25 7Z"

    val shelf = icon("shelf") { line(SHELF) }
    val shelfOn = icon("shelf.on") { line(SHELF, filled = true) }

    val notes = icon("notes") {
        line("M7.35 3.75h9.3a2.6 2.6 0 0 1 2.6 2.6v11.3a2.6 2.6 0 0 1-2.6 2.6h-9.3a2.6 2.6 0 0 1-2.6-2.6V6.35a2.6 2.6 0 0 1 2.6-2.6zM8.5 8.75h7M8.5 12.25h7M8.5 15.75h4.5")
    }
    val notesOn = icon("notes.on") {
        fill(
            "M7.35 2.95H16.65A3.4 3.4 0 0 1 20.05 6.35V17.65A3.4 3.4 0 0 1 16.65 21.05H7.35A3.4 3.4 0 0 1 3.95 17.65V6.35A3.4 3.4 0 0 1 7.35 2.95Z" +
                "M9.3 7.95H14.7A0.8 0.8 0 0 1 15.5 8.75A0.8 0.8 0 0 1 14.7 9.55H9.3A0.8 0.8 0 0 1 8.5 8.75A0.8 0.8 0 0 1 9.3 7.95Z" +
                "M9.3 11.45H14.7A0.8 0.8 0 0 1 15.5 12.25A0.8 0.8 0 0 1 14.7 13.05H9.3A0.8 0.8 0 0 1 8.5 12.25A0.8 0.8 0 0 1 9.3 11.45Z" +
                "M9.3 14.95H12.2A0.8 0.8 0 0 1 13 15.75A0.8 0.8 0 0 1 12.2 16.55H9.3A0.8 0.8 0 0 1 8.5 15.75A0.8 0.8 0 0 1 9.3 14.95Z"
        )
    }

    val me = icon("me") {
        line("M12 4.5a3.75 3.75 0 1 1 0 7.5a3.75 3.75 0 1 1 0-7.5zM4.75 20.25c.7-3.9 3.5-6.25 7.25-6.25s6.55 2.35 7.25 6.25")
    }
    val meOn = icon("me.on") {
        fill("M12 3.7a4.55 4.55 0 1 1 0 9.1a4.55 4.55 0 1 1 0-9.1z")
        fill("M3.98 20.1c.78-4.35 3.9-7.1 8.02-7.1s7.24 2.75 8.02 7.1c.1.58-.34 1.1-.93 1.1H4.91c-.59 0-1.03-.52-.93-1.1z")
    }

    val search = icon("search") { line("M10.75 4.5a6.25 6.25 0 1 1 0 12.5a6.25 6.25 0 1 1 0-12.5zM15.5 15.5 20.25 20.25") }
    val searchOn = icon("search.on") { line("M10.75 4.75a6 6 0 1 1 0 12a6 6 0 1 1 0-12zM15.4 15.4 20 20", width = 2.4f) }

    private fun icon(name: String, build: ImageVector.Builder.() -> Unit) =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply(build).build()

    private fun ImageVector.Builder.line(d: String, filled: Boolean = false, width: Float = 1.6f) {
        addPath(
            addPathNodes(d),
            fill = if (filled) SolidColor(Color.Black) else null,
            stroke = SolidColor(Color.Black),
            strokeLineWidth = width,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        )
    }

    private fun ImageVector.Builder.fill(d: String) {
        addPath(addPathNodes(d), pathFillType = PathFillType.EvenOdd, fill = SolidColor(Color.Black))
    }
}

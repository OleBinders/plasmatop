/*
    AsciiBox.qml — shared/theme

    A panel frame drawn from real Unicode box-drawing characters
    (┌─┐│└─┘), like a terminal TUI (btop/vtop/gtop) draws its boxes —
    not a rounded QML Rectangle border.

    The title is set into the top border, e.g.:
        ┌─ GPU ──────────────────┐
        │ ...content...          │
        └──────────────────────--┘

    Usage — content is declared as plain children, like any container:
        AsciiBox {
            anchors.fill: parent
            title: "GPU"
            ColumnLayout {
                anchors.fill: parent
                ...
            }
        }

    Implementation note: the side borders are a column of "│" glyphs
    clipped to the box height, rather than one glyph per actual content
    text row (which would require laying out the inner content on a true
    character grid, i.e. reimplementing a terminal renderer). That's a
    deliberate simplification -- purely decorative framing, not a real
    terminal -- and reads correctly because the glyphs are opaque and
    evenly spaced regardless of what the content inside is doing.
*/

import QtQuick

Item {
    id: root

    property string title: ""
    property color borderColor: "#606060"
    property color titleColor: "#eeeeee"

    // Optional second text slot in the top border row, right-aligned
    // before the closing corner -- e.g. "┌─ GPU ────── 1200 MHz ┐". Added
    // per R6 item 4 (bashtop shows clock speed once, in the box's
    // header/identity area next to the title, not as a repeated/tabular
    // stat). "" (default) collapses back to the plain dash-filled border,
    // identical to every AsciiBox usage that predates this property.
    property string trailingText: ""
    property color trailingColor: titleColor
    // Solid background -- a real terminal's box interior is opaque, not a
    // frosted/translucent Plasma card.
    property color backgroundColor: "#000000"
    property int padding: 8

    // Fixed monospace size for the border glyphs (independent of content
    // font size) -- keeps corners/dashes/pipes crisp and evenly spaced.
    property int borderPixelSize: 13

    // Plain children declared on an AsciiBox go here, like any normal
    // container (Item's own default property is `data`; this just
    // redirects it to the inset content area instead of root itself).
    default property alias contentData: contentSlot.data

    FontMetrics {
        id: fm
        font.family: "monospace"
        font.pixelSize: root.borderPixelSize
    }

    Rectangle {
        anchors.fill: parent
        color: root.backgroundColor
    }

    // --- Top border: "┌─ Title ────┐" -- the dash run's length is
    // computed from the remaining pixel width divided by the monospace
    // character width, so it always exactly fills the box at any size.
    // Works identically when title is "" (collapses to "┌───────┐"). ---
    Row {
        id: topRow
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: fm.height

        Text {
            id: prefixText
            text: "┌─" + (root.title.length > 0 ? " " : "")
            font: fm.font
            color: root.borderColor
        }
        Text {
            id: titleText
            text: root.title
            // Can't combine "font: fm.font" (whole grouped-property assign)
            // with "font.bold: true" (sub-property assign) on the same
            // element -- QML rejects that as a duplicate assignment to the
            // grouped `font` property. Set the two sub-properties we need
            // individually instead.
            font.family: fm.font.family
            font.pixelSize: fm.font.pixelSize
            font.bold: true
            color: root.titleColor
        }
        Text {
            id: suffixText
            text: root.title.length > 0 ? " " : ""
            font: fm.font
            color: root.borderColor
        }
        Text {
            id: topDashFill
            width: Math.max(0, topRow.width - prefixText.width - titleText.width - suffixText.width
                - trailingPrefixSpace.width - trailingTextItem.width - trailingSuffixSpace.width
                - topRightCorner.width)
            height: fm.height
            font: fm.font
            color: root.borderColor
            text: "─".repeat(Math.max(0, Math.floor(width / Math.max(1, fm.advanceWidth("─")))))
            clip: true
        }
        Text {
            id: trailingPrefixSpace
            text: root.trailingText.length > 0 ? " " : ""
            font: fm.font
            color: root.borderColor
        }
        Text {
            id: trailingTextItem
            text: root.trailingText
            font.family: fm.font.family
            font.pixelSize: fm.font.pixelSize
            font.bold: true
            color: root.trailingColor
        }
        Text {
            id: trailingSuffixSpace
            text: root.trailingText.length > 0 ? " " : ""
            font: fm.font
            color: root.borderColor
        }
        Text {
            id: topRightCorner
            text: "┐"
            font: fm.font
            color: root.borderColor
        }
    }

    // --- Bottom border: "└──────────┘" ---
    Row {
        id: bottomRow
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: fm.height

        Text {
            id: bottomLeftCorner
            text: "└"
            font: fm.font
            color: root.borderColor
        }
        Text {
            id: bottomDashFill
            width: Math.max(0, bottomRow.width - bottomLeftCorner.width - bottomRightCorner.width)
            height: fm.height
            font: fm.font
            color: root.borderColor
            text: "─".repeat(Math.max(0, Math.floor(width / Math.max(1, fm.advanceWidth("─")))))
            clip: true
        }
        Text {
            id: bottomRightCorner
            text: "┘"
            font: fm.font
            color: root.borderColor
        }
    }

    // --- Side borders: a column of "│" clipped to the box height. ---
    Text {
        anchors.top: topRow.bottom
        anchors.bottom: bottomRow.top
        anchors.left: parent.left
        width: fm.advanceWidth("│")
        clip: true
        font: fm.font
        color: root.borderColor
        text: Array(200).fill("│").join("\n")
        lineHeight: fm.lineSpacing
    }
    Text {
        anchors.top: topRow.bottom
        anchors.bottom: bottomRow.top
        anchors.right: parent.right
        width: fm.advanceWidth("│")
        clip: true
        font: fm.font
        color: root.borderColor
        text: Array(200).fill("│").join("\n")
        lineHeight: fm.lineSpacing
    }

    // --- Real widget content, inset from the ASCII frame. ---
    Item {
        id: contentSlot
        anchors.top: topRow.bottom
        anchors.bottom: bottomRow.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: fm.advanceWidth("│") + root.padding
        anchors.rightMargin: fm.advanceWidth("│") + root.padding
        anchors.topMargin: root.padding / 2
        anchors.bottomMargin: root.padding / 2
    }
}

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Details panel for the Microsoft Dev Blogs bar widget: the ten most recent
// posts from https://devblogs.microsoft.com/landing/, newest first.
// Clicking a post opens its canonical link in the default browser; nothing
// here ever renders full article content.
//
// BarWidget.qml owns feed polling and hands this panel the already-parsed
// post list plus the button to anchor against.
Panel {
  id: root
  moduleName: "sinannar.omarchy.plugin.msftdevblogs"
  ipcTarget: "sinannar.omarchy.plugin.msftdevblogs"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var posts: []

  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Re-poll the feed the moment the panel is opened, so a bar that is up to
  // pollIntervalSec stale never shows a stale post list once the user
  // actually looks.
  function requestBarRefresh() {
    if (root.hostWidget && typeof root.hostWidget.refresh === "function") root.hostWidget.refresh()
  }

  onOpenedChanged: if (opened) requestBarRefresh()

  // A relative-if-recent, absolute-otherwise timestamp: "just now" reads
  // more usefully than an absolute time for something that just happened,
  // but a post from last week benefits from an actual date. Pure
  // date-arithmetic; Qt.formatDateTime handles only the far branch, since it
  // has no notion of "3 hours ago".
  function formatPostDate(pubDateMs) {
    if (pubDateMs === null || pubDateMs === undefined || !isFinite(pubDateMs)) return ""
    var deltaMs = Date.now() - pubDateMs
    if (deltaMs < 0) deltaMs = 0
    var minutes = Math.floor(deltaMs / 60000)
    if (minutes < 1) return "just now"
    if (minutes < 60) return minutes + " min ago"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + " hour" + (hours === 1 ? "" : "s") + " ago"
    var days = Math.floor(hours / 24)
    if (days < 7) return days + " day" + (days === 1 ? "" : "s") + " ago"
    return Qt.formatDateTime(new Date(pubDateMs), "d MMM yyyy")
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: column.width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(14)

          Item {
            width: parent.width
            height: Math.max(titleColumn.implicitHeight, refreshBtn.implicitHeight)

            Column {
              id: titleColumn
              anchors.left: parent.left
              anchors.right: refreshBtn.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                text: "Microsoft Dev Blogs"
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                text: root.posts.length === 0
                  ? "No posts loaded yet"
                  : root.posts.length + " recent post" + (root.posts.length === 1 ? "" : "s")
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Button {
              id: refreshBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Refresh"
              fontFamily: root.contentFontFamily
              foreground: root.contentForeground
              bordered: true
              onClicked: root.requestBarRefresh()
            }
          }

          PanelSeparator {
            foreground: root.contentForeground
          }

          Column {
            visible: root.posts.length > 0
            width: column.width
            spacing: Style.space(2)

            Repeater {
              model: root.posts

              PostRow {
                width: column.width
                post: modelData
                contentForeground: root.contentForeground
                contentFontFamily: root.contentFontFamily
                dateText: root.formatPostDate(modelData.pubDateMs)
              }
            }
          }

          Text {
            visible: root.posts.length === 0
            width: parent.width
            text: root.hostWidget && root.hostWidget.lastPollFailed
              ? "The Microsoft Dev Blogs feed is unavailable right now. Click Refresh to retry."
              : "Loading recent posts…"
            textFormat: Text.PlainText
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // One clickable row per post: title, then a byline of author/category/date
  // where each part is present. The whole row opens the post's link.
  component PostRow: Rectangle {
    id: row

    required property var post
    property color contentForeground: Color.foreground
    property string contentFontFamily: Style.font.family
    property string dateText: ""

    readonly property string byline: {
      var parts = []
      if (row.post && row.post.author) parts.push(row.post.author)
      if (row.post && row.post.category) parts.push(row.post.category)
      if (row.dateText) parts.push(row.dateText)
      return parts.join(" · ")
    }

    height: rowColumn.implicitHeight + Style.space(16)
    radius: Style.space(6)
    color: rowArea.containsMouse ? Qt.rgba(row.contentForeground.r, row.contentForeground.g, row.contentForeground.b, 0.08) : "transparent"

    Column {
      id: rowColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: row.post ? row.post.title : ""
        textFormat: Text.PlainText
        color: row.contentForeground
        font.family: row.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Text {
        visible: row.byline !== ""
        width: parent.width
        text: row.byline
        textFormat: Text.PlainText
        color: Qt.darker(row.contentForeground, 1.4)
        font.family: row.contentFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: row.post && row.post.url !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (row.post && Model.isSafeHttpUrl(row.post.url)) Qt.openUrlExternally(row.post.url)
    }
  }
}

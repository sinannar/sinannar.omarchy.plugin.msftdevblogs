import QtQuick
import QtQuick.Controls
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

  // Categories pinned from this widget's inline shell.json entry, normalized
  // (bounded, de-duplicated, case/whitespace-folded keys). Empty means no
  // filter — every retained post is shown.
  readonly property var pinnedCategoryKeys: Model.normalizePinnedCategories(root.setting("pinnedCategories", []))
  // Every category seen across the currently retained posts, ordered by
  // first (most recent) occurrence — this is the full chip list, independent
  // of any active filter.
  readonly property var availableCategories: Model.aggregateCategories(root.posts)
  // The posts actually rendered below: all retained posts when nothing is
  // pinned, otherwise only posts matching at least one pinned category.
  readonly property var displayPosts: Model.selectDisplayPosts(root.posts, root.pinnedCategoryKeys)

  // Persists a full pin list to this widget's inline shell.json entry,
  // matching the update-entry pattern used by built-in panels (clock's
  // persistSettings, tailscale's persistRecentMullvad): merge the changed
  // key into a clone of the current settings, apply it locally to both this
  // panel and its host bar widget for an immediate UI update, then push the
  // merged entry through the shell so it survives reloads/restarts.
  function persistPinnedCategories(keys) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry.pinnedCategories = keys

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function togglePin(categoryKey) {
    var current = root.pinnedCategoryKeys
    var index = current.indexOf(categoryKey)
    var next = index === -1 ? current.concat([categoryKey]) : current.slice(0, index).concat(current.slice(index + 1))
    root.persistPinnedCategories(Model.normalizePinnedCategories(next))
  }

  function clearPins() {
    root.persistPinnedCategories([])
  }

  // "Filters" reads as a plain label when nothing is pinned, or gets a
  // count suffix once one or more categories are pinned — the only
  // filter-state indicator visible in the main panel now that the full
  // category list lives in a popup instead of an always-expanded row.
  readonly property string filtersButtonText: root.pinnedCategoryKeys.length === 0
    ? "Filters"
    : "Filters (" + root.pinnedCategoryKeys.length + ")"

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

  // Closing the panel always closes any open category picker with it, so
  // reopening the panel later never resumes with a stray popup visible.
  onOpenedChanged: {
    if (opened) requestBarRefresh()
    else if (categoryPopup.opened) categoryPopup.close()
  }

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
            id: headerRow
            width: parent.width
            height: Math.max(titleColumn.implicitHeight, refreshBtn.implicitHeight, filtersBtn.implicitHeight)

            Column {
              id: titleColumn
              anchors.left: parent.left
              anchors.right: filtersBtn.visible ? filtersBtn.left : refreshBtn.left
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
                  : (root.pinnedCategoryKeys.length === 0
                      ? root.posts.length + " recent post" + (root.posts.length === 1 ? "" : "s")
                      : root.displayPosts.length + " of " + root.posts.length + " recent posts")
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // Replaces the always-expanded category chip row: a single
            // compact control that opens a bounded, scrollable popup with
            // the full category list, keeping the panel's height stable
            // however many categories the feed happens to publish. The
            // button label itself carries the only filter-state summary
            // ("Filters" vs "Filters (N)") needed in the main panel.
            Button {
              id: filtersBtn
              visible: root.availableCategories.length > 0
              anchors.right: refreshBtn.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.filtersButtonText
              fontFamily: root.contentFontFamily
              foreground: root.contentForeground
              bordered: true
              onClicked: categoryPopup.opened ? categoryPopup.close() : categoryPopup.open()
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

            Popup {
              id: categoryPopup
              x: filtersBtn.x + filtersBtn.width - width
              y: filtersBtn.y + filtersBtn.height + Style.space(4)
              width: Style.space(300)
              height: Math.min(popupColumn.implicitHeight + Style.space(16), Style.space(360))
              padding: Style.space(8)
              modal: false
              focus: true
              closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

              background: BorderSurface {
                color: Color.popups.background
                borderSpec: Border.flat(Qt.darker(root.contentForeground, 1.6), 1)
                radius: Style.cornerRadius
              }

              contentItem: Flickable {
                id: popupFlick
                width: parent.width
                contentWidth: width
                contentHeight: popupColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                Column {
                  id: popupColumn
                  width: popupFlick.width
                  spacing: Style.space(8)

                  PanelSectionHeader {
                    text: "Categories"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                  }

                  Flow {
                    width: popupColumn.width
                    spacing: Style.space(6)

                    // "All" clears any pins and shows every retained post;
                    // it reads as pinned itself whenever no category is
                    // currently pinned, so exactly one chip here is always
                    // active.
                    Rectangle {
                      id: allChip
                      readonly property bool pinned: root.pinnedCategoryKeys.length === 0
                      width: allLabel.implicitWidth + Style.space(16)
                      height: allLabel.implicitHeight + Style.space(8)
                      radius: Style.space(6)
                      color: allChip.pinned ? root.contentForeground : "transparent"
                      border.width: allChip.pinned ? 0 : 1
                      border.color: Qt.darker(root.contentForeground, 1.6)

                      Text {
                        id: allLabel
                        anchors.centerIn: parent
                        text: "All"
                        textFormat: Text.PlainText
                        color: allChip.pinned ? Color.popups.background : root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.clearPins()
                      }
                    }

                    // Category chips are written inline here (not as a
                    // separately declared `component`) so `modelData` binds
                    // directly — the same nested-component pitfall
                    // documented on the post-row Repeater below only bites
                    // when a named component type is instantiated as the
                    // delegate itself.
                    Repeater {
                      model: root.availableCategories

                      Rectangle {
                        id: chip
                        required property var modelData
                        readonly property bool pinned: root.pinnedCategoryKeys.indexOf(chip.modelData.key) !== -1
                        width: chipLabel.implicitWidth + Style.space(16)
                        height: chipLabel.implicitHeight + Style.space(8)
                        radius: Style.space(6)
                        color: chip.pinned ? root.contentForeground : "transparent"
                        border.width: chip.pinned ? 0 : 1
                        border.color: Qt.darker(root.contentForeground, 1.6)

                        Text {
                          id: chipLabel
                          anchors.centerIn: parent
                          text: chip.modelData.name
                          textFormat: Text.PlainText
                          color: chip.pinned ? Color.popups.background : root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                        }

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.togglePin(chip.modelData.key)
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.contentForeground
          }

          Column {
            visible: root.displayPosts.length > 0
            width: column.width
            spacing: Style.space(2)

            Repeater {
              model: root.displayPosts

              // `modelData`/`index` don't bind into a nested `component`
              // declaration used directly as a Repeater delegate — a plain
              // wrapper Item takes them as required properties and passes
              // them down explicitly instead (same shape as the network
              // widget's Wi-Fi list delegate).
              delegate: Item {
                id: wrapper
                required property var modelData
                required property int index
                width: column.width
                height: postRow.height

                PostRow {
                  id: postRow
                  width: wrapper.width
                  post: wrapper.modelData
                  contentForeground: root.contentForeground
                  contentFontFamily: root.contentFontFamily
                  dateText: root.formatPostDate(wrapper.modelData.pubDateMs)
                }
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

          Text {
            visible: root.posts.length > 0 && root.displayPosts.length === 0
            width: parent.width
            text: "No recent posts match the pinned categories. Click All to clear the filter."
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

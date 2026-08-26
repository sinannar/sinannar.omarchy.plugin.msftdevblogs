import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar presence for the Microsoft for Developers RSS feed
// (https://devblogs.microsoft.com/landing/). This widget only ever fetches
// and displays the feed's own posts — it never remembers read/unread state
// or filters by category.
//
// BarWidget.qml owns feed retrieval and polling; Panel.qml owns rendering
// the post list and opening posts in the browser.
BarWidget {
  id: root
  moduleName: "sinannar.omarchy.plugin.msftdevblogs"

  readonly property string feedUrl: "https://devblogs.microsoft.com/landing/"
  readonly property int pollIntervalSec: Math.max(60, Number(setting("pollIntervalSec", 900)))

  // Last successfully parsed posts, newest first. Kept even while a refresh
  // is in flight (and across a failed refresh) so the bar/panel never blank
  // out mid-poll or after a transient network hiccup.
  property var posts: []
  property bool loading: false
  property bool lastPollFailed: false
  property bool everPolled: false
  property string feedStdoutText: ""
  property string feedStderrText: ""

  readonly property var latestPost: posts.length > 0 ? posts[0] : null

  readonly property color statusColor: {
    if (!everPolled || lastPollFailed) return Qt.darker(bar ? bar.foreground : Color.foreground, 1.5)
    return bar ? bar.foreground : Color.foreground
  }

  function refresh() {
    if (feedProcess.running) return
    root.loading = true
    root.feedStdoutText = ""
    root.feedStderrText = ""
    feedProcess.running = true
  }

  Process {
    id: feedProcess
    command: ["curl", "-fsSL", "--max-time", "10", root.feedUrl]

    // Collect incrementally with a hard cap so memory stays bounded even if
    // the feed emits unexpectedly large output.
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.feedStdoutText = Model.appendCapped(root.feedStdoutText, data) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.feedStderrText = Model.appendCapped(root.feedStderrText, data) }
    }

    onExited: function(exitCode) {
      root.loading = false
      root.everPolled = true
      if (exitCode !== 0) {
        // Keep the last good snapshot on a transient failure (network down,
        // curl missing, feed temporarily unreachable) rather than flashing
        // to empty.
        root.lastPollFailed = true
        return
      }
      // A capped response (root.feedStdoutText hit MAX_OUTPUT_CHARS) means
      // the feed was truncated mid-stream, not that it has zero posts.
      // Treat that as a poll failure — keep the last good snapshot — rather
      // than letting a resulting empty parse blank the panel.
      if (Model.wasCapped(root.feedStdoutText)) {
        var parsed = Model.parseFeed(root.feedStdoutText)
        if (parsed.length === 0) {
          root.lastPollFailed = true
          return
        }
      }
      var posts = Model.parseFeed(root.feedStdoutText)
      if (posts.length === 0) {
        // An empty parse of a non-truncated response is treated the same
        // way: a malformed/unexpected document is more likely than the feed
        // genuinely publishing zero posts, so the last good snapshot is
        // kept rather than shown as "no posts".
        root.lastPollFailed = true
        return
      }
      root.lastPollFailed = false
      root.posts = posts
    }
  }

  Timer {
    interval: root.pollIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("posts" in target) target.posts = root.posts
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onPostsChanged: injectPanel()

  Component.onCompleted: refresh()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "sinannar.omarchy.plugin.msftdevblogs"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-fa-laptop: the bar renders through JetBrainsMono Nerd Font, which
    // has no color-emoji fallback glyph, so a plain emoji here rendered as
    // a blank/missing-glyph box. A Nerd Font codepoint from the same font
    // renders correctly and reads as "developer machine".
    text: "\uf109"
    foreground: root.statusColor
    tooltipText: root.lastPollFailed
      ? "Microsoft Dev Blogs feed unavailable — click to retry"
      : (root.latestPost ? root.latestPost.title : "Loading Microsoft Dev Blogs…")

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}

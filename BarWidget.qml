import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar presence for the Microsoft for Developers RSS feed
// (https://devblogs.microsoft.com/landing/). This widget only ever fetches
// the feed's own posts — it never remembers read/unread state. Category
// pinning (Panel.qml) filters which of the retained posts are displayed,
// but every fetched post is still retained here regardless of pins, so
// unpinning a category never requires a re-fetch to bring its posts back.
//
// BarWidget.qml owns feed retrieval and polling; Panel.qml owns rendering
// the post list, category pin controls, and opening posts in the browser.
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
  readonly property var latestPost: posts.length > 0 ? posts[0] : null

  readonly property color statusColor: {
    if (!everPolled || lastPollFailed) return Qt.darker(bar ? bar.foreground : Color.foreground, 1.5)
    return bar ? bar.foreground : Color.foreground
  }

  function refresh() {
    if (feedProcess.running) return
    root.loading = true
    feedStdout.reset()
    feedStderr.reset()
    feedProcess.running = true
  }

  Process {
    id: feedProcess
    // --location with zero permitted redirects rejects redirects explicitly;
    // --max-filesize bounds bytes before they enter the shell process.
    command: [
      "curl", "-fsSL", "--max-time", "10",
      "--max-filesize", String(Model.MAX_RESPONSE_BYTES),
      "--max-redirs", "0", root.feedUrl
    ]

    // These collectors independently bound retained process output before
    // parseFeed sees it. Both streams are capped to avoid error-output growth.
    stdout: BoundedStreamCollector { id: feedStdout }
    stderr: BoundedStreamCollector { id: feedStderr }

    onExited: function(exitCode) {
      root.loading = false
      root.everPolled = true
      if (exitCode !== 0 || feedStdout.overflowed || feedStderr.overflowed) {
        // Keep the last good snapshot on a transient failure (network down,
        // curl missing, oversized/redirected response, or unavailable feed)
        // rather than flashing to empty.
        root.lastPollFailed = true
        return
      }
      var posts = Model.parseFeed(feedStdout.text)
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

  // BarIconButton (not the plain WidgetButton) for a single glyph: it centers
  // through OpticalGlyph's tight-bounding-box math rather than raw advance
  // width, which is what every other icon-only bar widget (bluetooth,
  // network, monitor, microphone) uses. A plain WidgetButton centers the
  // glyph in its full advance width, which for most Nerd Font icons paints
  // visibly off-center relative to the module's own open-panel underline.
  BarIconButton {
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

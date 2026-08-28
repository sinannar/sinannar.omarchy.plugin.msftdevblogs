import QtQuick
import Quickshell.Io
import "Model.js" as Model

// A streaming collector that never retains more than the configured response
// budget. An empty split marker passes each process read straight through,
// avoiding SplitParser's delimiter buffer.
SplitParser {
  id: root

  readonly property int maximumChars: Model.MAX_OUTPUT_CHARS
  property string text: ""
  property bool overflowed: false

  splitMarker: ""

  function reset() {
    root.text = ""
    root.overflowed = false
  }

  onRead: function(data) {
    var chunk = String(data === undefined || data === null ? "" : data)
    if (chunk === "") return

    var remaining = root.maximumChars - root.text.length
    if (remaining <= 0) {
      root.overflowed = true
      return
    }
    if (chunk.length > remaining) root.overflowed = true
    root.text = Model.appendCapped(root.text, chunk)
  }
}

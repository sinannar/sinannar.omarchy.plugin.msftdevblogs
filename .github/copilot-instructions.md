# Microsoft Dev Blogs Omarchy plugin

This is a user-owned Omarchy/Quickshell bar plugin. `manifest.json` registers
`BarWidget.qml`; keep its module ID and the `IpcHandler` surface aligned with
the panel. Plugin files reload through Omarchy's shell, but validate QML
before relying on that behavior.

## Architecture

- `BarWidget.qml` owns RSS polling, the curl `Process`, state, and IPC.
- `Panel.qml` renders, filters categories, and opens post URLs.
- `Model.js` owns RSS parsing, normalization, and bounded collection helpers.
  It must stay Qt-free and CommonJS-loadable under plain Node. Do not move
  parsing logic into QML.

## Safety invariants

- Invoke curl only as an argv array, including `-fsSL`, `--max-time 10`,
  `--max-filesize 1048576`, and `--max-redirs 0`. Never introduce a shell,
  shell interpolation, or a concatenated command string.
- Route stdout and stderr through `BoundedStreamCollector`; preserve its 1 MiB
  consumer-side bound independently of curl's producer-side size limit. On a
  curl failure, collector overflow, or parse failure, keep the last good posts
  rather than clearing the UI.
- Retain parser scan, rendered-post, and pinned-category limits: 200, 10,
  and 20 respectively.
- Pass a feed URL to `Qt.openUrlExternally` only after
  `Model.isSafeHttpUrl` permits `http` or `https`.
- Every `Text` whose value can derive from the feed must use
  `textFormat: Text.PlainText`. Do not persist read/unread state or expose
  untrusted raw feed output.

## Validation

Run the smallest relevant checks:

```bash
checks/validate.sh       # Omarchy plugin validation and qmllint
checks/run-inspect.sh    # confirm the installed plugin entry
```

For `Model.js`, use focused Node probes; no test framework is assumed:

```bash
node -e 'const M=require("./Model.js"); console.log(M.parseFeed("<rss/>"))'
node -e 'const M=require("./Model.js"); console.log(M.appendCapped("", "x"))'
```

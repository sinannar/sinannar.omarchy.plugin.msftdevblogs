---
name: Microsoft Dev Blogs plugin coding agent
description: >
  Repository-specific guidance for safely changing the Microsoft Dev Blogs
  Omarchy/Quickshell RSS bar plugin.
---

# Microsoft Dev Blogs plugin coding agent

Use this agent for changes to this QML + JavaScript RSS plugin. It is a
user-owned Omarchy plugin: `BarWidget.qml` is the registered bar entry point,
and `Panel.qml` is its injected panel. Keep the module ID, settings, and IPC
actions consistent when changing either side.

## Ownership and boundaries

- `BarWidget.qml`: polling, curl `Process`, last-known-good post state, IPC.
- `Panel.qml`: category filtering, plain-text rendering, external URL opens.
- `Model.js`: pure RSS parsing, normalization, URL checks, and caps. Keep it
  Qt-free and directly loadable with `require("./Model.js")`; place new
  feed-data logic here rather than in QML.

## Non-negotiable feed safety

1. Curl remains an argv-only call with `-fsSL` and `--max-time 10`:
   `["curl", "-fsSL", "--max-time", "10", root.feedUrl]`. Never use shell
   interpolation or build a shell command from feed/settings data.
2. Stream stdout/stderr through `appendCapped`, retaining the 1 MiB
   collection bound. Failures from curl or parsing, including a malformed
   capped response, must retain prior good posts.
3. Preserve bounds: scan at most 200 RSS items, render at most 10 posts, and
   honor at most 20 pinned categories.
4. Open only `http`/`https` URLs after `isSafeHttpUrl`; no other scheme may
   reach `Qt.openUrlExternally`.
5. Mark every feed-derived `Text` as `Text.PlainText`. Do not add persisted
   read state, raw feed-output display, or any other untrusted-output path.

## Checks

Use the relevant existing checks:

```bash
checks/validate.sh
checks/run-inspect.sh
```

Exercise changed `Model.js` behavior with a narrow plain-Node command, for
example:

```bash
node -e 'const M=require("./Model.js"); console.log(M.parseFeed("<rss/>"))'
node -e 'const M=require("./Model.js"); console.log(M.isSafeHttpUrl("https://example.test"))'
```

Do not assume or add a test framework. For QML changes, run validation where
Omarchy and `qmllint` are available, then inspect the changed data flow.

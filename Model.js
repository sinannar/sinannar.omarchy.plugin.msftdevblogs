// Pure RSS-parsing and normalization math for the Microsoft Dev Blogs
// widget and its post-list panel. Everything here is Qt-free so it can be
// unit tested under node; the QML owns process invocation, polling, and
// rendering only.
//
// The feed (https://devblogs.microsoft.com/landing/) is a standard RSS 2.0
// document. Rather than pull in an XML parser dependency, item fields are
// pulled out with small, targeted regexes — the fields this plugin reads
// (title, link, pubDate, dc:creator, category, guid) are simple leaf
// elements that don't nest, which is what makes that safe to do here.

// ---- Response caps ---------------------------------------------------------
// A malicious or unexpectedly bloated feed response can't exhaust memory in
// the long-lived shell process. curl enforces MAX_RESPONSE_BYTES before it
// reaches QML; BoundedStreamCollector.qml independently caps retained text.
//
// MAX_RESPONSE_BYTES – bytes curl accepts from the response body.
// MAX_OUTPUT_CHARS – UTF-16 code units retained by the QML stream collector.
//   The feed is mostly ASCII, so the two limits intentionally share a 1 MiB
//   budget.
// MAX_ITEMS_SCANNED – <item> blocks read out of the raw XML before giving up.
// MAX_POSTS         – posts ever *displayed* in the panel at once, after
//   de-duplication, sorting, and any category filtering.
// MAX_PINNED_CATEGORIES – category pins ever honored from a persisted
//   setting, so a hand-edited or corrupted shell.json entry can't make
//   filtering scale with an attacker-chosen list length.
var MAX_RESPONSE_BYTES = 1 * 1024 * 1024
var MAX_OUTPUT_CHARS = MAX_RESPONSE_BYTES
var MAX_ITEMS_SCANNED = 200
var MAX_POSTS = 10
var MAX_PINNED_CATEGORIES = 20

function capOutput(text) {
  var s = String(text === undefined || text === null ? "" : text)
  if (s.length > MAX_OUTPUT_CHARS) return s.substring(0, MAX_OUTPUT_CHARS)
  return s
}

// Appends a stream chunk while preserving a hard MAX_OUTPUT_CHARS cap, for
// QML stream parsers to bound memory *during collection*, not only after
// process exit.
function appendCapped(existing, chunk) {
  var current = String(existing === undefined || existing === null ? "" : existing)
  if (current.length >= MAX_OUTPUT_CHARS) return current
  var next = String(chunk === undefined || chunk === null ? "" : chunk)
  if (next === "") return current
  var remaining = MAX_OUTPUT_CHARS - current.length
  if (next.length > remaining) next = next.substring(0, remaining)
  return current + next
}

// True if a collected string hit the hard MAX_OUTPUT_CHARS boundary, meaning
// the feed likely sent more than was retained. Callers use this to tell
// "the server sent nothing/garbage" apart from "a real response was cut off
// mid-stream", so a resulting parse failure keeps the last-known-good posts
// instead of blanking the panel.
function wasCapped(text) {
  return String(text === undefined || text === null ? "" : text).length >= MAX_OUTPUT_CHARS
}

// Only http/https links are ever surfaced or opened by this plugin — other
// schemes could trigger unintended external-handler behavior when passed to
// Qt.openUrlExternally, so anything else is dropped.
function isSafeHttpUrl(url) {
  return typeof url === "string" && /^https?:\/\//i.test(String(url).trim())
}

// Decodes the handful of entities RSS text actually uses. Numeric entities
// (decimal and hex) are decoded generically; anything malformed is left as
// literal text rather than throwing.
function decodeEntities(text) {
  var s = String(text === undefined || text === null ? "" : text)
  s = s.replace(/&#x([0-9a-fA-F]+);/g, function(_, hex) {
    var code = parseInt(hex, 16)
    return isFinite(code) ? String.fromCodePoint(code) : _
  })
  s = s.replace(/&#(\d+);/g, function(_, dec) {
    var code = parseInt(dec, 10)
    return isFinite(code) ? String.fromCodePoint(code) : _
  })
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&")
}

// Strips a CDATA wrapper if present, otherwise decodes XML entities. RSS
// producers use one or the other for text content, never both at once.
function unwrapText(raw) {
  var s = String(raw === undefined || raw === null ? "" : raw).trim()
  var cdata = /^<!\[CDATA\[([\s\S]*?)\]\]>$/.exec(s)
  if (cdata) return cdata[1].trim()
  return decodeEntities(s)
}

// Strips any HTML tags left in a title/description after CDATA unwrapping —
// dc:creator and title are supposed to be plain text, but a feed producer
// occasionally leaks markup into them.
function stripTags(text) {
  return String(text === undefined || text === null ? "" : text).replace(/<[^>]*>/g, "").trim()
}

// Splits raw feed XML into individual <item>...</item> blocks. Namespaced
// root elements (rss/channel) are irrelevant to this: items are always a
// flat, non-nested run of siblings under <channel>. Capped at
// MAX_ITEMS_SCANNED so a pathological feed can't cause unbounded work.
function extractItemBlocks(xmlText) {
  var text = capOutput(xmlText)
  var blocks = []
  var re = /<item\b[^>]*>([\s\S]*?)<\/item>/gi
  var match
  while ((match = re.exec(text)) !== null && blocks.length < MAX_ITEMS_SCANNED) {
    blocks.push(match[1])
  }
  return blocks
}

// Extracts the first `<tagName>...</tagName>` (or self-namespaced
// `<ns:tagName>...</ns:tagName>`) from one item block, unwrapped/decoded.
// Returns "" when the tag is missing rather than throwing.
function extractTag(itemXml, tagName) {
  var escaped = String(tagName).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  var re = new RegExp("<" + escaped + "\\b[^>]*>([\\s\\S]*?)<\\/" + escaped + ">", "i")
  var match = re.exec(String(itemXml || ""))
  return match ? unwrapText(match[1]) : ""
}

// Extracts every `<category>` entry in one item block, decoded and
// tag-stripped. A feed with none yields an empty array.
function extractCategories(itemXml) {
  var text = String(itemXml || "")
  var re = /<category\b[^>]*>([\s\S]*?)<\/category>/gi
  var match
  var out = []
  while ((match = re.exec(text)) !== null) {
    var value = stripTags(unwrapText(match[1]))
    if (value !== "") out.push(value)
  }
  return out
}

// RFC 822 (the format RSS pubDate uses) parses fine with the platform Date
// constructor; anything that doesn't parse yields null rather than an
// Invalid Date leaking into callers.
function parsePubDate(text) {
  var raw = String(text === undefined || text === null ? "" : text).trim()
  if (raw === "") return null
  var ms = Date.parse(raw)
  return isFinite(ms) ? ms : null
}

// Normalizes one raw <item> block into the flat shape the panel renders a
// row from. Items missing both a link and a guid are dropped: without one
// of those there is nothing safe to open and nothing stable to de-duplicate
// or key a list delegate on.
// Case/whitespace-normalized identity for a category name, used to compare
// and de-duplicate categories without being tripped up by a feed producer's
// inconsistent capitalization of the same tag (rare, but seen in the wild).
// The *displayed* name always comes from the first-seen original spelling,
// not this normalized form.
function categoryKey(name) {
  return String(name === undefined || name === null ? "" : name).trim().toLowerCase()
}

function normalizeItem(itemXml) {
  var title = stripTags(extractTag(itemXml, "title")) || "(untitled)"
  var link = extractTag(itemXml, "link").trim()
  var guid = extractTag(itemXml, "guid").trim()
  var creator = stripTags(extractTag(itemXml, "dc:creator"))
  var pubDateText = extractTag(itemXml, "pubDate")
  var pubDateMs = parsePubDate(pubDateText)
  var categories = extractCategories(itemXml)

  var url = isSafeHttpUrl(link) ? link : (isSafeHttpUrl(guid) ? guid : "")
  var key = url !== "" ? url : guid
  if (key === "") return null

  return {
    key: key,
    title: title,
    url: url,
    author: creator,
    // The full category list is kept (not just the first) so a post can be
    // matched against any pinned category it belongs to, not only its
    // primary one. `category` stays as the single display category (the
    // feed's first-listed one) for the byline shown on every row.
    categories: categories,
    category: categories.length > 0 ? categories[0] : "",
    pubDateMs: pubDateMs
  }
}

// Parses a full RSS document into the de-duplicated, newest-first post list
// this widget retains. De-duplication is by link/guid (not title): the feed
// mirrors the same post under multiple sub-blogs with identical titles but
// distinct canonical links, and those are legitimately different entries.
// Items with no usable date sort after every dated item, oldest-first among
// themselves, since there's no better ordering signal for them.
//
// Unlike the ten-post cap the *panel* applies, this returns every
// de-duplicated post the feed response contained (already bounded by
// MAX_ITEMS_SCANNED upstream) — a category pin needs the full retained set
// to filter before re-applying the ten-item display cap, since a pinned
// category's ten most recent posts are not necessarily within the ten most
// recent posts overall.
function parseFeed(xmlText) {
  var blocks = extractItemBlocks(xmlText)
  var seen = {}
  var posts = []
  for (var i = 0; i < blocks.length; i++) {
    var post = normalizeItem(blocks[i])
    if (!post || seen[post.key]) continue
    seen[post.key] = true
    posts.push(post)
  }
  posts.sort(function(a, b) {
    var am = a.pubDateMs === null ? -1 : a.pubDateMs
    var bm = b.pubDateMs === null ? -1 : b.pubDateMs
    return bm - am
  })
  return posts
}

// Every category currently present across the retained posts, in
// first-seen order. Posts are already newest-first, so this doubles as
// "most-recently-used category first" — the order the panel's chip row
// lists categories in. Deduplicated case/whitespace-insensitively but
// displayed under whichever original spelling was seen first.
function aggregateCategories(posts) {
  var list = Array.isArray(posts) ? posts : []
  var seen = {}
  var out = []
  for (var i = 0; i < list.length; i++) {
    var categories = Array.isArray(list[i].categories) ? list[i].categories : []
    for (var j = 0; j < categories.length; j++) {
      var name = categories[j]
      var key = categoryKey(name)
      if (key === "" || seen[key]) continue
      seen[key] = true
      out.push({ key: key, name: name })
    }
  }
  return out
}

// Normalizes a persisted `pinnedCategories` setting (any shape shell.json
// might hand back — an array, undefined, a stray non-array value from hand
// editing) into a de-duplicated list of lowercased category keys. At most
// MAX_PINNED_CATEGORIES are kept so a corrupted setting can't cause
// unbounded filtering work.
function normalizePinnedCategories(raw) {
  var list = Array.isArray(raw) ? raw : []
  var seen = {}
  var out = []
  for (var i = 0; i < list.length; i++) {
    var key = categoryKey(list[i])
    if (key === "" || seen[key]) continue
    seen[key] = true
    out.push(key)
    if (out.length >= MAX_PINNED_CATEGORIES) break
  }
  return out
}

// True if `post` carries any of the (already-normalized) pinned category
// keys. An empty pin list matches everything — "no pins" means "show
// everything", not "show nothing".
function postMatchesPins(post, normalizedPinKeys) {
  if (!normalizedPinKeys || normalizedPinKeys.length === 0) return true
  var categories = post && Array.isArray(post.categories) ? post.categories : []
  for (var i = 0; i < categories.length; i++) {
    if (normalizedPinKeys.indexOf(categoryKey(categories[i])) !== -1) return true
  }
  return false
}

// The list the panel actually renders: every retained post whose categories
// intersect the pinned set (or every retained post, unfiltered, when
// nothing is pinned), newest-first, capped to MAX_POSTS. `pinnedCategories`
// is accepted in whatever raw shape the caller has on hand and normalized
// here, so both the panel and any future caller can pass the settings value
// straight through.
function selectDisplayPosts(posts, pinnedCategories) {
  var list = Array.isArray(posts) ? posts : []
  var pins = normalizePinnedCategories(pinnedCategories)
  var filtered = pins.length === 0 ? list : list.filter(function(post) { return postMatchesPins(post, pins) })
  return filtered.length > MAX_POSTS ? filtered.slice(0, MAX_POSTS) : filtered
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_OUTPUT_CHARS: MAX_OUTPUT_CHARS,
    MAX_RESPONSE_BYTES: MAX_RESPONSE_BYTES,
    MAX_ITEMS_SCANNED: MAX_ITEMS_SCANNED,
    MAX_POSTS: MAX_POSTS,
    MAX_PINNED_CATEGORIES: MAX_PINNED_CATEGORIES,
    capOutput: capOutput,
    appendCapped: appendCapped,
    wasCapped: wasCapped,
    isSafeHttpUrl: isSafeHttpUrl,
    decodeEntities: decodeEntities,
    unwrapText: unwrapText,
    stripTags: stripTags,
    extractItemBlocks: extractItemBlocks,
    extractTag: extractTag,
    extractCategories: extractCategories,
    parsePubDate: parsePubDate,
    categoryKey: categoryKey,
    normalizeItem: normalizeItem,
    parseFeed: parseFeed,
    aggregateCategories: aggregateCategories,
    normalizePinnedCategories: normalizePinnedCategories,
    postMatchesPins: postMatchesPins,
    selectDisplayPosts: selectDisplayPosts
  }
}

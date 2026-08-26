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

// ---- Producer-side caps ----------------------------------------------------
// A malicious or unexpectedly bloated feed response can't exhaust memory in
// the long-lived shell process.
//
// MAX_OUTPUT_CHARS – UTF-16 code units accepted from curl's stdout before
//   truncation (~1 MB for the mostly-ASCII XML this feed serves).
// MAX_ITEMS_SCANNED – <item> blocks read out of the raw XML before giving up.
// MAX_POSTS         – posts ever kept/returned after de-duplication and
//   sorting; the panel only ever shows the ten most recent.
var MAX_OUTPUT_CHARS = 1 * 1024 * 1024
var MAX_ITEMS_SCANNED = 200
var MAX_POSTS = 10

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
    category: categories.length > 0 ? categories[0] : "",
    pubDateMs: pubDateMs
  }
}

// Parses a full RSS document into the de-duplicated, newest-first post list
// this widget shows. De-duplication is by link/guid (not title): the feed
// mirrors the same post under multiple sub-blogs with identical titles but
// distinct canonical links, and those are legitimately different entries.
// Items with no usable date sort after every dated item, oldest-first among
// themselves, since there's no better ordering signal for them. At most
// MAX_POSTS are returned.
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
  if (posts.length > MAX_POSTS) posts = posts.slice(0, MAX_POSTS)
  return posts
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_OUTPUT_CHARS: MAX_OUTPUT_CHARS,
    MAX_ITEMS_SCANNED: MAX_ITEMS_SCANNED,
    MAX_POSTS: MAX_POSTS,
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
    normalizeItem: normalizeItem,
    parseFeed: parseFeed
  }
}

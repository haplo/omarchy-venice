// Pure presentation logic for the Venice Balance plugin.
//
// Everything here is a plain function over plain data so it can be exercised
// from node (`tests/model.test.js`) without a running shell. The QML side
// loads this with `import "Model.js" as Model`; nothing in here may touch a
// QML type, a singleton, or the filesystem.

// ------------------------------------------------------------ parsing

function number(value) {
  if (typeof value === "number" && isFinite(value)) return value
  if (typeof value === "string" && value.trim() !== "") {
    var n = Number(value)
    if (isFinite(n)) return n
  }
  return 0
}

function clamp(value, low, high) {
  var n = number(value)
  if (n < low) return low
  if (n > high) return high
  return n
}

// The helper always prints one JSON object. A malformed or empty payload is a
// parse failure, never a silent zero balance.
function parseResult(text) {
  var raw = String(text || "").trim()
  if (raw === "") return { ok: false, kind: "parse", message: "Empty response from the balance helper" }
  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return { ok: false, kind: "parse", message: "Unreadable response from the balance helper" }
  }
  if (!parsed || typeof parsed !== "object") {
    return { ok: false, kind: "parse", message: "Unreadable response from the balance helper" }
  }
  if (parsed.ok === false) {
    return {
      ok: false,
      kind: String(parsed.kind || "parse"),
      message: String(parsed.message || "Balance request failed")
    }
  }
  if (parsed.ok !== true || !parsed.data || typeof parsed.data !== "object") {
    return { ok: false, kind: "parse", message: "Balance response was missing data" }
  }
  return { ok: true, data: parsed.data, storage: String(parsed.storage || "") }
}

// The store/clear commands answer {"ok":true,"storage":"keyring"} with no
// balance payload. Using parseResult for those replies made a successful
// token save look like "Balance response was missing data".
function parseAction(text) {
  var raw = String(text || "").trim()
  if (raw === "") return { ok: false, kind: "parse", message: "Empty response from the helper" }
  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return { ok: false, kind: "parse", message: "Unreadable response from the helper" }
  }
  if (!parsed || typeof parsed !== "object") {
    return { ok: false, kind: "parse", message: "Unreadable response from the helper" }
  }
  if (parsed.ok === false) {
    return {
      ok: false,
      kind: String(parsed.kind || "parse"),
      message: String(parsed.message || "Action failed")
    }
  }
  if (parsed.ok !== true) {
    return { ok: false, kind: "parse", message: "Unreadable response from the helper" }
  }
  return { ok: true, storage: String(parsed.storage || "") }
}

// Launcher status from bin/venice-app: installed / managed / chatUrl / foreign.
function parseAppStatus(text) {
  var raw = String(text || "").trim()
  if (raw === "") return { ok: false, kind: "parse", message: "Empty response from the app helper" }
  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return { ok: false, kind: "parse", message: "Unreadable response from the app helper" }
  }
  if (!parsed || typeof parsed !== "object") {
    return { ok: false, kind: "parse", message: "Unreadable response from the app helper" }
  }
  if (parsed.ok === false) {
    return {
      ok: false,
      kind: String(parsed.kind || "parse"),
      message: String(parsed.message || "Could not read the app status")
    }
  }
  if (parsed.ok !== true) {
    return { ok: false, kind: "parse", message: "Unreadable response from the app helper" }
  }
  return {
    ok: true,
    installed: parsed.installed === true,
    managed: parsed.managed === true,
    chatUrl: parsed.chatUrl === true,
    foreign: parsed.foreign === true,
    marker: parsed.marker === true,
    url: String(parsed.url || ""),
    target: String(parsed.target || ""),
    name: String(parsed.name || "")
  }
}

function normalize(data) {
  var d = (data && typeof data === "object") ? data : {}
  var b = (d.balances && typeof d.balances === "object") ? d.balances : {}
  return {
    diem: number(b.diem),
    usd: number(b.usd),
    bundled: number(b.bundledCredits),
    earned: number(b.earnedCredits),
    allocation: Math.max(0, number(d.diemEpochAllocation)),
    canConsume: d.canConsume === true,
    currency: String(d.consumptionCurrency || "")
  }
}

// ---------------------------------------------------------- calculations

function diemPercent(balance) {
  if (!balance || !(balance.allocation > 0)) return 0
  return clamp(balance.diem / balance.allocation * 100, 0, 100)
}

// healthy | low | depleted. canConsume is authoritative: if Venice says the
// account cannot spend, the widget must not claim it is healthy.
function tier(balance, warnAtPercent) {
  if (!balance) return "none"
  var warn = isFinite(Number(warnAtPercent)) ? Number(warnAtPercent) : 25
  if (balance.canConsume === false) return "depleted"
  if (balance.allocation > 0) {
    var pct = diemPercent(balance)
    if (pct > 0.0001) return pct <= warn ? "low" : "healthy"
    return balance.usd > 0 ? "healthy" : "depleted"
  }
  return balance.usd > 0 ? "healthy" : "depleted"
}

// ------------------------------------------------------------ formatting

function groupThousands(value) {
  var s = String(value)
  var negative = s.charAt(0) === "-"
  if (negative) s = s.substring(1)
  var out = ""
  var count = 0
  for (var i = s.length - 1; i >= 0; i--) {
    out = s.charAt(i) + out
    count++
    if (count % 3 === 0 && i > 0) out = "," + out
  }
  return (negative ? "-" : "") + out
}

function formatUsd(value) {
  var n = number(value)
  var negative = n < 0
  var fixed = Math.abs(n).toFixed(2).split(".")
  return (negative ? "-$" : "$") + groupThousands(fixed[0]) + "." + fixed[1]
}

function formatDiem(value) {
  var n = number(value)
  var negative = n < 0
  var fixed = Math.abs(n).toFixed(2).split(".")
  return (negative ? "-" : "") + groupThousands(fixed[0]) + "." + fixed[1]
}

function formatPercent(percent) {
  var pct = clamp(percent, 0, 100)
  if (pct <= 0) return "0%"
  if (pct < 1) return "<1%"
  return Math.round(pct) + "%"
}

function updatedLabel(timestamp, now) {
  var ts = number(timestamp)
  if (ts <= 0) return ""
  var current = number(now) || Date.now()
  var seconds = Math.max(0, Math.floor((current - ts) / 1000))
  if (seconds < 10) return "just now"
  if (seconds < 60) return seconds + "s ago"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h " + (minutes % 60) + "m ago"
  return Math.floor(hours / 24) + "d ago"
}

function summary(balance) {
  if (!balance) return ""
  if (balance.allocation > 0) {
    return formatDiem(balance.diem) + " / " + formatDiem(balance.allocation) + " DIEM ("
      + formatPercent(diemPercent(balance)) + ") · " + formatUsd(balance.usd) + " USD"
  }
  return formatUsd(balance.usd) + " USD · no DIEM allocation"
}

function extraCredits(balance) {
  if (!balance) return ""
  var bits = []
  if (balance.bundled > 0) bits.push(formatDiem(balance.bundled) + " bundled")
  if (balance.earned > 0) bits.push(formatDiem(balance.earned) + " earned")
  if (bits.length === 0) return ""
  return "Also available: " + bits.join(" · ")
}

// The bar text. "" is a valid answer (icon only); callers decide what to show
// while loading or before a token is set.
function barLabel(mode, balance) {
  if (!balance) return ""
  switch (String(mode || "none")) {
    case "auto":
    case "percent":
      return balance.allocation > 0 ? formatPercent(diemPercent(balance)) : formatUsd(balance.usd)
    case "usd":
      return formatUsd(balance.usd)
    case "diem":
      return formatDiem(balance.diem)
    case "both":
      return formatDiem(balance.diem) + " · " + formatUsd(balance.usd)
    default:
      return ""
  }
}

// Two-line bar tooltip. `opts` may carry needsToken, errorMessage, tier,
// stale, lastUpdated and now. "last known" avoids claiming the network is
// down when the failure might be an HTTP or parse error.
function tooltip(balance, opts) {
  opts = opts || {}
  if (!balance) {
    if (opts.needsToken) return "Venice.ai\nNo API token set"
    if (opts.errorMessage) return "Venice.ai\n" + opts.errorMessage
    return "Venice.ai\nLoading…"
  }
  var head
  if (opts.stale) head = "Venice.ai · last known"
  else if (opts.tier === "depleted") head = "Venice.ai · depleted"
  else if (balance.allocation > 0) head = "Venice.ai · " + formatPercent(diemPercent(balance)) + " DIEM left"
  else head = "Venice.ai · no DIEM allocation"

  var body = balance.allocation > 0
    ? summary(balance)
    : formatUsd(balance.usd) + " USD prepaid"
  if (opts.stale && opts.lastUpdated) body += "\nLast updated " + updatedLabel(opts.lastUpdated, opts.now)
  return head + "\n" + body
}

// --------------------------------------------------------------- helpers

function fileUrlPath(url) {
  var s = String(url || "")
  if (s.indexOf("file://") === 0) {
    s = s.substring(7)
    try {
      s = decodeURIComponent(s)
    } catch (e) {
      // Keep the undecoded path; it is still better than a file:// URL.
    }
  }
  return s
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    number: number,
    clamp: clamp,
    parseResult: parseResult,
    parseAction: parseAction,
    parseAppStatus: parseAppStatus,
    normalize: normalize,
    diemPercent: diemPercent,
    tier: tier,
    groupThousands: groupThousands,
    formatUsd: formatUsd,
    formatDiem: formatDiem,
    formatPercent: formatPercent,
    updatedLabel: updatedLabel,
    summary: summary,
    extraCredits: extraCredits,
    barLabel: barLabel,
    tooltip: tooltip,
    fileUrlPath: fileUrlPath
  }
}

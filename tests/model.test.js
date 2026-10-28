const test = require("node:test")
const assert = require("node:assert/strict")

const Model = require("../Model.js")

function balance(overrides = {}) {
  return {
    diem: 90.5,
    usd: 25,
    bundled: 0,
    earned: 0,
    allocation: 100,
    canConsume: true,
    currency: "DIEM",
    ...overrides
  }
}

test("parseResult accepts the helper envelope", () => {
  const parsed = Model.parseResult(JSON.stringify({
    ok: true,
    storage: "keyring",
    data: { canConsume: true, balances: { diem: 1, usd: 2 }, diemEpochAllocation: 3 }
  }))
  assert.equal(parsed.ok, true)
  assert.equal(parsed.storage, "keyring")
  assert.equal(parsed.data.balances.diem, 1)
})

test("parseResult surfaces helper failures and malformed payloads", () => {
  assert.deepEqual(Model.parseResult(""), {
    ok: false, kind: "parse", message: "Empty response from the balance helper"
  })
  assert.equal(Model.parseResult("not json").kind, "parse")
  assert.equal(Model.parseResult("[]").kind, "parse")

  const auth = Model.parseResult(JSON.stringify({ ok: false, kind: "auth", message: "bad token" }))
  assert.equal(auth.ok, false)
  assert.equal(auth.kind, "auth")
  assert.equal(auth.message, "bad token")

  const missing = Model.parseResult(JSON.stringify({ ok: false }))
  assert.equal(missing.kind, "parse")
  assert.equal(Model.parseResult(JSON.stringify({ ok: true })).kind, "parse")
})

test("parseAction accepts store replies without a balance payload", () => {
  assert.deepEqual(Model.parseAction(JSON.stringify({ ok: true, storage: "keyring" })),
    { ok: true, storage: "keyring" })
  assert.deepEqual(Model.parseAction(JSON.stringify({ ok: true })),
    { ok: true, storage: "" })

  const locked = Model.parseAction(JSON.stringify({
    ok: false, kind: "keyring", message: "The keyring is locked"
  }))
  assert.equal(locked.ok, false)
  assert.equal(locked.kind, "keyring")
  assert.equal(locked.message, "The keyring is locked")

  assert.equal(Model.parseAction("").kind, "parse")
  assert.equal(Model.parseAction("not json").kind, "parse")
  assert.equal(Model.parseAction("{}").kind, "parse")
  assert.equal(Model.parseAction(JSON.stringify({ storage: "keyring" })).kind, "parse")
})

test("parseAppStatus understands the launcher states", () => {
  const installed = Model.parseAppStatus(JSON.stringify({
    ok: true, name: "Venice.ai", target: "https://venice.ai/chat",
    url: "https://venice.ai/chat", installed: true, managed: true,
    chatUrl: true, foreign: false, marker: true
  }))
  assert.equal(installed.ok, true)
  assert.equal(installed.installed, true)
  assert.equal(installed.managed, true)
  assert.equal(installed.chatUrl, true)
  assert.equal(installed.foreign, false)
  assert.equal(installed.marker, true)
  assert.equal(installed.url, "https://venice.ai/chat")
  assert.equal(installed.target, "https://venice.ai/chat")

  const missing = Model.parseAppStatus(JSON.stringify({ ok: true, installed: false }))
  assert.equal(missing.ok, true)
  assert.equal(missing.installed, false)

  const foreign = Model.parseAppStatus(JSON.stringify({ ok: true, installed: true, foreign: true, managed: false }))
  assert.equal(foreign.foreign, true)
  assert.equal(foreign.managed, false)

  const error = Model.parseAppStatus(JSON.stringify({ ok: false, kind: "install", message: "icon failed" }))
  assert.equal(error.ok, false)
  assert.equal(error.kind, "install")
  assert.equal(error.message, "icon failed")

  assert.equal(Model.parseAppStatus("").kind, "parse")
  assert.equal(Model.parseAppStatus("not json").kind, "parse")
  assert.equal(Model.parseAppStatus("{}").kind, "parse")
})

test("normalize fills missing fields with zero and accepts numeric strings", () => {
  const full = Model.normalize({
    canConsume: true,
    consumptionCurrency: "DIEM",
    balances: { diem: 10.5, usd: 3, bundledCredits: 2, earnedCredits: 1 },
    diemEpochAllocation: 20
  })
  assert.deepEqual(full, {
    diem: 10.5, usd: 3, bundled: 2, earned: 1,
    allocation: 20, canConsume: true, currency: "DIEM"
  })

  const sparse = Model.normalize({
    balances: { diem: "7.25", usd: null },
    diemEpochAllocation: "-4"
  })
  assert.equal(sparse.diem, 7.25)
  assert.equal(sparse.usd, 0)
  assert.equal(sparse.allocation, 0)
  assert.equal(sparse.canConsume, false)
  assert.equal(sparse.currency, "")

  assert.equal(Model.normalize(null).diem, 0)
  assert.equal(Model.normalize({ balances: "nope" }).usd, 0)
})

test("diemPercent is allocation-relative and clamped", () => {
  assert.equal(Model.diemPercent(null), 0)
  assert.equal(Model.diemPercent(balance({ allocation: 0, diem: 10 })), 0)
  assert.equal(Model.diemPercent(balance({ diem: 50, allocation: 100 })), 50)
  assert.equal(Model.diemPercent(balance({ diem: 150, allocation: 100 })), 100)
  assert.equal(Model.diemPercent(balance({ diem: -5, allocation: 100 })), 0)
})

test("tier respects canConsume and the low threshold", () => {
  assert.equal(Model.tier(null, 25), "none")
  assert.equal(Model.tier(balance({ canConsume: false }), 25), "depleted")
  assert.equal(Model.tier(balance({ diem: 80, allocation: 100 }), 25), "healthy")
  assert.equal(Model.tier(balance({ diem: 25.1, allocation: 100 }), 25), "healthy")
  assert.equal(Model.tier(balance({ diem: 25, allocation: 100 }), 25), "low")
  assert.equal(Model.tier(balance({ diem: 0, allocation: 100, usd: 0 }), 25), "depleted")
  // DIEM drained but USD remains is still spendable.
  assert.equal(Model.tier(balance({ diem: 0, allocation: 100, usd: 5 }), 25), "healthy")
  // No staking at all: USD carries the account.
  assert.equal(Model.tier(balance({ diem: 0, allocation: 0, usd: 5 }), 25), "healthy")
  assert.equal(Model.tier(balance({ diem: 0, allocation: 0, usd: 0 }), 25), "depleted")
})

test("money and percent formatting", () => {
  assert.equal(Model.formatUsd(0), "$0.00")
  assert.equal(Model.formatUsd(12.3), "$12.30")
  assert.equal(Model.formatUsd(1234.5), "$1,234.50")
  assert.equal(Model.formatUsd(-0.5), "-$0.50")
  assert.equal(Model.formatUsd(-1234.567), "-$1,234.57")
  assert.equal(Model.formatUsd("12.5"), "$12.50")
  assert.equal(Model.formatUsd(null), "$0.00")
  assert.equal(Model.formatUsd(Infinity), "$0.00")

  assert.equal(Model.formatDiem(0), "0.00")
  assert.equal(Model.formatDiem(143.5), "143.50")
  assert.equal(Model.formatDiem(1234567.891), "1,234,567.89")
  assert.equal(Model.formatDiem(-2), "-2.00")

  assert.equal(Model.groupThousands(0), "0")
  assert.equal(Model.groupThousands(999), "999")
  assert.equal(Model.groupThousands(1000), "1,000")
  assert.equal(Model.groupThousands(-1234567), "-1,234,567")

  assert.equal(Model.formatPercent(0), "0%")
  assert.equal(Model.formatPercent(-5), "0%")
  assert.equal(Model.formatPercent(0.4), "<1%")
  assert.equal(Model.formatPercent(0.9), "<1%")
  assert.equal(Model.formatPercent(24.6), "25%")
  assert.equal(Model.formatPercent(99.6), "100%")
  assert.equal(Model.formatPercent(150), "100%")
})

test("updatedLabel reads naturally at every scale", () => {
  const now = 1_800_000_000_000
  assert.equal(Model.updatedLabel(0, now), "")
  assert.equal(Model.updatedLabel(now - 5_000, now), "just now")
  assert.equal(Model.updatedLabel(now - 30_000, now), "30s ago")
  assert.equal(Model.updatedLabel(now - 5 * 60_000, now), "5m ago")
  assert.equal(Model.updatedLabel(now - 65 * 60_000, now), "1h 5m ago")
  assert.equal(Model.updatedLabel(now - 2 * 86400_000, now), "2d ago")
})

test("resetIn counts down to the next 00:00 UTC", () => {
  const at = (hhmmss) => {
    const [h, m, s] = hhmmss.split(":").map(Number)
    return Date.UTC(2026, 9, 28, h, m, s)
  }
  assert.equal(Model.resetIn(at("00:00:00")), "24h 0m")
  assert.equal(Model.resetIn(at("19:48:00")), "4h 12m")
  assert.equal(Model.resetIn(at("23:59:30")), "0h 1m")
  assert.equal(Model.resetIn(at("12:00:00")), "12h 0m")
  assert.equal(Model.resetIn(at("00:00:01")), "24h 0m")
  // A missing or zero clock falls back to the real one without throwing.
  assert.match(Model.resetIn(0), /^\d+h \d+m$/)
  assert.match(Model.resetIn(null), /^\d+h \d+m$/)
})

test("summary covers staking and USD-only accounts", () => {
  assert.equal(Model.summary(null), "")
  assert.equal(Model.summary(balance({ diem: 90.5, allocation: 100, usd: 25 })),
    "90.50 / 100.00 DIEM (91%) · $25.00 USD")
  assert.equal(Model.summary(balance({ diem: 0, allocation: 0, usd: 25 })),
    "$25.00 USD · no DIEM allocation")
})

test("extraCredits only mentions credits that exist", () => {
  assert.equal(Model.extraCredits(null), "")
  assert.equal(Model.extraCredits(balance({ bundled: 0, earned: 0 })), "")
  assert.equal(Model.extraCredits(balance({ bundled: 10, earned: 0 })),
    "Also available: 10.00 bundled")
  assert.equal(Model.extraCredits(balance({ bundled: 10, earned: 5 })),
    "Also available: 10.00 bundled · 5.00 earned")
})

test("barLabel honours every mode", () => {
  const staking = balance({ diem: 72, allocation: 100, usd: 12.34 })
  const usdOnly = balance({ diem: 0, allocation: 0, usd: 12.34 })

  assert.equal(Model.barLabel("none", staking), "")
  assert.equal(Model.barLabel("auto", staking), "72%")
  assert.equal(Model.barLabel("auto", usdOnly), "$12.34")
  assert.equal(Model.barLabel("percent", staking), "72%")
  assert.equal(Model.barLabel("percent", usdOnly), "$12.34")
  assert.equal(Model.barLabel("usd", staking), "$12.34")
  assert.equal(Model.barLabel("diem", staking), "72.00")
  assert.equal(Model.barLabel("both", staking), "72.00 · $12.34")
  assert.equal(Model.barLabel("nonsense", staking), "")
  assert.equal(Model.barLabel("auto", null), "")
})

test("tooltip explains loading, token, depletion and offline states", () => {
  assert.equal(Model.tooltip(null, {}), "Venice.ai\nLoading…")
  assert.equal(Model.tooltip(null, { needsToken: true }), "Venice.ai\nNo API token set")
  assert.equal(Model.tooltip(null, { errorMessage: "Network unreachable" }),
    "Venice.ai\nNetwork unreachable")

  const normal = Model.tooltip(balance({ diem: 90.5, allocation: 100, usd: 25 }), { tier: "healthy" })
  assert.equal(normal, "Venice.ai · 91% DIEM left\n90.50 / 100.00 DIEM (91%) · $25.00 USD")

  const usdOnly = Model.tooltip(balance({ diem: 0, allocation: 0, usd: 25 }), { tier: "healthy" })
  assert.equal(usdOnly, "Venice.ai · no DIEM allocation\n$25.00 USD prepaid")

  const depleted = Model.tooltip(balance({ diem: 0, allocation: 100, usd: 0, canConsume: false }), { tier: "depleted" })
  assert.equal(depleted, "Venice.ai · depleted\n0.00 / 100.00 DIEM (0%) · $0.00 USD")

  const now = 1_800_000_000_000
  const stale = Model.tooltip(balance({ usd: 5 }), {
    tier: "healthy", stale: true, lastUpdated: now - 5 * 60_000, now
  })
  assert.equal(stale, "Venice.ai · last known\n90.50 / 100.00 DIEM (91%) · $5.00 USD\nLast updated 5m ago")
})

test("fileUrlPath strips the scheme and decodes", () => {
  assert.equal(Model.fileUrlPath("file:///home/me/plugins/venice"), "/home/me/plugins/venice")
  assert.equal(Model.fileUrlPath("file:///home/me/with%20space"), "/home/me/with space")
  assert.equal(Model.fileUrlPath("/plain/path"), "/plain/path")
  assert.equal(Model.fileUrlPath(""), "")
})

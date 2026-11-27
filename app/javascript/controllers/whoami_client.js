// One question per page load to Hack Club Auth's browser endpoint: "does this visitor have a Hack Club session, and what is their first name?"
// The page sends nothing but the browser's own cookies; every failure (blocked, offline, not allowed from this origin, slow, odd reply)
// is the same quiet answer, "unknown", so a page using it just stays as it is. The answer is never stored, logged or sent to our server.
const TIMEOUT_MS = 3000
const FRESH_MS = 60_000
const UNKNOWN = Object.freeze({ signedIn: false, firstName: "" })
let asked = null // { url, at, promise }: one shared request for every element on the page

// Only a short plain string is ever used, and only as text (textContent), never as markup.
const cleanName = (value) => (typeof value === "string" ? value.replace(/[\u0000-\u001f\u007f<>]/g, "").trim().slice(0, 40) : "")

async function ask(url) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
  try {
    const response = await fetch(url, { credentials: "include", headers: { Accept: "application/json" }, signal: controller.signal })
    if (!response.ok) return UNKNOWN
    const data = await response.json()
    if (!data || data.signed_in !== true) return UNKNOWN
    return { signedIn: true, firstName: cleanName(data.first_name) }
  } catch {
    return UNKNOWN
  } finally {
    clearTimeout(timer)
  }
}

export function whoami(url) {
  if (!url) return Promise.resolve(UNKNOWN)
  if (!asked || asked.url !== url || Date.now() - asked.at > FRESH_MS) asked = { url, at: Date.now(), promise: ask(url) }
  return asked.promise
}

// The answer if it arrives within `ms`, otherwise null (and the caller leaves the page alone: no late jump).
export function whoamiWithin(url, ms) {
  let timer
  const late = new Promise((resolve) => { timer = setTimeout(() => resolve(null), ms) })
  return Promise.race([whoami(url), late]).finally(() => clearTimeout(timer))
}

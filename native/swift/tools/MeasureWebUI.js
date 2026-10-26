// Development-only runtime. Import only from an explicitly instrumented PRIVATE
// client copy; normal client sources never import it. React useLayoutEffect
// adapters supply page-specific committed booleans, never payloads or errors.
// No request interception, DOM readiness guessing, storage, polling or rAF.
export function createWebUIProfiler(host) {
  if (host.__uniapiWebUIProfileV2) return host.__uniapiWebUIProfileV2
  const pages = new Set(['home', 'speed', 'results', 'prompts', 'arena', 'switcher', 'code', 'stats', 'activity', 'fans', 'battery', 'transcribe', 'jobs', 'settings'])
  const pageAt = value => {
    try {
      const url = new URL(value ?? host.location.href, host.location.href)
      if (url.origin !== host.location.origin) return null
      const page = url.pathname === '/' ? 'home' : url.pathname.split('/')[1]
      return pages.has(page) ? page : null
    } catch { return null }
  }
  const rows = []
  let sequence = 0, active = null, navigation = null, click = null, queued = false
  // Only the optional PRIVATE profiling shell opts into native metadata output.
  // The installed shell has neither this flag nor this handler. Never send a
  // route key, URL, payload, failure text or component state across the bridge.
  const postNative = row => {
    if (host.__uniapiWebUIProfileNative !== true) return
    try { host.webkit?.messageHandlers?.uniapiProfileCommit?.postMessage({ ...row }) } catch { /* measurement must not alter the application */ }
  }
  const begin = (page, start, clock) => {
    const visit = { page, id: ++sequence, start, clock }
    postNative({ schema: 2, page, visit: visit.id, clock, phase: 'begin', elapsedMs: Math.max(0, host.performance.now() - start) })
    return visit
  }
  const panel = host.document.createElement('pre')
  panel.id = 'uniapi-web-profile-v2'
  panel.setAttribute('aria-label', 'Web commit measurements')
  panel.style.cssText = 'position:fixed;right:12px;bottom:12px;z-index:9999;max-height:180px;max-width:650px;overflow:auto;padding:8px;background:#111;color:#eee;font:10px monospace;border:1px solid #666;white-space:pre-wrap;pointer-events:none'
  const paintPanel = () => {
    panel.textContent = 'WEB PROFILE V2: React layout-effect/DOM commits, not painted frames; document/click/route clocks.\n' + rows.map(row => JSON.stringify(row)).join('\n')
  }
  const append = phase => {
    const now = host.performance.now()
    const row = { schema: 2, page: active.page, visit: active.id, clock: active.clock, phase, elapsedMs: Math.max(0, now - active.start) }
    rows.push(row)
    postNative(row)
    if (rows.length > 1000) rows.splice(0, rows.length - 1000)
    paintPanel()
  }
  const flush = () => {
    queued = false
    if (!active || active.page !== pageAt()) return
    if (!active.first) { active.first = true; append('firstViewCommit') }
    if (active.terminal || !active.required) return
    const states = active.required.map(part => active.parts.get(part))
    if (states.some(state => state?.failed)) {
      active.terminal = true; append('failureViewCommit')
    } else if (states.every(state => state?.ready)) {
      active.terminal = true; append('dataViewCommit')
    }
  }
  const enqueue = () => { if (!queued) { queued = true; host.queueMicrotask(flush) } }
  const navigate = value => {
    const page = pageAt(value)
    if (page) navigation = begin(page, click?.start ?? host.performance.now(), click ? 'click' : 'route')
  }
  host.document.addEventListener('click', event => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const own = { start: host.performance.now() }
    click = own
    // A router history write during this event consumes the click clock. A
    // cancelled/non-navigation click cannot taint a later unrelated navigation.
    host.queueMicrotask(() => { if (click === own) click = null })
  }, true)
  for (const operation of ['pushState', 'replaceState']) {
    const original = host.history[operation]
    host.history[operation] = function (...args) {
      const result = original.apply(this, args)
      if (active || click) navigate(args[2])
      return result
    }
  }
  host.addEventListener('popstate', () => { const page = pageAt(); navigation = page ? begin(page, host.performance.now(), 'route') : null })
  const api = Object.freeze({
    commit(page, routeKey, part, state, required) {
      if (!pages.has(page) || page !== pageAt() || typeof routeKey !== 'string' || typeof part !== 'string') return
      if (!active || active.key !== routeKey || active.page !== page) {
        const clock = navigation?.page === page ? navigation : begin(page, active ? host.performance.now() : 0, active ? 'route' : 'document')
        active = { page, key: routeKey, id: clock.id, start: clock.start, clock: clock.clock, first: false, terminal: false, required: null, parts: new Map() }
        navigation = null
      }
      active.parts.set(part, { ready: state.ready === true, failed: state.failed === true })
      if (part === 'page' && Array.isArray(required)) active.required = [...new Set(['page', ...required])]
      // Coalesce layout effects from one commit so child-first effect ordering
      // cannot combine a new child state with the previous parent requirements.
      enqueue()
    },
    rows: () => rows.map(row => ({ ...row })),
  })
  host.__uniapiWebUIProfileV2 = api
  const initialPage = pageAt()
  if (initialPage) navigation = begin(initialPage, 0, 'document')
  const mount = () => { if (!panel.parentNode) host.document.body.append(panel); paintPanel() }
  if (host.document.body) mount()
  else host.document.addEventListener('DOMContentLoaded', mount, { once: true })
  return api
}

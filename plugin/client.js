// ds-touchbar — client 端：轮询 host 的 touchbar-click 文件内容，
// 有新的点击（ts 变化）就切到对应 bot 会话。
window.__ModuleLoader__.load({
  id: 'ds-touchbar',
  factory: (require) => {
    const module = { exports: {} }
    const POLL_PATH = 'api/ds-touchbar/poll'
    const POLL_MS = 1000

    const inject = ['uiWorkspace']
    function apply(ctx) {
      let lastTs = 0
      let timer = null
      let stopped = false

      const poll = async () => {
        if (stopped) return
        try {
          const res = await fetch(POLL_PATH, { credentials: 'same-origin', cache: 'no-store' })
          if (res.ok) {
            const body = await res.json()
            const click = body?.click
            if (click && click.id && click.ts && click.ts !== lastTs) {
              lastTs = click.ts
              try { ctx.uiWorkspace.openSession(click.id) } catch (e) { /* openSession 可能不存在 */ }
            }
          }
        } catch { /* 网络波动忽略 */ }
      }

      ctx.effect(() => {
        timer = setInterval(poll, POLL_MS)
        poll()
        return () => { stopped = true; clearInterval(timer) }
      }, 'ds-touchbar: click poll')
    }

    module.exports = { apply, inject }
    return Object.defineProperty({ ...module.exports }, Symbol.toStringTag, { value: 'Module' })
  },
})

// ds-touchbar — DSH 插件：把「DSH Bot 活动」显示到 MacBook Touch Bar，
// 并在 DSH 运行时自动拉起原生 DSHTouchBar.app，DSH 退出时关闭它。
// 点击 Touch Bar 上的 bot 头像 → 原生 App 写 ~/.dsh/touchbar-click.json →
// 本插件 client 端轮询到 → ctx.uiWorkspace.openSession(botId) 切到该会话。
//
// host 端职责：
//   1. DSH 启动时 spawn 原生 App（若未运行），dispose 时 kill（只杀我们自己拉起的）
//   2. 注册 GET /api/ds-touchbar/poll：返回 click 文件里的最新 {id, ts}
import { spawn, execFile, execFileSync } from 'node:child_process'
import { existsSync, readFileSync, rmSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const name = 'ds-touchbar'
export const inject = ['connection']

const HOME = homedir()
const DSH_HOME = process.env.DSH_HOME || join(HOME, '.dsh')
// 原生 App 路径优先级: 环境变量 DSH_TOUCHBAR_APP > ~/.dsh/ds-touchbar/DSHTouchBar.app
const APP_BIN = process.env.DSH_TOUCHBAR_APP
  || join(DSH_HOME, 'ds-touchbar', 'DSHTouchBar.app', 'Contents', 'MacOS', 'DSHTouchBar')
const CLICK_FILE = join(DSH_HOME, 'touchbar-click.json')
const ROUTE = '/api/ds-touchbar/poll'
const POLL_PATH = 'api/ds-touchbar/poll'

function readClick() {
  try {
    if (!existsSync(CLICK_FILE)) return null
    const raw = readFileSync(CLICK_FILE, 'utf8')
    return JSON.parse(raw)
  } catch { return null }
}

export function apply(ctx) {
  // ---- 1. 原生 App 生命周期: 启动时拉起 + 看护(挂了重拉) + DSH 关闭时停 ----
  const running = () => {
    try { return execFileSync('/usr/bin/pgrep', ['-x', 'DSHTouchBar'], { encoding: 'utf8' }).trim().length > 0 }
    catch { return false }
  }
  const launch = () => {
    if (!existsSync(APP_BIN)) return
    try {
      const c = spawn(APP_BIN, [], { detached: true, stdio: 'ignore' })
      c.unref()
    } catch {}
  }

  ctx.effect(() => {
    if (!running()) launch()
    // 看护: 每 5 秒检查一次, App 没了就重拉
    const keep = setInterval(() => { if (!running()) launch() }, 5000)
    keep.unref?.()
    return () => {
      clearInterval(keep)
      // DSH 关闭: 停掉 Touch Bar App(满足"只在 DSH 开时显示")
      try { execFile('/usr/bin/pkill', ['-x', 'DSHTouchBar']) } catch {}
    }
  }, 'ds-touchbar: native app lifecycle')

  // ---- 2. 轮询端点：返回 click 文件内容 ----
  ctx.effect(() => ctx.connection.fetch.register({
    path: ROUTE,
    methods: ['GET'],
    requestBody: 'buffered',
    fetch: async () => {
      const click = readClick()
      return new Response(JSON.stringify({ click }), {
        status: 200,
        headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
      })
    },
  }), 'ds-touchbar: poll route')
}

// client 端通过这个常量知道轮询路径
export { POLL_PATH }

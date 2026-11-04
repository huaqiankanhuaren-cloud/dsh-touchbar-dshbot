import Cocoa

// 矢量实时自绘头像, 完全参照 ds-bot 表情逻辑:
//  - body: CHARACTER_PATHS[shape] 矢量
//  - 眼睛: 普通眼(圆角矩形) + 笑眼(弧线), 按 state(idle/alert=笑眼) 切换
//  - 眨眼: 眼睛 scaleY 连续动画 (bt-blink-idle 节奏: 5s 内眨 2 次)
//  - 注视: 眼睛组轻微左右/上下移动 (bt-gaze)
//  - 摇头晃脑: 由外层 controller 用 layer transform 驱动
class BotAvatarView: NSView {
    var shape: String = "whale"
    var colorHex: String = "#8E8E93"
    var botState: String = "working"     // working / idle / alert
    var phaseBase: Double = 0            // 每个 bot 随机相位, 错开眨眼
    private var lastDraw: Double = 0
    // 按状态节流的重绘: 活跃=30fps, 空闲=10fps
    func tickRedraw(_ now: Double) {
        let minInterval = (botState == "working") ? (1.0/30.0) : (1.0/10.0)
        if now - lastDraw >= minInterval {
            lastDraw = now
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // 眨眼相位: 返回眼睛 scaleY (1=睁, ~0.03=闭). 周期 5s, 眨两次(约 1.5s 和 3.5s 处)
    private func blinkScale(_ t: Double) -> CGFloat {
        // bt-blink-idle: 0,29.6%,35%,69.2%,74.6%,100% scaleY=1 ; 32.2%,71.8% scaleY=.03
        let p = (t + phaseBase).truncatingRemainder(dividingBy: 5.0) / 5.0   // 0..1
        let blinks: [(center: Double, width: Double)] = [(0.322, 0.028), (0.718, 0.028)]
        for b in blinks {
            let d = abs(p - b.center)
            if d < b.width {
                // 谷底
                let k = d / b.width           // 0..1
                let v = 0.03 + (1.0 - 0.03) * (k * k)  // 二次回升
                return CGFloat(min(1.0, v))
            }
        }
        return 1.0
    }

    // 注视偏移 (bt-gaze): 缓慢小幅移动
    private func gazeOffset(_ t: Double) -> CGPoint {
        let gx = sin(t * 0.9 + phaseBase) * 0.6
        let gy = cos(t * 0.7 + phaseBase * 1.3) * 0.5
        return CGPoint(x: gx, y: gy)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let px = bounds.width
        let pxH = bounds.height
        let color = hexColor(colorHex)
        let pathStr = CHARACTER_PATHS[shape] ?? CHARACTER_PATHS["whale"]!
        let eyes = CHARACTER_EYES[shape] ?? []

        let t = Date().timeIntervalSince1970

        // 计算 fit (同 shapeImage 逻辑)
        let raw = parseSVGPath(pathStr, scale: 1.0)
        var bb = raw.bounds
        let pad: CGFloat = 3
        // eyes 纳入 bounds (原始坐标)
        for e in eyes {
            let ex = CGFloat(e[0]), ey = CGFloat(e[1]), ew = CGFloat(e[2]), eh = CGFloat(e[3])
            bb = bb.union(CGRect(x: ex-ew/2, y: ey-eh/2, width: ew, height: eh))
        }
        if bb.width <= 0 { bb = CGRect(x:0,y:0,width:100,height:100) }
        let avail = min(px, pxH) - pad*2
        let fitScale = min(avail / bb.width, avail / bb.height)
        let offX = (px - bb.width*fitScale)/2 - bb.minX*fitScale
        let offY = (pxH - bb.height*fitScale)/2 - bb.minY*fitScale

        ctx.saveGState()
        // 翻转 y (SVG 朝下)
        ctx.translateBy(x: 0, y: pxH)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: offX, y: offY)
        ctx.scaleBy(x: fitScale, y: fitScale)

        // body
        let bp = parseSVGPath(pathStr, scale: 1.0)
        color.setFill(); bp.fill()

        // 眼睛
        let glow = NSColor(white: 0.12, alpha: 0.92)
        let happy = (botState == "idle" || botState == "alert")
        let bs = blinkScale(t)
        let gaze = gazeOffset(t)
        for e in eyes {
            let cx = CGFloat(e[0]), cy = CGFloat(e[1])
            let w = CGFloat(e[2]), h = CGFloat(e[3])
            let tilt = CGFloat(e[4]) * .pi / 180.0
            ctx.saveGState()
            ctx.translateBy(x: cx + gaze.x, y: cy + gaze.y)
            ctx.rotate(by: tilt)
            if happy {
                // 笑眼: 弧线
                let p = NSBezierPath()
                p.move(to: NSPoint(x: -w*0.62, y: h*0.14))
                p.curve(to: NSPoint(x: w*0.62, y: h*0.14), controlPoint1: NSPoint(x: 0, y: -h*0.42), controlPoint2: NSPoint(x: 0, y: -h*0.42))
                p.lineWidth = max(1.2, w*0.32); p.lineCapStyle = .round
                glow.setStroke(); p.stroke()
            } else {
                // 普通眼 + 眨眼 scaleY
                let hh = h * bs
                let rect = CGRect(x: -w/2, y: -hh/2, width: w, height: max(hh, 0.4))
                let ep = NSBezierPath(roundedRect: rect, xRadius: w/2, yRadius: max(hh,0.4)/2)
                glow.setFill(); ep.fill()
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}

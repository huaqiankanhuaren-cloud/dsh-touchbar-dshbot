import Cocoa
import Darwin

// DSHTouchBar — 在 MacBook Touch Bar 上显示 DSH 活动的 Bot
//
// 交互: 常态 Control Strip 显示 空闲=鲸鱼娘 / 工作=最活跃1个; 点开展开全部 Bot(可滑动,
//      活跃置顶带动画); 点头像切会话, 长按看名字, ✕ 收起; 矢量自绘表情(眨眼/注视/笑眼)。
//
// 文件结构(自上而下):
//   1. 配置        常量、TBConfig(~/.dsh/touchbar-config.json)
//   2. 私有 API     DFRFoundation(dlsym)、SVG path 解析
//   3. 图像         头像/鲸鱼娘 渲染与缓存
//   4. 数据模型     ActiveBot、数据脚本调用(runJSONFull)
//   5. 交互视图     ClickableView(点击/长按)、makeBotCapsule
//   6. 动画注册     BotAvatarView 全局重绘驱动
//   7. 渲染         renderStrip(常态)、renderExpanded(展开)
//   8. 控制器       TouchBarController(生命周期/刷新/展开)
//   9. 入口         AppDelegate、无 TouchBar 检测

// ============ 1. 配置 ============
let stripId = NSTouchBarItem.Identifier("com.yg.dshtouchbar.strip")
let scriptPath = NSString(string: "~/bin/dsh-active-bots-json.sh").expandingTildeInPath
// 可调参数: 读 ~/.dsh/touchbar-config.json (存在则覆盖默认), 无需重编译
struct TBConfig {
    static let shared: [String: Any] = {
        let path = NSString(string: "~/.dsh/touchbar-config.json").expandingTildeInPath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return [:]
    }()
    static func double(_ key: String, _ def: Double) -> Double { (shared[key] as? NSNumber)?.doubleValue ?? def }
}
let refreshInterval: TimeInterval = TBConfig.double("refreshInterval", 2.0)

// ============ 2. 私有 API / SVG 解析 ============
typealias DFRSetPresenceFn = @convention(c) (NSString, Bool) -> Void
func loadSetPresence() -> DFRSetPresenceFn? {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW) else { return nil }
    return dlsym(h, "DFRElementSetControlStripPresenceForIdentifier").map { unsafeBitCast($0, to: DFRSetPresenceFn.self) }
}
let setPresence = loadSetPresence()

// ---- SVG path → NSBezierPath ----
func parseSVGPath(_ d: String, scale: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    // 正确 tokenizer: 分离命令字母与数字, 负数 '-' 视为新数字开始
    var tokens = [String]()
    var num = ""
    for ch in d {
        if ch.isNumber || ch == "." {
            num.append(ch)
        } else if ch == "-" {
            if !num.isEmpty { tokens.append(num); num = "" }
            num.append("-")
        } else if ch == " " || ch == "," {
            if !num.isEmpty { tokens.append(num); num = "" }
        } else {
            // 命令字母
            if !num.isEmpty { tokens.append(num); num = "" }
            tokens.append(String(ch))
        }
    }
    if !num.isEmpty { tokens.append(num) }

    var i = 0; var cur = NSPoint.zero; var cmd = ""
    func nextNum() -> CGFloat? { guard i < tokens.count, let v = Double(tokens[i]) else { return nil }; i += 1; return CGFloat(v) }
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x*scale, y: y*scale) }
    var guardCount = 0
    while i < tokens.count && guardCount < 100000 {
        guardCount += 1
        let t = tokens[i]
        if t.count == 1 && t.rangeOfCharacter(from: .letters) != nil {
            cmd = t; i += 1
            if cmd == "Z" || cmd == "z" { path.close(); continue }
        }
        let before = i
        switch cmd {
        case "M": if let x = nextNum(), let y = nextNum() { cur = pt(x,y); path.move(to: cur) } else { i = tokens.count }
        case "m": if let x = nextNum(), let y = nextNum() { cur = NSPoint(x: cur.x+x*scale, y: cur.y+y*scale); path.move(to: cur) } else { i = tokens.count }
        case "L": if let x = nextNum(), let y = nextNum() { cur = pt(x,y); path.line(to: cur) } else { i = tokens.count }
        case "l": if let x = nextNum(), let y = nextNum() { cur = NSPoint(x: cur.x+x*scale, y: cur.y+y*scale); path.line(to: cur) } else { i = tokens.count }
        case "H": if let x = nextNum() { cur = NSPoint(x: x*scale, y: cur.y); path.line(to: cur) } else { i = tokens.count }
        case "h": if let x = nextNum() { cur = NSPoint(x: cur.x+x*scale, y: cur.y); path.line(to: cur) } else { i = tokens.count }
        case "V": if let y = nextNum() { cur = NSPoint(x: cur.x, y: y*scale); path.line(to: cur) } else { i = tokens.count }
        case "v": if let y = nextNum() { cur = NSPoint(x: cur.x, y: cur.y+y*scale); path.line(to: cur) } else { i = tokens.count }
        case "C": if let x1=nextNum(),let y1=nextNum(),let x2=nextNum(),let y2=nextNum(),let x=nextNum(),let y=nextNum() { let c=pt(x,y); path.curve(to:c,controlPoint1:pt(x1,y1),controlPoint2:pt(x2,y2)); cur=c } else { i = tokens.count }
        case "c": if let x1=nextNum(),let y1=nextNum(),let x2=nextNum(),let y2=nextNum(),let x=nextNum(),let y=nextNum() { let c=NSPoint(x:cur.x+x*scale,y:cur.y+y*scale); path.curve(to:c,controlPoint1:NSPoint(x:cur.x+x1*scale,y:cur.y+y1*scale),controlPoint2:NSPoint(x:cur.x+x2*scale,y:cur.y+y2*scale)); cur=c } else { i = tokens.count }
        default:
            // 未知命令: 跳过该 token 防死循环
            i += 1
        }
        // 若本轮未推进且非命令字母, 强制前进
        if i == before && !(t.count==1 && t.rangeOfCharacter(from: .letters) != nil) { i += 1 }
    }
    return path
}

// ============ 3. 图像渲染与缓存 ============
var shapeCache: [String: NSImage] = [:]

// 空闲态 Q版鲸鱼娘大头, 睁眼/闭眼两帧, 按高度等比缩放
var whaleGirlCache: [String: NSImage] = [:]
func whaleGirlFrame(_ b64: String, height h: CGFloat) -> NSImage? {
    let key = "\(b64.hashValue)-\(Int(h))"
    if let c = whaleGirlCache[key] { return c }
    guard let data = Data(base64Encoded: b64), let src = NSImage(data: data) else { return nil }
    let ratio = src.size.width / src.size.height
    let target = NSSize(width: h * ratio, height: h)
    let img = NSImage(size: target)
    img.lockFocus()
    src.draw(in: NSRect(origin: .zero, size: target))
    img.unlockFocus()
    whaleGirlCache[key] = img
    return img
}
func whaleGirlImageCustomHeight(_ h: CGFloat) -> NSImage? { whaleGirlFrame(whaleGirlBase64, height: h) }



// ============ 4. 数据模型与脚本调用 ============
struct ActiveBot { let id: String; let sessionId: String; let name: String; let abbr: String; let colorHex: String; let shape: String; let sec: Int; let state: String }



// 一次执行同时拿 active 和 all(省一次 python 启动)
func runJSONFull() -> (active: [ActiveBot], all: [ActiveBot]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: scriptPath)
    let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return ([], []) }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
    func parse(_ key: String) -> [ActiveBot] {
        guard let arr = obj[key] as? [[String: Any]] else { return [] }
        return arr.map { ActiveBot(id: $0["id"] as? String ?? "", sessionId: $0["sessionId"] as? String ?? ($0["id"] as? String ?? ""), name: $0["name"] as? String ?? "?", abbr: $0["abbr"] as? String ?? ($0["name"] as? String ?? "?"), colorHex: $0["color"] as? String ?? "#8E8E93", shape: $0["shape"] as? String ?? "whale", sec: $0["sec"] as? Int ?? 0, state: $0["state"] as? String ?? "idle") }
    }
    return (parse("active"), parse("all"))
}

// 全部 bot(含空闲), working 在前


func hexColor(_ hex: String) -> NSColor {
    var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
    if s.count == 6 { return NSColor(srgbRed: CGFloat((v>>16)&0xFF)/255, green: CGFloat((v>>8)&0xFF)/255, blue: CGFloat(v&0xFF)/255, alpha: 1) }
    return .systemGray
}

// Control Strip 上空间小：显示 第一个鲸鱼头像 + 计数徽标
// 点击头像 → 写 botId 到 click 文件, 供 DSH 插件轮询
let clickFilePath = NSString(string: "~/.dsh/touchbar-click.json").expandingTildeInPath
func writeClick(_ botId: String) {
    let obj: [String: Any] = ["id": botId, "ts": Int(Date().timeIntervalSince1970 * 1000)]
    if let data = try? JSONSerialization.data(withJSONObject: obj) {
        try? data.write(to: URL(fileURLWithPath: clickFilePath))
    }
}

// 可点击胶囊: NSView + NSClickGestureRecognizer (NSButton 的子视图在 Touch Bar 不渲染)
var currentNameTip: NSView?
var tipHideTimer: Timer?

class ClickableView: NSView, NSGestureRecognizerDelegate {
    var botId: String = ""
    var botName: String = ""
    var clickTarget: String = ""
    var onExpand: (() -> Void)?
    var tapMode: CapsuleTap = .switchSession
    private var nameTip: NSView?

    // click 手势: 若长按(其他手势)成功则不触发 click
    func gestureRecognizer(_ g: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer) -> Bool {
        // 让 click 等待 press 失败(即: press 识别成功=长按, click 不触发)
        if g is NSClickGestureRecognizer && other is NSPressGestureRecognizer { return true }
        return false
    }

    @objc func longPressed() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        showNameTip()
    }
    private func showNameTip() {
        currentNameTip?.removeFromSuperview(); currentNameTip = nil
        nameTip?.removeFromSuperview()
        let lbl = NSTextField(labelWithString: botName.isEmpty ? "?" : botName)
        lbl.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        lbl.textColor = .white
        lbl.sizeToFit()
        let pad: CGFloat = 8
        let textW = lbl.intrinsicContentSize.width
        let tipW = min(textW + pad*2, 160)
        let tipH: CGFloat = 28
        let tip = NSView(frame: NSRect(x: 0, y: 0, width: tipW, height: tipH))
        tip.wantsLayer = true
        tip.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        tip.layer?.cornerRadius = 7
        // label 撑满气泡内区, 文字水平居中, 垂直居中
        lbl.alignment = .center
        lbl.frame = NSRect(x: 0, y: (tipH-lbl.frame.height)/2 - 2, width: tipW, height: lbl.frame.height)
        tip.addSubview(lbl)
        // 挂到展开区根视图右侧(向上找 superview 链的顶层)
        var top: NSView? = self
        while let p = top?.superview { top = p }
        if let root = top {
            // 气泡居中盖在被长按的头像自己身上(不挡邻居), 1秒即消失
            // 气泡贴在该 bot 右边缘向右侧展开, 覆盖右侧相邻 bot(临时提示, 1秒消失)
            let selfRect = self.convert(bounds, to: root)
            var tx = selfRect.maxX + 2
            if tx + tipW > root.bounds.width - 4 { tx = root.bounds.width - tipW - 4 }  // 避免超出屏幕最右
            tip.frame.origin = NSPoint(x: tx, y: (root.bounds.height - tipH)/2)
            root.addSubview(tip)
            nameTip = tip
            currentNameTip = tip
            // 用 Timer 移除(比 asyncAfter 在 Touch Bar 环境更可靠), 存到全局防释放
            tipHideTimer?.invalidate()
            tipHideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak tip] _ in
                DispatchQueue.main.async {
                    tip?.removeFromSuperview()
                    if currentNameTip === tip { currentNameTip = nil }
                }
            }
            RunLoop.main.add(tipHideTimer!, forMode: .common)
        }
    }
    private func visualTap() {
        guard let layer = self.layer else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 0.85, 1.0]; pop.keyTimes = [0, 0.5, 1]; pop.duration = 0.22
        layer.add(pop, forKey: "pop")
    }
    @objc func handleClick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        visualTap()
        switch tapMode {
        case .expand: onExpand?()
        case .switchSession: let t = clickTarget.isEmpty ? botId : clickTarget; if !t.isEmpty { writeClick(t) }
        }
    }
}

// ============ 5. 交互视图 ============
var layoutYOffset: CGFloat = CGFloat(TBConfig.double("layoutYOffset", -1))   // 全局垂直微调

// tapMode: .switchSession(展开态点击切会话) / .expand(常态点击展开)
enum CapsuleTap { case switchSession, expand }

func makeBotCapsule(_ bot: ActiveBot, height H: CGFloat = 30, tap: CapsuleTap = .switchSession, onExpand: (() -> Void)? = nil, drawBg: Bool = true) -> NSView {
    let color = hexColor(bot.colorHex)
    let ivH: CGFloat = 28
    let pad: CGFloat = 3
    let totalW = ivH + pad*2

    let v = ClickableView(frame: NSRect(x: 0, y: 0, width: totalW, height: H))
    v.botId = bot.id
    v.botName = bot.name
    v.clickTarget = bot.sessionId
    v.onExpand = onExpand
    v.tapMode = tap

    // 矢量自绘头像(连续眨眼+笑眼+注视)
    let av = BotAvatarView(frame: NSRect(x: pad, y: (H-ivH)/2 + layoutYOffset, width: ivH, height: ivH))
    av.shape = bot.shape
    av.colorHex = bot.colorHex
    av.botState = bot.state
    av.phaseBase = Double.random(in: 0..<5)
    v.addSubview(av)
    registerAvatarForAnimation(av)

    v.wantsLayer = true
    if drawBg {
        v.layer?.backgroundColor = color.withAlphaComponent(bot.state == "working" ? 0.22 : 0.08).cgColor
        v.layer?.cornerRadius = 7
    }

    // 摇头晃脑(bt-bob: 绕底部 rotate + bob) — 作用在 avatarView 的 layer
    let working = bot.state == "working"
    let amp: CGFloat = working ? 1.0 : 0.6
    av.wantsLayer = true
    let rot = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    rot.values = [0, -5*Double(amp), 4*Double(amp), -2*Double(amp), 0].map { $0 * .pi / 180 }
    rot.keyTimes = [0, 0.3, 0.65, 0.85, 1]
    rot.duration = working ? 1.6 : 2.4
    rot.repeatCount = .infinity
    rot.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    av.layer?.add(rot, forKey: "sway")
    let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
    let bobPx = working ? 1.4 : 0.7
    bob.values = [0, -bobPx, 0, bobPx*0.4, 0]
    bob.keyTimes = [0, 0.3, 0.65, 0.85, 1]
    bob.duration = working ? 1.6 : 2.4
    bob.repeatCount = .infinity
    bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    av.layer?.add(bob, forKey: "bob")
    av.alphaValue = working ? 1.0 : 0.6

    // 长按手势(0.5s): 显示名字
    let press = NSPressGestureRecognizer(target: v, action: #selector(ClickableView.longPressed))
    press.minimumPressDuration = 0.5
    press.allowedTouchTypes = .direct
    press.delegate = v
    v.addGestureRecognizer(press)
    // 点击手势
    let click = NSClickGestureRecognizer(target: v, action: #selector(ClickableView.handleClick))
    click.allowedTouchTypes = .direct
    click.delegate = v
    v.addGestureRecognizer(click)
    return v
}

// 全局动画注册表: 定时触发所有 BotAvatarView 重绘(驱动眨眼/注视)
// ============ 6. 动画注册 ============
private var avatarViews: [WeakBox] = []
private var avatarTicker: Timer?
class WeakBox { weak var v: BotAvatarView?; init(_ v: BotAvatarView){self.v=v} }
func registerAvatarForAnimation(_ av: BotAvatarView) {
    avatarViews.append(WeakBox(av))
    if avatarTicker == nil {
        // 30fps 基础 tick; 每个 avatar 内部按 state 节流(活跃=30fps, 空闲=10fps)
        avatarTicker = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { _ in
            avatarViews = avatarViews.filter { $0.v != nil }
            let now = Date().timeIntervalSince1970
            for box in avatarViews { box.v?.tickRedraw(now) }
        }
    }
}


// ============ 7. 渲染(常态/展开) ============
func renderStrip(_ bots: [ActiveBot], onExpand: (() -> Void)? = nil) -> NSView {
    let H: CGFloat = 30
    if bots.isEmpty {
        // 空闲态: 鲸鱼娘, 点击=展开(显示所有活动bot, 虽然此刻通常无)
        let ivH: CGFloat = 28
        let gw = whaleGirlImageCustomHeight(ivH)?.size.width ?? ivH
        let leftPad: CGFloat = gw * 0.25
        let rightPad: CGFloat = 6
        let v = ClickableView(frame: NSRect(x: 0, y: 0, width: leftPad + gw + rightPad, height: H))
        v.tapMode = .expand
        v.onExpand = onExpand
        let ig = NSClickGestureRecognizer(target: v, action: #selector(ClickableView.handleClick))
        ig.allowedTouchTypes = .direct
        v.addGestureRecognizer(ig)
        let iv = NSImageView(frame: NSRect(x: leftPad, y: (H-ivH)/2 + layoutYOffset, width: gw, height: ivH))
        iv.image = whaleGirlImageCustomHeight(ivH)
        iv.wantsLayer = true
        v.addSubview(iv)
        // 鲸鱼娘柔和浮动 + 呼吸
        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = -1.2; float.toValue = 1.2
        float.duration = 1.6; float.autoreverses = true; float.repeatCount = .infinity
        float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iv.layer?.add(float, forKey: "float")
        let breath = CABasicAnimation(keyPath: "transform.scale")
        breath.fromValue = 0.98; breath.toValue = 1.03
        breath.duration = 1.9; breath.autoreverses = true; breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iv.layer?.add(breath, forKey: "breath")
        return v
    }
    // 工作态: 只显示最活跃 1 个; 无底色框, 裸头像居中; 点击=展开
    let top = bots.max(by: { $0.sec < $1.sec }) ?? bots[0]
    let cap = makeBotCapsule(top, height: H, tap: .expand, onExpand: onExpand, drawBg: false)
    let leftComp = cap.frame.width * 0.3   // 抵消系统左对齐, 让头像居中
    let container = NSView(frame: NSRect(x: 0, y: 0, width: cap.frame.width + leftComp, height: H))
    cap.frame.origin = NSPoint(x: leftComp, y: 0)
    container.addSubview(cap)
    return container
}

// 可点击的"展开"按钮
class ExpandButton: NSView {
    var onTap: (() -> Void)?
    @objc func tapped() { onTap?() }
}

// 透明命中层: 按点击 x 坐标命中对应 bot, 规避 scroll 子view 收不到点击的问题


// 展开面板: NSScrollView 横排所有 bot + 收起按钮
func renderExpanded(_ bots: [ActiveBot], onCollapse: @escaping () -> Void) -> NSView {
    let H: CGFloat = 30
    let totalW: CGFloat = 640
    let closeW: CGFloat = 36

    let root = NSView(frame: NSRect(x: 0, y: 0, width: totalW, height: H))

    // 左侧常驻 x 按钮
    let closeBtn = ExpandButton()
    closeBtn.onTap = onCollapse
    closeBtn.frame = NSRect(x: 0, y: 0, width: closeW, height: H)
    let xLabel = NSTextField(labelWithString: "✕")
    xLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
    xLabel.textColor = NSColor.controlAccentColor
    xLabel.sizeToFit()
    xLabel.frame = NSRect(x: (closeW-xLabel.intrinsicContentSize.width)/2, y: (H-xLabel.intrinsicContentSize.height)/2, width: xLabel.intrinsicContentSize.width, height: xLabel.intrinsicContentSize.height)
    closeBtn.addSubview(xLabel)
    let cg = NSClickGestureRecognizer(target: closeBtn, action: #selector(ExpandButton.tapped))
    cg.allowedTouchTypes = .direct
    closeBtn.addGestureRecognizer(cg)
    root.addSubview(closeBtn)

    // 头像区(可横向滚动, 居中)
    let gap: CGFloat = 10
    let capW: CGFloat = 30
    let areaX = closeW + 6
    let areaW = totalW - areaX - 6
    let scroll = NSScrollView(frame: NSRect(x: areaX, y: 0, width: areaW, height: H))
    scroll.hasHorizontalScroller = false
    scroll.hasVerticalScroller = false
    scroll.drawsBackground = false
    scroll.horizontalScrollElasticity = .allowed
    let contentW = CGFloat(bots.count) * capW + CGFloat(max(bots.count-1,0)) * gap
    let docW = max(contentW, areaW)
    let doc = NSView(frame: NSRect(x: 0, y: 0, width: docW, height: H))
    var x: CGFloat = contentW < areaW ? (areaW - contentW)/2 : 0
    for bot in bots {
        let cap = makeBotCapsule(bot, height: H, tap: .switchSession)
        cap.frame.origin = NSPoint(x: x, y: 0)
        doc.addSubview(cap)
        x += capW + gap
    }
    scroll.documentView = doc
    root.addSubview(scroll)
    return root
}

// ============ 8. Touch Bar 控制器 ============
class TouchBarController: NSObject, NSTouchBarDelegate {
    let stripItem = NSCustomTouchBarItem(identifier: stripId)
    let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 30))
    var lastBotsSignature = ""
    var latestBots: [ActiveBot] = []
    var latestAllBots: [ActiveBot] = []
    var expandedBar: NSTouchBar?
    var expandedItem: NSCustomTouchBarItem?
    var expandSig = ""
    var expandedRefreshTimer: Timer?
    var isExpanded = false
    let expandedItemId = NSTouchBarItem.Identifier("com.yg.dshtouchbar.expanded")

    func setup() {
        fputs("[DSH] setup start\n", stderr)
        let _bots0 = runJSONFull().active
        hostView.autoresizingMask = []
        stripItem.view = hostView
        fillHostView(_bots0)
        NSTouchBarItem.addSystemTrayItem(stripItem)
        setPresence?(stripId.rawValue as NSString, true)

        Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            DispatchQueue.global().async {
                let full = runJSONFull()
                DispatchQueue.main.async { self?.latestAllBots = full.all; self?.fillHostView(full.active) }
            }
        }
    }
    func fillHostView(_ bots: [ActiveBot]) {
        // 指纹: 空闲=idle; 否则 id+abbr 组合。相同则跳过重建, 避免重置动画
        let top = bots.max(by: { $0.sec < $1.sec })
        let sig = bots.isEmpty ? "idle" : (top?.id ?? "") + "@\(bots.count)"
        if sig == lastBotsSignature { return }
        lastBotsSignature = sig
        latestBots = bots
        for sub in hostView.subviews { sub.removeFromSuperview() }
        let content = renderStrip(bots, onExpand: { [weak self] in self?.showExpanded() })
        let cw = content.frame.width
        let h: CGFloat = 30
        hostView.frame = NSRect(x: 0, y: 0, width: cw, height: h)
        content.frame = NSRect(x: 0, y: 0, width: cw, height: h)
        hostView.addSubview(content)
        hostView.needsDisplay = true
        hostView.layoutSubtreeIfNeeded()
    }

    // 展开: presentSystemModal 弹可滑动大区域
    func showExpanded() {
        if isExpanded { return }
        isExpanded = true
        latestAllBots = runJSONFull().all
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [expandedItemId]
        expandedBar = bar
        NSTouchBar.presentSystemModalTouchBar(bar, placement: 1, systemTrayItemIdentifier: stripId)
        // 展开时定时刷新: bot 活跃变化会自动重排(活跃挪最前)
        expandedRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.global().async {
                let all = runJSONFull().all
                DispatchQueue.main.async {
                    // 指纹: 顺序/状态/秒变化才重建, 否则跳过(防闪烁)
                    let sig = all.map { "\($0.id):\($0.state)" }.joined(separator: "|")
                    if sig == self.expandSig { return }
                    self.expandSig = sig
                    self.latestAllBots = all
                    if let item = self.expandedItem {
                        item.view = renderExpanded(all) { [weak self] in self?.hideExpanded() }
                    }
                }
            }
        }
    }
    func hideExpanded() {
        if !isExpanded { return }
        if let bar = expandedBar {
            NSTouchBar.dismissSystemModalTouchBar(bar)
        }
        expandedBar = nil
        expandedItem = nil
        expandedRefreshTimer?.invalidate()
        expandedRefreshTimer = nil
        isExpanded = false
        // 保证常驻 item 仍在
        setPresence?(stripId.rawValue as NSString, true)
    }
}

// NSTouchBarDelegate for expandedBar
extension TouchBarController {
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier == expandedItemId {
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = renderExpanded(latestAllBots) { [weak self] in self?.hideExpanded() }
            expandedItem = item
            return item
        }
        return nil
    }
}

// 无 Touch Bar 检测: DFRGetStatus() 返回 >0 表示有 Touch Bar 硬件
// ============ 9. 入口 ============
func hasTouchBar() -> Bool {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW),
          let sym = dlsym(h, "DFRGetStatus") else { return false }
    typealias StatusFn = @convention(c) () -> Int32
    let fn = unsafeBitCast(sym, to: StatusFn.self)
    return fn() > 0
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = TouchBarController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 无 Touch Bar 时不空转(外接键盘/台式机)
        if !hasTouchBar() {
            fputs("[DSH] no touchbar, exit\n", stderr)
            NSApp.terminate(nil)
            return
        }
        controller.setup()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()


// v2rayN 退出保护 —— 在系统层拦截 Cmd+Q
//
// 交互设计:
//   按住 Cmd+Q  -> 全屏灰屏糊化 + 红色粗进度条, 随按住时长从左到右填充
//   松手        -> 淡出取消, v2rayN 继续运行 (什么都没发生)
//   按住满 8 秒 -> 主动退出 v2rayN
//
//   没有按钮、没有窗口边框、不需要动鼠标 —— 全程只靠 Cmd+Q 一个手势。
//
// 为什么用 CGEventTap:
//   macOS 的 Cmd+Q 是系统级退出, 应用自己不做确认就没有确认。只有事件拦截
//   能在按键阶段把它吞掉, 让 v2rayN 根本收不到 —— 它是"不会退出",
//   而不是"退出后被拉回来"。
//
// ⚠️ 事件回调绝不能阻塞 —— 回调卡住会冻住【整个系统】的键盘输入。
//    所以回调只做判断和状态更新, UI 在独立的 60fps 渲染循环里跑。
//
// 硬前提: 辅助功能(Accessibility)权限。macOS 不允许没有该权限的程序拦截键盘。
//
// 编译: swiftc -O -o quit-guard quit-guard.swift
// 日志: ~/Library/Logs/v2rayn-quitguard.log

import Cocoa
import ApplicationServices

// ---------------- 配置 ----------------
let V2RAYN_BUNDLE_ID = "2dust.v2rayN"
let HOLD_SECONDS: Double = 8.0     // 按住多久确认退出
let FADE_OUT: Double = 0.28        // 淡出时长
let MAX_DISPLAY: Double = 20.0     // 兜底: 万一收不到松手事件, 最多显示这么久
let KEYCODE_Q: Int64 = 12          // kVK_ANSI_Q

let home = FileManager.default.homeDirectoryForCurrentUser.path
let allowFlag = "\(home)/Library/Application Support/v2rayN/allow-quit"
let logPath = "\(home)/Library/Logs/v2rayn-quitguard.log"

// 受保护应用的 Bundle ID。用 bundle id 比进程名准, 不会误命中 Chrome Helper。
// 浏览器装的 App(PWA) 仍是浏览器主进程在跑, 所以列浏览器就覆盖了。
let PROTECTED_BUNDLE_IDS: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
    "co.zeit.hyper", "org.tabby", "com.mitchellh.ghostty",
    "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
    "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser",
    "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    "com.openai.chat", "com.anthropic.claudefordesktop",
    "ai.perplexity.mac", "com.todesktop.230313mzl4w4u92",
    "com.lmstudio.app", "com.electron.ollama",
]

func log(_ msg: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// ⚠️ 不要用 NSWorkspace.shared.runningApplications 全量枚举。
//    它会遍历系统里所有 App(含 /System/Applications 下受 SIP 保护的包), 触发
//    kTCCServiceSystemPolicyAllFiles 检查, 系统就弹"想控制这台 Mac 并访问你的数据"。
//    我们只需要知道名单里那几个在不在跑 —— 定向查询就够了, 不碰别的。
func protectedApps() -> [String] {
    var names: [String] = []
    for bid in PROTECTED_BUNDLE_IDS {
        guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bid).first,
              !app.isTerminated else { continue }
        names.append(app.localizedName ?? bid)
    }
    return Array(Set(names)).sorted()
}

// 同上: 定向查询, 不做全量枚举
func v2raynApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: V2RAYN_BUNDLE_ID)
        .first { !$0.isTerminated }
}

// ---------------- 粗进度条 ----------------
// 圆角轨道 + 红色渐变填充 + 发光 + 上半高光, 让它有体积感而不是一块死色。
final class ProgressBarView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 1)
        let radius = r.height / 2

        let track = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSColor(white: 1, alpha: 0.13).setFill()
        track.fill()

        guard progress > 0.001 else { return }

        let fillW = max(r.width * CGFloat(progress), r.height)
        let fillRect = NSRect(x: r.minX, y: r.minY, width: fillW, height: r.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.systemRed.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = .zero
        shadow.set()
        // 红色系: 玫红 -> 正红 -> 亮橙红
        NSGradient(colors: [
            NSColor(calibratedRed: 1.00, green: 0.28, blue: 0.40, alpha: 1),
            NSColor(calibratedRed: 0.95, green: 0.15, blue: 0.20, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.18, alpha: 1),
        ])?.draw(in: fill, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        // 上半部高光
        NSGraphicsContext.saveGraphicsState()
        fill.addClip()
        NSGradient(colors: [
            NSColor(white: 1, alpha: 0.32),
            NSColor(white: 1, alpha: 0.0),
        ])?.draw(in: NSRect(x: fillRect.minX, y: fillRect.midY,
                            width: fillRect.width, height: fillRect.height / 2),
                 angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// ---------------- 全屏灰屏糊化覆盖层 ----------------
final class Overlay {
    private var windows: [NSWindow] = []
    private var bars: [ProgressBarView] = []
    private var statusLabels: [NSTextField] = []
    private var appLabels: [NSTextField] = []
    private var renderTimer: Timer?
    private var started = Date()
    private var built = false
    private(set) var visible = false

    var elapsed: Double { Date().timeIntervalSince(started) }

    private func build() {
        for screen in NSScreen.screens {
            let win = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .screenSaver          // 盖住 Dock 与菜单栏
            win.ignoresMouseEvents = true     // 纯展示, 不抢鼠标
            win.hasShadow = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))

            // 1) 糊化: 让背后的内容变成毛玻璃
            let blur = NSVisualEffectView(frame: root.bounds)
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            root.addSubview(blur)

            // 2) 灰色压暗: 保证文字对比度
            let dim = NSView(frame: root.bounds)
            dim.wantsLayer = true
            dim.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.58).cgColor
            dim.autoresizingMask = [.width, .height]
            root.addSubview(dim)

            // 3) 三行内容, 垂直居中
            let w: CGFloat = min(780, root.bounds.width - 140)
            let x = (root.bounds.width - w) / 2
            let cy = root.bounds.height / 2

            let title = Overlay.label("", size: 32, weight: .bold, color: .white, width: w)
            title.frame.origin = NSPoint(x: x, y: cy + 158)
            root.addSubview(title)

            let apps = Overlay.label("", size: 17, weight: .medium,
                                     color: NSColor(white: 1, alpha: 0.70), width: w)
            apps.frame.origin = NSPoint(x: x, y: cy + 112)
            root.addSubview(apps)
            appLabels.append(apps)

            // 倒计时文字在进度条【上方】
            let status = Overlay.label("", size: 15, weight: .semibold,
                                       color: NSColor(white: 1, alpha: 0.88), width: w)
            status.frame.origin = NSPoint(x: x, y: cy - 26)
            root.addSubview(status)
            statusLabels.append(status)

            let bar = ProgressBarView(frame: NSRect(x: x, y: cy - 74, width: w, height: 24))
            root.addSubview(bar)
            bars.append(bar)

            win.contentView = root
            windows.append(win)
        }
        built = true
    }

    private static func label(_ s: String, size: CGFloat, weight: NSFont.Weight,
                              color: NSColor, width: CGFloat) -> NSTextField {
        let t = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: size * 1.7))
        t.stringValue = s
        t.isEditable = false; t.isBordered = false; t.drawsBackground = false
        t.font = NSFont.systemFont(ofSize: size, weight: weight)
        t.textColor = color
        t.alignment = .center
        t.lineBreakMode = .byTruncatingTail
        return t
    }

    func show(apps: [String]) {
        if !built { build() }
        started = Date()
        let appText = apps.isEmpty ? "（无）" : apps.joined(separator: "、")

        for win in windows {
            guard let root = win.contentView else { continue }
            for v in root.subviews {
                guard let l = v as? NSTextField else { continue }
                if l.font?.pointSize == 32 {
                    l.stringValue = "v2rayN 没有退出 —— Cmd+Q 已被拦截"
                }
            }
            win.alphaValue = 0
            win.orderFrontRegardless()
        }
        for l in appLabels { l.stringValue = "保护中：\(appText)" }
        for b in bars { b.progress = 0 }
        for s in statusLabels {
            s.stringValue = String(format: "按住 Cmd+Q 满 %.0f 秒确认退出", HOLD_SECONDS)
        }

        visible = true
        animateAlpha(to: 1, duration: 0.16)
        startRenderLoop()
    }

    func hide() {
        guard visible else { return }
        visible = false
        stopRenderLoop()
        animateAlpha(to: 0, duration: FADE_OUT) { [weak self] in
            self?.windows.forEach { $0.orderOut(nil) }
        }
    }

    private func animateAlpha(to: CGFloat, duration: Double, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for w in windows { w.animator().alphaValue = to }
        } completionHandler: { completion?() }
    }

    private func startRenderLoop() {
        stopRenderLoop()
        // 60fps, 保证进度条丝滑。用 .common 模式 —— 默认模式在某些 run loop
        // 状态下会被饿死(Timer.scheduledTimer 在模态循环里就不触发, 踩过)。
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(t, forMode: .common)
        renderTimer = t
    }

    private func stopRenderLoop() {
        renderTimer?.invalidate(); renderTimer = nil
    }

    private func tick() {
        let e = elapsed
        let raw = min(e / HOLD_SECONDS, 1.0)
        // 轻微缓出, 让起始阶段更跟手、收尾更稳
        let eased = 1 - pow(1 - raw, 1.5)
        for b in bars { b.progress = eased }

        let left = max(HOLD_SECONDS - e, 0)
        for s in statusLabels {
            s.stringValue = left > 0.05
                ? String(format: "%.1f 秒后退出 · 松手即取消", left)
                : "正在退出…"
        }
    }

    func teardown() {
        stopRenderLoop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll(); bars.removeAll()
        statusLabels.removeAll(); appLabels.removeAll()
        built = false
    }
}

// ---------------- 拦截与状态机 ----------------
final class Guard {
    private var overlay = Overlay()
    private var holding = false
    private var apps: [String] = []
    private var safetyTimer: Timer?

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// Cmd+Q(keyDown)。返回 true 表示放行, false 表示吞掉。
    func keyDown() -> Bool {
        if FileManager.default.fileExists(atPath: allowFlag) { return true }
        if protectedApps().isEmpty { return true }

        if !holding {
            holding = true
            apps = protectedApps()
            log("拦截 Cmd+Q: 受保护进程 [\(apps.joined(separator: ", "))]")
            let list = apps
            onMain { [weak self] in
                guard let self else { return }
                self.overlay.show(apps: list)
                self.armSafety()
            }
        }
        // 按住期间系统持续发 keyDown(自动重复) —— 吞掉, v2rayN 收不到就不会退出
        return false
    }

    /// Cmd+Q 或 Command 键被松开
    func release() {
        guard holding else { return }
        holding = false
        safetyTimer?.invalidate(); safetyTimer = nil

        let held = overlay.elapsed
        let quit = held >= HOLD_SECONDS
        log(quit
            ? String(format: "按住 %.1f 秒 -> 确认退出 v2rayN", held)
            : String(format: "按住 %.1f 秒后松手 -> 取消, v2rayN 全程未退出", held))

        onMain { [weak self] in self?.overlay.hide() }
        if quit { onMain { v2raynApp()?.terminate() } }
    }

    /// 兜底: 万一松手事件丢失(例如 Command 先被松开), 最多显示 MAX_DISPLAY 秒
    private func armSafety() {
        safetyTimer?.invalidate()
        let t = Timer(timeInterval: MAX_DISPLAY, repeats: false) { [weak self] _ in
            guard let self, self.holding else { return }
            log("⚠ 超过 \(Int(MAX_DISPLAY)) 秒未收到松手事件, 强制取消")
            self.release()
        }
        RunLoop.current.add(t, forMode: .common)
        safetyTimer = t
    }
}

let guardInstance = Guard()
var globalTap: CFMachPort?
let EVENT_MARKER: Int64 = 0x51_55_47_44   // 'QUGD'

// ---------------- 主流程 ----------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// ---------------- 权限检查 ----------------
//
// ⚠️ 这里【绝对不要】调用 AXIsProcessTrustedWithOptions(prompt: true)。
//
//    那个 API 会弹系统授权框。配合 LaunchAgent 的重启(或用户的任何操作),
//    弹窗会反复出现 —— 用户实测"每点一次就在新位置弹一个新的, 无止境"。
//    而且那个框的默认按钮是「Deny」(蓝色高亮), 顺手点掉就会让 TCC 记下拒绝。
//
//    正确做法: 只做【静默检查】(AXIsProcessTrusted 不带 prompt)。
//    没权限就安静退出, 由 launchd 按 ThrottleInterval 慢慢重试, 不弹任何窗。
//    用户自己去「系统设置 → 隐私与安全性 → 辅助功能」手动添加即可。
func hasAccessibility() -> Bool {
    AXIsProcessTrusted()          // 纯查询, 不弹窗
}

if !hasAccessibility() {
    log("=== quit-guard: 尚未获得辅助功能权限, 静默退出 (不弹窗) ===")
    log("    手动添加方法: 系统设置 → 隐私与安全性 → 辅助功能 → +")
    log("    路径: /usr/local/libexec/v2rayn-tun/quit-guard")
    FileHandle.standardError.write(
        "quit-guard: 缺少辅助功能权限。请在 系统设置 → 隐私与安全性 → 辅助功能 里添加本程序。\n"
            .data(using: .utf8)!)
    exit(0)      // 静默退出。plist 里 ThrottleInterval 会限制重试频率。
}

let mask = (1 << CGEventType.keyDown.rawValue)
         | (1 << CGEventType.keyUp.rawValue)
         | (1 << CGEventType.flagsChanged.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(mask),
    callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = globalTap { CGEvent.tapEnable(tap: t, enable: true) }
            log("event tap 被系统禁用, 已重新启用")
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == EVENT_MARKER {
            return Unmanaged.passUnretained(event)
        }

        // 命令键松开 -> 结束按住状态。放在最前面, 否则会漏。
        if type == .flagsChanged {
            if !event.flags.contains(.maskCommand) { guardInstance.release() }
            return Unmanaged.passUnretained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == KEYCODE_Q else { return Unmanaged.passUnretained(event) }

        // 只在 v2rayN 是前台应用时管。别的应用按 Cmd+Q 完全不受影响。
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == V2RAYN_BUNDLE_ID else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            guardInstance.release()
            return nil
        }
        if type == .keyDown {
            guard event.flags.contains(.maskCommand) else {
                return Unmanaged.passUnretained(event)
            }
            return guardInstance.keyDown() ? Unmanaged.passUnretained(event) : nil
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    // 权限显示有、但 event tap 建不起来 —— 通常是 TCC 里那条记录的 CDHash
    // 和当前二进制对不上(例如刚换过二进制)。静默退出, 不弹窗、不空转。
    log("❌ 无法创建 event tap —— TCC 记录可能与当前二进制不匹配。")
    log("   请到「系统设置 → 隐私与安全性 → 辅助功能」里删掉 quit-guard 条目后重新添加:")
    log("   /usr/local/libexec/v2rayn-tun/quit-guard")
    exit(3)
}

globalTap = tap
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("event tap 已启用: 只有 v2rayN 在前台时, 按住 Cmd+Q \(Int(HOLD_SECONDS)) 秒才退出")

app.run()

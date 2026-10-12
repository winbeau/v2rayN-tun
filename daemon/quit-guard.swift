// v2rayN 退出保护 —— 在系统层拦截 Cmd+Q
//
// 设计要点(和上一版的关键区别):
//   上一版是"检测到 v2rayN 退出后把它拉回来", 那意味着 v2rayN 真的关过一次 ——
//   连接会断, 窗口会重建, 是错的做法。
//
//   这一版用 CGEventTap 在建键阶段就把 Cmd+Q 吞掉, **v2rayN 根本收不到这个事件**,
//   于是它从来不会退出。只有你在弹窗里长按确认, 才由我们主动 terminate 它。
//
//   所以正确路径下, v2rayN 的进程、窗口、连接自始至终没有中断过。
//
// 拦截范围:
//   仅当前台应用是 v2rayN 时。别的应用里按 Cmd+Q 完全不受影响。
//
// 放行条件(满足任一就不拦):
//   · ~/Library/Application Support/v2rayN/allow-quit 开关存在
//   · 没有任何受保护进程在运行(终端/浏览器/AI 应用)
//
// 硬前提: 辅助功能(Accessibility)权限。
//   macOS 不允许任何程序在没有该权限时拦截键盘事件。首次运行会弹系统提示,
//   需要到「系统设置 → 隐私与安全性 → 辅助功能」里勾选本程序。
//
// 编译: swiftc -O -o quit-guard quit-guard.swift
// 日志: ~/Library/Logs/v2rayn-quitguard.log

import Cocoa
import ApplicationServices

// ---------------- 配置 ----------------
let V2RAYN_BUNDLE_ID = "2dust.v2rayN"
let HOLD_SECONDS: Double = 8.0     // 弹窗里需要按住多久才确认退出
let DIALOG_TIMEOUT: Double = 12.0  // 弹窗自动取消的时间
let KEYCODE_Q: Int64 = 12          // kVK_ANSI_Q

let home = FileManager.default.homeDirectoryForCurrentUser.path
let allowFlag = "\(home)/Library/Application Support/v2rayN/allow-quit"
let logPath = "\(home)/Library/Logs/v2rayn-quitguard.log"

// 受保护应用的 Bundle ID。
// 用 bundle id 而不是进程名 —— 更准, 也不会误命中 Chrome Helper 之类的子进程。
// 注意: 浏览器装的 App(PWA) 仍然是浏览器主进程在跑, 所以列浏览器就覆盖了。
let PROTECTED_BUNDLE_IDS: Set<String> = [
    // 终端
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
    "co.zeit.hyper", "org.tabby", "com.mitchellh.ghostty",
    // 浏览器
    "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
    "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser",
    "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    // AI 应用
    "com.openai.chat", "com.anthropic.claudefordesktop",
    "ai.perplexity.mac", "com.todesktop.230313mzl4w4u92",   // Cursor
    "com.lmstudio.app", "com.electron.ollama",
]

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// 找出正在运行的受保护应用(可读名字)
func protectedApps() -> [String] {
    var names: [String] = []
    for app in NSWorkspace.shared.runningApplications {
        guard let bid = app.bundleIdentifier, PROTECTED_BUNDLE_IDS.contains(bid) else { continue }
        if app.isTerminated { continue }
        names.append(app.localizedName ?? bid)
    }
    return Array(Set(names)).sorted()
}

func v2raynRunning() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
        $0.bundleIdentifier == V2RAYN_BUNDLE_ID && !$0.isTerminated
    }
}

// ---------------- 长按确认窗口 ----------------
final class HoldButton: NSView {
    var onProgress: ((Double) -> Void)?
    var onConfirm: (() -> Void)?
    var onRelease: (() -> Void)?
    private var timer: Timer?
    private var elapsed: Double = 0
    private var holding = false
    private let interval = 0.05
    var title: String = "按住确认" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        (holding ? NSColor.systemRed.withAlphaComponent(0.22) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (holding ? NSColor.systemRed : NSColor.separatorColor).setStroke()
        path.lineWidth = holding ? 2 : 1
        path.stroke()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: holding ? NSColor.systemRed : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let h = (title as NSString).size(withAttributes: attrs).height
        (title as NSString).draw(in: NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h),
                                 withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) {
        holding = true; elapsed = 0; needsDisplay = true; onProgress?(0)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { return }
            self.elapsed += self.interval
            let p = min(self.elapsed / HOLD_SECONDS, 1.0)
            self.onProgress?(p)
            if self.elapsed >= HOLD_SECONDS {
                t.invalidate(); self.timer = nil
                self.holding = false; self.needsDisplay = true
                self.onConfirm?()
            }
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard holding else { return }
        timer?.invalidate(); timer = nil
        holding = false; elapsed = 0; needsDisplay = true; onProgress?(0); onRelease?()
    }
}

// 显示确认窗口并阻塞等待结果。返回 true = 用户确认退出。
// 事件回调里不能直接阻塞, 所以由调用方 dispatch 到主线程串行队列上执行。
func askConfirm(apps: [String]) -> Bool {
    let W: CGFloat = 460, H: CGFloat = 250
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                       styleMask: [.titled], backing: .buffered, defer: false)
    win.title = "v2rayN 退出保护（已拦截 Cmd+Q）"
    win.level = .floating
    win.isReleasedWhenClosed = false
    let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

    func label(_ s: String, _ rect: NSRect, size: CGFloat,
               weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(frame: rect)
        t.stringValue = s; t.isEditable = false; t.isBordered = false; t.drawsBackground = false
        t.font = NSFont.systemFont(ofSize: size, weight: weight); t.textColor = color
        t.lineBreakMode = .byTruncatingTail
        return t
    }

    content.addSubview(label("v2rayN 没有退出 —— Cmd+Q 已被拦截。",
                             NSRect(x: 24, y: H - 50, width: W - 48, height: 20), size: 13, weight: .semibold))
    content.addSubview(label("以下程序仍在使用网络：",
                             NSRect(x: 24, y: H - 76, width: W - 48, height: 18), size: 12, color: .secondaryLabelColor))
    content.addSubview(label(apps.joined(separator: ", "),
                             NSRect(x: 24, y: H - 100, width: W - 48, height: 20), size: 13, weight: .semibold, color: .systemRed))
    content.addSubview(label("确需退出请长按下方按钮；松手或超时都会保持 v2rayN 运行。",
                             NSRect(x: 24, y: H - 128, width: W - 48, height: 18), size: 11, color: .secondaryLabelColor))

    let hold = HoldButton(frame: NSRect(x: 24, y: 92, width: W - 48, height: 44))
    hold.title = String(format: "按住此按钮 %.0f 秒以确认退出", HOLD_SECONDS)
    content.addSubview(hold)

    let bar = NSProgressIndicator(frame: NSRect(x: 24, y: 70, width: W - 48, height: 8))
    bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1; bar.doubleValue = 0
    content.addSubview(bar)

    let status = label("松手即取消，v2rayN 继续运行", NSRect(x: 24, y: 44, width: W - 170, height: 18),
                       size: 11, color: .secondaryLabelColor)
    content.addSubview(status)

    let cancelBtn = NSButton(frame: NSRect(x: W - 130, y: 38, width: 106, height: 30))
    cancelBtn.title = "取消"
    cancelBtn.bezelStyle = .rounded
    content.addSubview(cancelBtn)

    win.contentView = content
    win.center()

    // 用模态会话阻塞, 拿到明确的结果
    var confirmed = false
    var done = false
    func finish(_ ok: Bool) {
        if done { return }
        done = true; confirmed = ok
        NSApp.stopModal(withCode: ok ? .OK : .cancel)
        win.orderOut(nil)
    }

    // 按钮的 target/action 必须是 @objc 方法, 所以用一个持有回调的小对象来接线。
    final class CancelTarget: NSObject {
        var onCancel: (() -> Void)?
        @objc func clicked() { onCancel?() }
    }
    let cancelTarget = CancelTarget()
    cancelTarget.onCancel = { finish(false) }
    cancelBtn.target = cancelTarget
    cancelBtn.action = #selector(CancelTarget.clicked)

    hold.onProgress = { p in
        bar.doubleValue = p
        status.stringValue = p > 0
            ? String(format: "继续按住… 还需 %.1f 秒（松手即取消）", max(HOLD_SECONDS * (1 - p), 0))
            : "松手即取消，v2rayN 继续运行"
    }
    hold.onRelease = { status.stringValue = "已松手 —— v2rayN 保持运行" }
    hold.onConfirm = { finish(true) }

    // 关窗 / Cmd+W 也算取消
    final class WindowWatcher: NSObject, NSWindowDelegate {
        var onClose: (() -> Void)?
        func windowWillClose(_ notification: Notification) { onClose?() }
    }
    let watcher = WindowWatcher()
    watcher.onClose = { finish(false) }
    win.delegate = watcher

    Timer.scheduledTimer(withTimeInterval: DIALOG_TIMEOUT, repeats: false) { _ in finish(false) }

    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
    NSApp.runModal(for: win)
    win.orderOut(nil)
    _ = cancelTarget      // 保活: target 是 weak 引用, 出了作用域就没了
    _ = watcher
    return confirmed
}

// ---------------- 拦截逻辑 ----------------
//
// ⚠️ 最关键的一条约束: 事件回调必须【立刻返回】。
//    CGEventTap 的回调如果阻塞, 冻住的是整个系统的键盘输入, 不只是 v2rayN。
//    所以回调里只做两件极快的事: 判断要不要管, 然后吞掉事件。
//    弹窗和后续处理全部丢到后台队列, 结果需要"放行"时用重发事件的方式补回去。
//
// 重发事件要带标记, 否则会被自己的 tap 再拦一次, 变成死循环。

let EVENT_MARKER: Int64 = 0x51_55_47_44   // 'QUGD', 标记"这是我们重发的"

final class Guard {
    private let queue = DispatchQueue(label: "quitguard.work")
    private var busy = false

    /// 判断是否该放行(不做任何耗时操作)
    func shouldPassThrough() -> Bool {
        if FileManager.default.fileExists(atPath: allowFlag) { return true }
        return protectedApps().isEmpty
    }

    /// 异步处理被拦下的 Cmd+Q。original 用于需要放行时原样重发。
    func handle(original: CGEvent) {
        queue.async { [weak self] in
            guard let self else { return }

            if self.shouldPassThrough() {
                // 没程序在用网 -> 原样补发, 让 v2rayN 正常退出
                log("放行 Cmd+Q（无受保护进程或存在 allow-quit 开关）")
                original.setIntegerValueField(.eventSourceUserData, value: EVENT_MARKER)
                original.postToPid(pid_t(v2raynRunning()?.processIdentifier ?? 0))
                return
            }

            if self.busy {
                log("弹窗已在进行中, 忽略重复的 Cmd+Q")
                return
            }
            self.busy = true
            defer { self.busy = false }

            let apps = protectedApps()
            log("拦截 Cmd+Q: 受保护进程 [\(apps.joined(separator: ", "))]")

            var confirmed = false
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                confirmed = askConfirm(apps: apps)
                sem.signal()
            }
            sem.wait()

            if confirmed {
                log("用户长按确认 -> 主动退出 v2rayN")
                v2raynRunning()?.terminate()
            } else {
                log("用户取消 —— v2rayN 全程未退出")
            }
        }
    }
}

let guardInstance = Guard()

// 供 C 回调重新启用 tap 用
var globalTap: CFMachPort?

// ---------------- 主流程 ----------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// 请求辅助功能权限。没有它 CGEventTap 会创建失败。
// 用带 prompt 的版本, 首次运行会弹系统提示引导用户去勾选。
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
log("=== quit-guard 启动 (辅助功能权限: \(trusted ? "已授权" : "未授权, 已弹出系统提示")) ===")

let mask = (1 << CGEventType.keyDown.rawValue)
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(mask),
    callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
        // tap 被系统因超时/用户输入禁用时要重新启用, 否则保护就悄悄失效了
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = globalTap { CGEvent.tapEnable(tap: t, enable: true) }
            log("event tap 被系统禁用, 已重新启用")
            return Unmanaged.passUnretained(event)
        }

        // 我们自己重发的事件, 直接放行, 否则会无限循环
        if event.getIntegerValueField(.eventSourceUserData) == EVENT_MARKER {
            return Unmanaged.passUnretained(event)
        }

        // 条件 1: 必须是 Cmd+Q
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == KEYCODE_Q, event.flags.contains(.maskCommand) else {
            return Unmanaged.passUnretained(event)
        }

        // 条件 2: 必须 v2rayN 是前台应用。
        //        别的应用里按 Cmd+Q 完全不受本程序影响。
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == V2RAYN_BUNDLE_ID else {
            return Unmanaged.passUnretained(event)
        }

        // 到这里才需要处理。立刻吞掉并异步处理 —— 回调绝不能阻塞。
        guardInstance.handle(original: event)
        return nil
    },
    userInfo: nil
) else {
    log("❌ 无法创建 event tap —— 缺少辅助功能权限。")
    log("   请到「系统设置 → 隐私与安全性 → 辅助功能」里勾选本程序后重新启动。")
    FileHandle.standardError.write(
        "❌ 缺少辅助功能权限, 无法拦截 Cmd+Q。\n".data(using: .utf8)!)
    exit(2)
}

// 供回调里重新启用 tap 用(回调是 C 函数, 拿不到局部变量)
globalTap = tap

let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("event tap 已启用, 只在 v2rayN 为前台应用时拦截 Cmd+Q")

app.run()

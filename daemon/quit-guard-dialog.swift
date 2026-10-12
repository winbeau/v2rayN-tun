// v2rayN 退出确认对话框
//
// 为什么需要它:
//   macOS 的 Cmd+Q 是系统级退出, 第三方无法拦截。quit-guard.sh 只能事后补救,
//   但"8 秒内再按一次 Cmd+Q"这种隐式约定用户看不见, 容易困惑。
//   所以改成显式的长按确认: 看得见倒计时, 松手就取消。
//
// 交互:
//   · 按住按钮 HOLD_SECONDS 秒 -> 确认退出 (退出码 0)
//   · 中途松手 / 点"取消退出" / 超时 -> 取消 (退出码 1)
//   · 按住期间进度条与剩余秒数实时更新
//
// 编译: swiftc -O -o quit-guard-dialog quit-guard-dialog.swift
// 调用: quit-guard-dialog "<受保护程序列表>" [按住秒数] [总超时秒数]

import Cocoa

let args = CommandLine.arguments
let appsText = args.count > 1 ? args[1] : "未知程序"
let holdSeconds = args.count > 2 ? (Double(args[2]) ?? 8.0) : 8.0
let totalTimeout = args.count > 3 ? (Double(args[3]) ?? 30.0) : 30.0

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不在 Dock 显示图标

// ---------------- 长按按钮 ----------------
final class HoldButton: NSView {
    var onProgress: ((Double) -> Void)?   // 0.0 ~ 1.0
    var onConfirm: (() -> Void)?
    var onCancelHold: (() -> Void)?

    private var timer: Timer?
    private var elapsed: Double = 0
    private var holding = false
    private let interval = 0.05

    var title: String = "按住确认" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        (holding ? NSColor.systemRed.withAlphaComponent(0.22)
                 : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (holding ? NSColor.systemRed : NSColor.separatorColor).setStroke()
        path.lineWidth = holding ? 2 : 1
        path.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: holding ? NSColor.systemRed : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let h = (title as NSString).size(withAttributes: attrs).height
        (title as NSString).draw(in: NSRect(x: 0, y: (bounds.height - h) / 2,
                                            width: bounds.width, height: h),
                                 withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        holding = true
        elapsed = 0
        needsDisplay = true
        onProgress?(0)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { return }
            self.elapsed += self.interval
            let p = min(self.elapsed / holdSeconds, 1.0)
            self.onProgress?(p)
            if self.elapsed >= holdSeconds {
                t.invalidate(); self.timer = nil
                self.holding = false; self.needsDisplay = true
                self.onConfirm?()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard holding else { return }
        timer?.invalidate(); timer = nil
        holding = false
        elapsed = 0
        needsDisplay = true
        onProgress?(0)
        onCancelHold?()
    }
}

// ---------------- 窗口 ----------------
let W: CGFloat = 460, H: CGFloat = 250
let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                   styleMask: [.titled],
                   backing: .buffered, defer: false)
win.title = "v2rayN 退出保护"
win.level = .floating
win.isReleasedWhenClosed = false

let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

func label(_ s: String, _ rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
           color: NSColor = .labelColor, align: NSTextAlignment = .left) -> NSTextField {
    let t = NSTextField(frame: rect)
    t.stringValue = s
    t.isEditable = false
    t.isBordered = false
    t.drawsBackground = false
    t.font = NSFont.systemFont(ofSize: size, weight: weight)
    t.textColor = color
    t.alignment = align
    t.lineBreakMode = .byTruncatingTail
    return t
}

content.addSubview(label("检测到以下程序仍在使用网络：", NSRect(x: 24, y: H - 52, width: W - 48, height: 20), size: 13))
content.addSubview(label(appsText, NSRect(x: 24, y: H - 78, width: W - 48, height: 20), size: 13, weight: .semibold, color: .systemRed))
content.addSubview(label("退出会中断正在进行的下载和会话。", NSRect(x: 24, y: H - 108, width: W - 48, height: 20), size: 12, color: .secondaryLabelColor))

let holdTitle = String(format: "按住此按钮 %.0f 秒以确认退出", holdSeconds)
let hold = HoldButton(frame: NSRect(x: 24, y: 92, width: W - 48, height: 44))
hold.title = holdTitle
content.addSubview(hold)

let bar = NSProgressIndicator(frame: NSRect(x: 24, y: 70, width: W - 48, height: 8))
bar.style = .bar
bar.isIndeterminate = false
bar.minValue = 0
bar.maxValue = 1
bar.doubleValue = 0
content.addSubview(bar)

let status = label("松手即取消", NSRect(x: 24, y: 44, width: W - 150, height: 18), size: 11, color: .secondaryLabelColor)

let cancelBtn = NSButton(frame: NSRect(x: W - 130, y: 38, width: 106, height: 30))
cancelBtn.title = "取消退出"
cancelBtn.bezelStyle = .rounded
cancelBtn.keyEquivalent = "\u{1b}"   // Esc
content.addSubview(cancelBtn)
content.addSubview(status)

win.contentView = content
win.center()

// ---------------- 行为 ----------------
var finished = false
func finish(_ code: Int32) {
    if finished { return }
    finished = true
    exit(code)
}

hold.onProgress = { p in
    bar.doubleValue = p
    if p > 0 {
        let left = max(holdSeconds * (1 - p), 0)
        status.stringValue = String(format: "继续按住… 还需 %.1f 秒（松手即取消）", left)
    } else {
        status.stringValue = "松手即取消"
    }
}
hold.onCancelHold = { status.stringValue = "已松手，未确认（继续操作或等待自动取消）" }
hold.onConfirm = { finish(0) }        // 0 = 确认退出
cancelBtn.target = cancelBtn
cancelBtn.action = #selector(NSApplication.terminate(_:))

// 总超时: 一直没人操作就自动取消, 免得窗口赖着不走
Timer.scheduledTimer(withTimeInterval: totalTimeout, repeats: false) { _ in
    finish(1)                          // 1 = 取消
}

// Esc / Cmd+W / 关窗 都算取消
class Delegate: NSObject, NSWindowDelegate, NSApplicationDelegate {
    func windowWillClose(_ notification: Notification) { finish(1) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finish(1); return .terminateCancel
    }
}
let del = Delegate()
win.delegate = del
app.delegate = del

app.activate(ignoringOtherApps: true)
win.makeKeyAndOrderFront(nil)
app.run()

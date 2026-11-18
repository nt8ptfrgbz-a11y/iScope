// Compose introduction cards from actual iScope window captures.
// Usage: swift scripts/make_product_screenshots.swift /absolute/path/Screenshots
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Screenshots", isDirectory: true)
let input = root.appendingPathComponent("原始截图", isDirectory: true)
let output = root.appendingPathComponent("产品介绍版", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width = 3200, height = 2200
let ink = NSColor(srgbRed: 0.09, green: 0.12, blue: 0.22, alpha: 1)
let muted = NSColor(srgbRed: 0.38, green: 0.42, blue: 0.52, alpha: 1)
let accent = NSColor(srgbRed: 0.24, green: 0.36, blue: 0.98, alpha: 1)
let icon = NSImage(contentsOfFile: "build/iScope.app/Contents/Resources/AppIcon.icns")
let cards: [(String, String, String, String)] = [
    ("01-分析概览", "从 IPA 到方法，一眼看清", "集中浏览类、方法、字符串与符号，从 Mach-O 概览开始探索。", "分析概览"),
    ("02-中文智能定位", "用中文描述，找到候选方法", "复用本机 Codex CLI 生成检索计划，结合真实静态证据筛选候选。", "自然语言定位"),
    ("03-方法与静态证据", "地址、签名、引用，集中查看", "在同一个工作空间查看方法接口、匹配依据与静态调用线索。", "方法详情"),
    ("04-字符串与代码线索", "从一句文案，追到代码线索", "搜索界面文字、URL 或 API 路径，继续查看引用它们的函数。", "字符串检索"),
    ("05-创建Hook工程", "选中方法，生成 Hook 工程", "生成原生 Xcode iOS dylib 工程，直接编辑方法实现。", "Xcode Hook 工程"),
    ("06-编译与部署", "编译、注入、重签、安装", "编辑 Hooks.m，在 App 中完成构建与部署，保留日志和产物。", "构建与部署"),
    ("07-自动签名与高级配置", "签名与设备，一处配置", "自动匹配本机证书与描述文件，自定义 Bundle ID、权限和扩展处理。", "自动签名")
]

func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: CGFloat(height) - top - h, width: w, height: h)
}
func text(_ value: String, x: CGFloat, top: CGFloat, w: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, color: NSColor = ink, maxHeight: CGFloat = 160) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 7
    (value as NSString).draw(in: rect(x, top, w, maxHeight), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        .paragraphStyle: paragraph
    ])
}
func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
}
var rendered: [NSImage] = []
for (index, card) in cards.enumerated() {
    let source = input.appendingPathComponent(card.0 + ".png")
    guard let screenshot = NSImage(contentsOf: source) else { fatalError("Missing screenshot: \(source.path)") }
    let rep = bitmap(width, height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(starting: NSColor(srgbRed: 0.96, green: 0.97, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0.91, green: 0.93, blue: 0.99, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -25)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: rect(2150, -450, 1500, 1000)).addClip()
    NSGradient(starting: accent.withAlphaComponent(0.12), ending: accent.withAlphaComponent(0))!
        .draw(fromCenter: NSPoint(x: 2850, y: 2300), radius: 0,
              toCenter: NSPoint(x: 2850, y: 2300), radius: 900, options: [.drawsAfterEndingLocation])
    NSGraphicsContext.restoreGraphicsState()
    icon?.draw(in: rect(172, 78, 78, 78))
    text("iScope", x: 274, top: 87, w: 500, size: 53, weight: .semibold)
    text(String(format: "%02d", index + 1) + "  /  " + card.3, x: 2320, top: 104, w: 710,
         size: 29, weight: .medium, color: accent)
    text(card.1, x: 180, top: 192, w: 2840, size: 87, weight: .semibold)
    text(card.2, x: 184, top: 315, w: 2840, size: 35, color: muted)
    let scale = min(2840 / screenshot.size.width, 1660 / screenshot.size.height)
    let size = NSSize(width: screenshot.size.width * scale, height: screenshot.size.height * scale)
    let destination = rect((CGFloat(width) - size.width) / 2, 440 + (1660 - size.height) / 2, size.width, size.height)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 0.14, green: 0.20, blue: 0.40, alpha: 0.20)
    shadow.shadowBlurRadius = 52
    shadow.shadowOffset = NSSize(width: 0, height: -22)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: destination, xRadius: 20, yRadius: 20).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: destination, xRadius: 20, yRadius: 20).addClip()
    screenshot.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    text("原生 macOS  ·  SwiftUI", x: 184, top: 2140, w: 1000, size: 23, color: muted)
    text("真实界面截图", x: 2780, top: 2140, w: 250, size: 23, color: muted)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(card.0 + ".png"))
    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(rep)
    rendered.append(image)
    print("Saved \(card.0).png · \(width) × \(height)")
}

let sheetHeight = ((rendered.count + 1) / 2) * 660
let sheet = bitmap(1920, sheetHeight)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
NSColor(srgbRed: 0.90, green: 0.92, blue: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 1920, height: sheetHeight).fill()
for (i, image) in rendered.enumerated() {
    let x = i == rendered.count - 1 && rendered.count % 2 == 1 ? 480 : (i % 2) * 960
    image.draw(in: NSRect(x: x, y: sheetHeight - (i / 2 + 1) * 660, width: 960, height: 660))
}
NSGraphicsContext.restoreGraphicsState()
try sheet.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("00-截图总览.png"))

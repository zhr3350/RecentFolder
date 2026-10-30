import AppKit

/// 菜单栏图标。
///
/// 菜单栏只接受模板图（纯色 + alpha，系统按明暗主题自动反相），彩色图标放上去
/// 会被染成一坨。所以这里按应用图标的语义手绘一版线稿。18pt 下任何多余细节都会
/// 糊掉，只保留一个带折角的文件夹轮廓。
///
/// 用位图（1x/2x）而不是 `NSImage(size:flipped:drawingHandler:)`：前者像素已经落盘，
/// 不依赖绘制时机，图标在菜单栏里 100% 有内容。
enum MenuBarIcon {

    static let image: NSImage = make()

    private static let side: CGFloat = 18

    private static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        for scale in 1...2 {
            let pixels = Int(side) * scale
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            rep.size = NSSize(width: side, height: side)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw()
            NSGraphicsContext.restoreGraphicsState()

            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    private static func draw() {
        NSColor.black.setStroke()

        let folder = NSBezierPath()
        folder.lineWidth = 1.25
        folder.lineJoinStyle = .round
        folder.lineCapStyle = .round

        // 左下角 → 左边上升 → 折角顶边 → 斜上到后板 → 顶边 → 右边下降 → 底部圆角闭合
        folder.move(to: NSPoint(x: 2.0, y: 5.6))
        folder.line(to: NSPoint(x: 2.0, y: 11.6))
        folder.line(to: NSPoint(x: 6.3, y: 11.6))
        folder.line(to: NSPoint(x: 8.1, y: 14.6))
        folder.line(to: NSPoint(x: 16.0, y: 14.6))
        folder.line(to: NSPoint(x: 16.0, y: 5.6))
        folder.curve(
            to: NSPoint(x: 14.0, y: 3.4),
            controlPoint1: NSPoint(x: 16.0, y: 4.38),
            controlPoint2: NSPoint(x: 15.1, y: 3.4)
        )
        folder.line(to: NSPoint(x: 4.0, y: 3.4))
        folder.curve(
            to: NSPoint(x: 2.0, y: 5.6),
            controlPoint1: NSPoint(x: 2.9, y: 3.4),
            controlPoint2: NSPoint(x: 2.0, y: 4.38)
        )
        folder.close()
        folder.stroke()
    }
}

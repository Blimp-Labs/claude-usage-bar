import AppKit

private let labelWidth: CGFloat = 14
private let barWidth: CGFloat = 24
private let barHeight: CGFloat = 5
private let rowGap: CGFloat = 3
private let labelGap: CGFloat = 2
private let cornerRadius: CGFloat = 2
private let logoSize: CGFloat = 12
private let logoGap: CGFloat = 2
private let barsWidth: CGFloat = labelWidth + labelGap + barWidth + 2
private let iconWidth: CGFloat = logoSize + logoGap + barsWidth
private let iconHeight: CGFloat = 18
private let fontSize: CGFloat = 8

// Layout for percentage text mode
private let pctFontSize: CGFloat = 9
private let pctRowGap: CGFloat = 1
private let pctLabelGap: CGFloat = 1
private let pctIconLogoGap: CGFloat = 3

private struct CachedLabel {
    let string: NSAttributedString
    let size: NSSize
}

private let cachedLabels: [String: CachedLabel] = {
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    var result = [String: CachedLabel]()
    for label in ["5h", "7d"] {
        let str = NSAttributedString(string: label, attributes: attrs)
        result[label] = CachedLabel(string: str, size: str.size())
    }
    return result
}()

private func drawRow(label: String, barX: CGFloat, barY: CGFloat, labelX: CGFloat, drawBarFill: (CGFloat, CGFloat) -> Void) {
    if let cached = cachedLabels[label] {
        let labelY = barY + (barHeight - cached.size.height) / 2
        cached.string.draw(at: NSPoint(x: labelX + labelWidth - cached.size.width, y: labelY))
    }
    drawBarFill(barX, barY)
}

func renderIcon(pct5h: Double, pct7d: Double) -> NSImage {
    // Render percentage text alongside the Claude logo
    let font = NSFont.monospacedSystemFont(ofSize: pctFontSize, weight: .semibold)
    let labelFont = NSFont.monospacedSystemFont(ofSize: 7, weight: .regular)

    let pct5hInt = Int(round(min(max(pct5h, 0), 1) * 100))
    let pct7dInt = Int(round(min(max(pct7d, 0), 1) * 100))

    let attrs5h: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let attrs7d: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black.withAlphaComponent(0.6)]

    let str5h = NSAttributedString(string: "\(pct5hInt)%", attributes: attrs5h)
    let str7d = NSAttributedString(string: "\(pct7dInt)%", attributes: attrs7d)
    let lbl5h = NSAttributedString(string: "5h", attributes: labelAttrs)
    let lbl7d = NSAttributedString(string: "7d", attributes: labelAttrs)

    let size5h = str5h.size()
    let size7d = str7d.size()
    let lblSize5h = lbl5h.size()
    let lblSize7d = lbl7d.size()

    // Each row: "5h " + "XX%"
    let row1Width = lblSize5h.width + pctLabelGap + size5h.width
    let row2Width = lblSize7d.width + pctLabelGap + size7d.width
    let textWidth = max(row1Width, row2Width)
    let totalWidth = logoSize + pctIconLogoGap + textWidth + 2

    let image = NSImage(size: NSSize(width: totalWidth, height: iconHeight), flipped: true) { _ in
        drawClaudeLogo(x: 0, y: (iconHeight - logoSize) / 2, size: logoSize)

        let textX = logoSize + pctIconLogoGap
        let rowHeight = max(size5h.height, lblSize5h.height)
        let totalTextHeight = rowHeight * 2 + pctRowGap
        let topY = (iconHeight - totalTextHeight) / 2
        let bottomY = topY + rowHeight + pctRowGap

        // Row 1: "5h XX%"
        lbl5h.draw(at: NSPoint(x: textX, y: topY + (rowHeight - lblSize5h.height) / 2))
        str5h.draw(at: NSPoint(x: textX + lblSize5h.width + pctLabelGap, y: topY + (rowHeight - size5h.height) / 2))

        // Row 2: "7d XX%"
        lbl7d.draw(at: NSPoint(x: textX, y: bottomY + (rowHeight - lblSize7d.height) / 2))
        str7d.draw(at: NSPoint(x: textX + lblSize7d.width + pctLabelGap, y: bottomY + (rowHeight - size7d.height) / 2))

        return true
    }
    image.isTemplate = true
    return image
}

func renderUnauthenticatedIcon() -> NSImage {
    let font = NSFont.monospacedSystemFont(ofSize: pctFontSize, weight: .semibold)
    let labelFont = NSFont.monospacedSystemFont(ofSize: 7, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.4)]
    let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black.withAlphaComponent(0.3)]

    let strDash = NSAttributedString(string: "--%", attributes: attrs)
    let lbl5h = NSAttributedString(string: "5h", attributes: labelAttrs)
    let lbl7d = NSAttributedString(string: "7d", attributes: labelAttrs)

    let sizeDash = strDash.size()
    let lblSize = lbl5h.size()
    let textWidth = lblSize.width + pctLabelGap + sizeDash.width
    let totalWidth = logoSize + pctIconLogoGap + textWidth + 2

    let image = NSImage(size: NSSize(width: totalWidth, height: iconHeight), flipped: true) { _ in
        drawClaudeLogo(x: 0, y: (iconHeight - logoSize) / 2, size: logoSize)

        let textX = logoSize + pctIconLogoGap
        let rowHeight = max(sizeDash.height, lblSize.height)
        let totalTextHeight = rowHeight * 2 + pctRowGap
        let topY = (iconHeight - totalTextHeight) / 2
        let bottomY = topY + rowHeight + pctRowGap

        lbl5h.draw(at: NSPoint(x: textX, y: topY + (rowHeight - lblSize.height) / 2))
        strDash.draw(at: NSPoint(x: textX + lblSize.width + pctLabelGap, y: topY + (rowHeight - sizeDash.height) / 2))

        lbl7d.draw(at: NSPoint(x: textX, y: bottomY + (rowHeight - lblSize.height) / 2))
        strDash.draw(at: NSPoint(x: textX + lblSize.width + pctLabelGap, y: bottomY + (rowHeight - sizeDash.height) / 2))

        return true
    }
    image.isTemplate = true
    return image
}

// MARK: - Bar drawing

private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, cornerRadius: CGFloat, pct: Double) {
    let bgRect = NSRect(x: x, y: y, width: width, height: height)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.withAlphaComponent(0.25).setFill()
    bgPath.fill()

    let clampedPct = max(0, min(1, pct))
    if clampedPct > 0 {
        let fillWidth = width * clampedPct
        let fillRect = NSRect(x: x, y: y, width: fillWidth, height: height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.black.setFill()
        fillPath.fill()
    }
}

private func drawDashedBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, cornerRadius: CGFloat) {
    let rect = NSRect(x: x, y: y, width: width, height: height)
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.withAlphaComponent(0.25).setStroke()
    path.lineWidth = 1
    let dashPattern: [CGFloat] = [2, 2]
    path.setLineDash(dashPattern, count: 2, phase: 0)
    path.stroke()
}

// MARK: - Claude logo (pre-rendered 512px template PNG)

private let claudeLogoImage: NSImage? = {
    if let bundle = claudeUsageBarResourceBundle(),
       let png = bundle.url(forResource: "claude-logo", withExtension: "png") {
        return NSImage(contentsOf: png)
    }
    return nil
}()

private func drawClaudeLogo(x: CGFloat, y: CGFloat, size: CGFloat) {
    guard let logo = claudeLogoImage else { return }
    logo.draw(in: NSRect(x: x, y: y, width: size, height: size))
}

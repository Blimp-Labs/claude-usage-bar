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

struct MenuBarIconParams {
    let pct5h: Double
    let pct7d: Double
    let resetPos5h: Double?
    let state5h: ResetIndicatorState
    let resetPos7d: Double?
    let state7d: ResetIndicatorState
    let showResetDivider: Bool
    let coloredResetDivider: Bool
    /// Optional Claude-service-status tint. `nil` = no tint; logo renders as template.
    /// When set, the Claude logo is tinted with `statusOverlay.color` to signal severity.
    let statusOverlay: ServiceStatusOverlay?

    init(
        pct5h: Double,
        pct7d: Double,
        resetPos5h: Double?,
        state5h: ResetIndicatorState,
        resetPos7d: Double?,
        state7d: ResetIndicatorState,
        showResetDivider: Bool,
        coloredResetDivider: Bool,
        statusOverlay: ServiceStatusOverlay? = nil
    ) {
        self.pct5h = pct5h
        self.pct7d = pct7d
        self.resetPos5h = resetPos5h
        self.state5h = state5h
        self.resetPos7d = resetPos7d
        self.state7d = state7d
        self.showResetDivider = showResetDivider
        self.coloredResetDivider = coloredResetDivider
        self.statusOverlay = statusOverlay
    }
}

/// Drives the tint applied to the Claude logo when a service incident is active.
/// When present, the logo is rendered in non-template mode using `color` via `.sourceIn` compositing.
/// `nil` = no tint; logo renders as a standard template image (system accent / dark-mode auto-invert).
struct ServiceStatusOverlay: Equatable {
    let color: NSColor

    init(color: NSColor) {
        self.color = color
    }
}

private func drawLabel(_ label: String, x: CGFloat, barY: CGFloat, color: NSColor) {
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: label, attributes: attrs)
    let size = str.size()
    let labelY = barY + (barHeight - size.height) / 2
    str.draw(at: NSPoint(x: x + labelWidth - size.width, y: labelY))
}

func renderIcon(_ params: MenuBarIconParams) -> NSImage {
    // Determine rendering mode: template (system accent color) or colored (semantic colors for warning/critical).
    // Template mode (.isTemplate = true) is the default: the icon uses the system accent color and auto-inverts
    // in dark mode. If the accent color is dark (unlikely but possible), we flip to white for contrast.
    // Colored mode (.isTemplate = false) uses semantic colors (orange, red) for warning/critical states,
    // overriding system colors for deliberate visual emphasis. Only applies when divider is shown AND colored is enabled.
    let wantsColored = (params.showResetDivider && params.coloredResetDivider) || params.statusOverlay != nil
    let baseColor: NSColor = wantsColored ? .labelColor : .white

    let image = NSImage(size: NSSize(width: iconWidth, height: iconHeight), flipped: true) { _ in
        let offset = logoSize + logoGap
        let barX = offset + labelWidth + labelGap
        let topY = (iconHeight - barHeight * 2 - rowGap) / 2
        let bottomY = topY + barHeight + rowGap

        let logoTint: NSColor? = params.statusOverlay?.color ?? (wantsColored ? baseColor : nil)
        drawClaudeLogo(x: .zero, y: (iconHeight - logoSize) / 2, size: logoSize, tint: logoTint)

        drawLabel("5h", x: offset, barY: topY, color: baseColor)
        drawBar(x: barX, y: topY, width: barWidth, height: barHeight,
                cornerRadius: cornerRadius, pct: params.pct5h, color: baseColor)
        if params.showResetDivider, let pos = params.resetPos5h {
            drawDivider(barX: barX, barY: topY,
                        position: pos,
                        color: params.state5h.nsColor(colored: params.coloredResetDivider).withAlphaComponent(0.6))
        }

        drawLabel("7d", x: offset, barY: bottomY, color: baseColor)
        drawBar(x: barX, y: bottomY, width: barWidth, height: barHeight,
                cornerRadius: cornerRadius, pct: params.pct7d, color: baseColor)
        if params.showResetDivider, let pos = params.resetPos7d {
            drawDivider(barX: barX, barY: bottomY,
                        position: pos,
                        color: params.state7d.nsColor(colored: params.coloredResetDivider).withAlphaComponent(0.6))
        }

        return true
    }
    // Force non-template when a status tint is present so .systemOrange / .systemRed survive.
    image.isTemplate = !wantsColored
    return image
}

func renderIcon(pct5h: Double, pct7d: Double) -> NSImage {
    renderIcon(MenuBarIconParams(
        pct5h: pct5h, pct7d: pct7d,
        resetPos5h: nil, state5h: .normal,
        resetPos7d: nil, state7d: .normal,
        showResetDivider: false,
        coloredResetDivider: false
    ))
}

func renderUnauthenticatedIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: iconWidth, height: iconHeight), flipped: true) { _ in
        let offset = logoSize + logoGap
        let barX = offset + labelWidth + labelGap
        let topY = (iconHeight - barHeight * 2 - rowGap) / 2
        let bottomY = topY + barHeight + rowGap

        drawClaudeLogo(x: 0, y: (iconHeight - logoSize) / 2, size: logoSize, tint: nil)

        drawLabel("5h", x: offset, barY: topY, color: .black)
        drawDashedBar(x: barX, y: topY, width: barWidth, height: barHeight, cornerRadius: cornerRadius)
        drawLabel("7d", x: offset, barY: bottomY, color: .black)
        drawDashedBar(x: barX, y: bottomY, width: barWidth, height: barHeight, cornerRadius: cornerRadius)
        return true
    }
    image.isTemplate = true
    return image
}

// MARK: - Bar drawing

private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, cornerRadius: CGFloat, pct: Double, color: NSColor) {
    let bgRect = NSRect(x: x, y: y, width: width, height: height)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
    color.withAlphaComponent(0.25).setFill()
    bgPath.fill()

    let clampedPct = max(0, min(1, pct))
    if clampedPct > 0 {
        let fillWidth = width * clampedPct
        let fillRect = NSRect(x: x, y: y, width: fillWidth, height: height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius)
        color.setFill()
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

// Draws the reset-time divider: a 1-point vertical line at the given position within the bar.
// Extends 1 point above and below the bar (height: barHeight + 2) for visual centering and prominence,
// even though the bar itself is only 5 points tall. This slight extension makes the divider more visible
// in the compact 18x18 menubar icon.
private func drawDivider(barX: CGFloat, barY: CGFloat, position: Double, color: NSColor) {
    let clamped = max(0.0, min(1.0, position))
    let lineWidth: CGFloat = 1
    let x = barX + (barWidth * CGFloat(clamped)) - (lineWidth / 2)
    let rect = NSRect(x: x, y: barY - 1, width: lineWidth, height: barHeight + 2)
    color.setFill()
    rect.fill()
}

// MARK: - Claude logo (pre-rendered 512px template PNG)

private let claudeLogoImage: NSImage? = {
    if let bundle = claudeUsageBarResourceBundle(),
       let png = bundle.url(forResource: "claude-logo", withExtension: "png") {
        return NSImage(contentsOf: png)
    }
    return nil
}()

private func drawClaudeLogo(x: CGFloat, y: CGFloat, size: CGFloat, tint: NSColor?) {
    guard let logo = claudeLogoImage else { return }
    let rect = NSRect(x: x, y: y, width: size, height: size)
    guard let tint else {
        logo.draw(in: rect)
        return
    }
    NSGraphicsContext.saveGraphicsState()
    logo.draw(in: rect)
    tint.set()
    rect.fill(using: .sourceIn)
    NSGraphicsContext.restoreGraphicsState()
}

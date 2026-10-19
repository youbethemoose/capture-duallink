import AppKit

/// A child overlay, never a layout inset or a separate display surface.
final class ViewerControls: NSVisualEffectView {
    var onCommand: ((ViewerCommand) -> Void)?
    private var buttons: [ViewerCommand: NSButton] = [:]

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        setAccessibilityLabel("Floating Viewer Controls")
        setAccessibilityRole(.group)

        let specifications: [(ViewerCommand, String, String, String?, CGFloat)] = [
            (.grid, "", "Rule of Thirds Grid", "grid", 44),
            (.zoomOut, "", "Zoom Out", "minus", 44),
            (.fit, "Fit", "Fit Image", nil, 64),
            (.zoomIn, "", "Zoom In", "plus", 44),
            (.quickControls, "", "Hide Floating Controls", "chevron.down", 32)
        ]
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for (command, title, label, symbol, width) in specifications {
            let button = NSButton(title: title, target: self, action: #selector(clicked(_:)))
            button.tag = command.rawValue
            button.bezelStyle = .recessed
            button.controlSize = .large
            button.font = .systemFont(ofSize: 13, weight: .semibold)
            button.contentTintColor = .white
            button.setAccessibilityLabel(label)
            button.toolTip = label
            if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) }
            if command == .grid { button.setButtonType(.toggle) }
            let preferred = button.widthAnchor.constraint(equalToConstant: width)
            preferred.priority = .defaultHigh
            NSLayoutConstraint.activate([
                preferred,
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 44)
            ])
            stack.addArrangedSubview(button)
            buttons[command] = button
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func button(for command: ViewerCommand) -> NSButton? { buttons[command] }

    func update(options: MirrorOptions, hasImage: Bool) {
        buttons[.grid]?.state = options.showGrid ? .on : .off
        buttons[.grid]?.contentTintColor = options.showGrid ? .systemTeal : .white
        buttons[.zoomOut]?.isEnabled = hasImage && options.viewport.zoom > 1
        buttons[.zoomIn]?.isEnabled = hasImage && options.viewport.zoom < 8
        buttons[.fit]?.isEnabled = hasImage
        let zoom = Double(options.viewport.zoom).formatted(.number.precision(.fractionLength(0...2)))
        buttons[.fit]?.title = options.viewport.zoom > 1 ? "\(zoom)×" : "Fit"
        buttons[.fit]?.toolTip = "Fit image and reset zoom / pan"
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let command = ViewerCommand(rawValue: sender.tag) else { return }
        onCommand?(command)
    }
}

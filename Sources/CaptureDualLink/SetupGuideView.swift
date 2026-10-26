import AppKit
import SwiftUI

struct SetupGuideView: View {
    @ObservedObject var model: AppModel
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .center, spacing: 28) {
                    HStack(spacing: 10) {
                        Image(nsImage: MenuBarIcon.image).resizable().scaledToFit().frame(width: 26, height: 22)
                        Text("CAPTURE DUALLINK").font(.system(size: 11, weight: .semibold)).tracking(2.5)
                    }
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) { Rectangle().fill(DualLinkStyle.coral).frame(width: 18, height: 18) }
                    .overlay(alignment: .trailing) { Circle().fill(DualLinkStyle.yellow).frame(width: 18, height: 18) }
                    VStack(alignment: .center, spacing: 14) {
                        Text("Two views.\nOne composition.")
                            .font(.system(size: 42, weight: .regular)).lineSpacing(-2)
                        Text("Control Capture One on your laptop. Let the prop stylist see the same live view on the iPad.")
                            .font(.system(size: 15)).foregroundStyle(DualLinkStyle.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 22) {
                        role("Photographer", subtitle: "Original Capture One Live View", caption: "Focus · grid · reference overlay")
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.right").font(.system(size: 20, weight: .light))
                            Text("SAME\nLIVE FRAME").font(.system(size: 8, weight: .medium)).tracking(1.2).multilineTextAlignment(.center)
                        }.padding(.top, 115)
                        role("Prop stylist", subtitle: "DualLink copy on iPad", caption: "Move the product. See the change.")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("The photographer keeps the original Capture One Live View on the laptop, controlling focus, grids and overlays. The prop stylist watches a copy of the same frame on an iPad while moving the still-life product.")
                    Text("Capture One stays on the laptop. The copy goes on the iPad.")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).padding(16)
                        .background(DualLinkStyle.yellow)
                    HStack(alignment: .top, spacing: 20) {
                        step("01", title: "Connect the iPad", text: "Connect with Sidecar using the same Apple Account. Choose an extended display.") {
                            Button("Open Displays…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        step("02", title: "Allow window capture", text: "Allow DualLink in Screen Recording settings. Reopen if asked.") {
                            if model.hasPermission {
                                Label("Capture allowed", systemImage: "checkmark.circle.fill").font(.system(size: 11))
                            } else {
                                Button("Allow Window Capture…") { model.requestPermission() }
                            }
                        }
                        step("03", title: "Send the live view", text: "Open Capture One → Window → Live View. Duplicate it in DualLink, then move the copy to the iPad.") {
                            Text("Start with Native / Retina · 30 fps").font(.system(size: 10))
                        }
                    }
                    VStack(alignment: .center, spacing: 18) {
                        Text("Style. Adjust. Shoot.").font(.system(size: 23, weight: .regular))
                        HStack(alignment: .top, spacing: 24) {
                            note("Direct & focus", "Adjust focus in Capture One and direct the product placement. Camera and lens support is required.")
                            note("Share your guides", "Use Capture One’s grid or overlay for both views. DualLink’s Grid changes only the iPad copy.")
                            note("Style & refine", "Watch the iPad while moving the product. Double-click to fill the display. Right-click for Trim and Fit.")
                        }
                    }
                    .padding(22).background(DualLinkStyle.paper)
                    HStack(alignment: .top) {
                        Text("Sidecar supports one iPad. Use Apple Pencil or your Mac’s mouse if touch controls aren’t available.")
                            .font(.system(size: 11)).foregroundStyle(DualLinkStyle.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("Sidecar help ↗", destination: URL(string: "https://support.apple.com/en-us/102597")!)
                            .font(.system(size: 11))
                    }
                }.padding(32)
            }
            VStack(spacing: 10) {
                Button("Choose Live View", action: onContinue)
                    .buttonStyle(.borderedProminent).tint(DualLinkStyle.ink)
                    .keyboardShortcut(.defaultAction)
                Text("Find this guide anytime under the shutter icon → Setup Guide.")
                    .font(.system(size: 11)).foregroundStyle(DualLinkStyle.mutedInk)
            }.frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.vertical, 18).background(DualLinkStyle.paper)
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(DualLinkStyle.sky).foregroundStyle(DualLinkStyle.ink)
        .multilineTextAlignment(.center)
        .tint(DualLinkStyle.ink).preferredColorScheme(.light)
    }

    private func role(_ title: String, subtitle: String, caption: String) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Text(title).font(.system(size: 20, weight: .regular))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(DualLinkStyle.mutedInk)
            ShapeStillLife().padding(.vertical, 6)
            Text(caption).font(.system(size: 11, weight: .medium))
        }.frame(maxWidth: .infinity)
    }

    private func step<Content: View>(_ number: String, title: String, text: String,
                                     @ViewBuilder action: () -> Content) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Text(number).font(.system(size: 23, weight: .light))
            Text(title).font(.system(size: 14, weight: .medium))
            Text(text).font(.system(size: 12)).foregroundStyle(DualLinkStyle.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            action().controlSize(.small)
        }.frame(maxWidth: .infinity, alignment: .top)
    }

    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(text).font(.system(size: 11)).foregroundStyle(DualLinkStyle.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct ShapeStillLife: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                DualLinkStyle.sky
                Rectangle().fill(DualLinkStyle.coral)
                    .frame(width: w * 0.29, height: w * 0.29).position(x: w * 0.25, y: h * 0.47)
                Circle().fill(DualLinkStyle.yellow)
                    .frame(width: w * 0.40, height: w * 0.40).position(x: w * 0.68, y: h * 0.37)
                Path { path in
                    path.move(to: CGPoint(x: w * 0.37, y: h * 0.85))
                    path.addLine(to: CGPoint(x: w * 0.53, y: h * 0.52))
                    path.addLine(to: CGPoint(x: w * 0.69, y: h * 0.85))
                    path.closeSubpath()
                }.fill(DualLinkStyle.green)
                Rectangle().fill(DualLinkStyle.lilac).frame(width: w * 0.26, height: h * 0.025)
                    .rotationEffect(.degrees(-28)).position(x: w * 0.17, y: h * 0.15)
                Path { path in
                    for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                        path.move(to: CGPoint(x: w * fraction, y: 0)); path.addLine(to: CGPoint(x: w * fraction, y: h))
                        path.move(to: CGPoint(x: 0, y: h * fraction)); path.addLine(to: CGPoint(x: w, y: h * fraction))
                    }
                }.stroke(DualLinkStyle.ink.opacity(0.22), style: StrokeStyle(lineWidth: 0.6, dash: [3, 4]))
            }.clipped()
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

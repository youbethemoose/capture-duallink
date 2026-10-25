import AppKit
import SwiftUI

struct SetupGuideView: View {
    @ObservedObject var model: AppModel
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(nsImage: MenuBarIcon.image)
                            .resizable().scaledToFit().frame(width: 34, height: 28)
                            .foregroundStyle(.mint)
                            .frame(width: 54, height: 54)
                            .background(.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CAPTURE DUALLINK").font(.system(size: 11, weight: .semibold)).tracking(2)
                                .foregroundStyle(.mint)
                            Text("One live view. More eyes on set.").font(.system(size: 28, weight: .semibold))
                        }
                    }
                    Text("Keep shooting in Capture One. Give your team a clean, independent view on an iPad or another display.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SetupDiagram()

                    HStack(alignment: .top, spacing: 12) {
                        step(1, title: "Extend your workspace", text: "For an iPad, use Sidecar with the same Apple Account. Or connect a monitor. In Displays, choose an extended display.") {
                            Button("Open Displays…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        step(2, title: "Allow window capture", text: "Enable Capture DualLink in Screen Recording settings. Quit and reopen if macOS asks.") {
                            if model.hasPermission {
                                Label("Capture allowed", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.mint)
                            } else {
                                Button("Allow Window Capture…") { model.requestPermission() }
                            }
                        }
                        step(3, title: "Choose Live View", text: "In Capture One, open Window → Live View. Select that window in DualLink, then click Duplicate Window.") {
                            Label("Native / Retina · 30 fps", systemImage: "sparkles")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("THEN MAKE THE VIEW YOURS").font(.system(size: 10, weight: .semibold)).tracking(1.6)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 24) {
                            tip("arrow.up.left.and.arrow.down.right", "Move & fill", "Drag a copy to the other display. Double-click it to fill that display; double-click again to return.")
                            tip("grid", "Frame the shot", "Click or hover for Fit / Fill and Grid. Right-click to trim Capture One’s toolbar or create another copy.")
                            tip("cursorarrow", "Keep shooting", "Copies keep Capture One’s keyboard focus. Their grid and viewing settings change only that copy.")
                        }
                    }
                    .padding(18)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.mint)
                        Text("Sidecar connects one iPad. Extra monitors use your Mac’s supported display connections. On older Sidecar versions, use Apple Pencil or your Mac’s mouse for viewer controls.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("Sidecar help ↗", destination: URL(string: "https://support.apple.com/en-us/102597")!)
                            .font(.system(size: 11))
                    }
                }
                .padding(26)
            }
            Divider()
            HStack {
                Text("Reopen this guide from the shutter icon → Setup Guide.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Choose a Window", action: onContinue)
                    .buttonStyle(.borderedProminent).tint(.mint)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26).padding(.vertical, 18)
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private func step<Content: View>(_ number: Int, title: String, text: String,
                                     @ViewBuilder action: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(number)).font(.system(size: 12, weight: .bold)).foregroundStyle(.mint)
                .frame(width: 26, height: 26)
                .background(.mint.opacity(0.13), in: Circle())
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            action().controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct SetupDiagram: View {
    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill").font(.system(size: 22))
                    Image(systemName: "cable.connector").font(.system(size: 14)).foregroundStyle(.secondary)
                    Text("Your shooting Mac").font(.system(size: 11, weight: .medium))
                }
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.3)).frame(width: 4, height: 4) }
                        Spacer()
                        Text("CAPTURE ONE · LIVE VIEW").font(.system(size: 7, weight: .semibold)).tracking(0.8)
                        Spacer()
                    }
                    .padding(8).background(.white.opacity(0.10))
                    HStack(spacing: 7) {
                        VStack(spacing: 6) {
                            ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.15)).frame(width: 22, height: 5) }
                            Spacer()
                        }.padding(.top, 10)
                        SetupPhoto().frame(width: 84, height: 104)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                }
                .frame(width: 190)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.16)))
                Text("Camera & controls stay here").font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Image(systemName: "arrow.right").foregroundStyle(.mint.opacity(0.7))
            VStack(spacing: 10) {
                Image(nsImage: MenuBarIcon.image).resizable().scaledToFit()
                    .frame(width: 40, height: 33).foregroundStyle(.mint)
                    .frame(width: 68, height: 68)
                    .background(.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.mint.opacity(0.25)))
                Text("DUALLINK").font(.system(size: 9, weight: .semibold)).tracking(1.6)
                Text("One shared stream").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Image(systemName: "arrow.right").foregroundStyle(.mint.opacity(0.7))

            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 9) {
                    SetupPhoto().frame(width: 104, height: 81).padding(6)
                        .background(.black, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.3)))
                        .overlay(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.25))
                                .frame(width: 28, height: 3).offset(y: 6)
                        }
                    Text("Mac / monitor").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                VStack(spacing: 9) {
                    SetupPhoto().frame(width: 76, height: 102).padding(6)
                        .background(.black, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.3)))
                    Text("iPad via Sidecar").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20).padding(.horizontal, 16)
        .background(LinearGradient(colors: [.mint.opacity(0.055), .black.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("One camera feeds Capture One on your shooting Mac. DualLink copies that Live View to independently sized viewers on your Mac, an external monitor, or an iPad connected through Sidecar.")
    }
}

private struct SetupPhoto: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.16, green: 0.27, blue: 0.26)
                LinearGradient(colors: [.mint.opacity(0.3), .clear, .black.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Color(red: 0.88, green: 0.66, blue: 0.48))
                    .frame(width: geometry.size.width * 0.25, height: geometry.size.width * 0.25)
                    .offset(y: -geometry.size.height * 0.16)
                RoundedRectangle(cornerRadius: geometry.size.width * 0.24)
                    .fill(Color(red: 0.70, green: 0.83, blue: 0.66))
                    .frame(width: geometry.size.width * 0.54, height: geometry.size.height * 0.58)
                    .offset(y: geometry.size.height * 0.29)
                RoundedRectangle(cornerRadius: 1).strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                    .padding(geometry.size.width * 0.09)
            }
            .clipped()
        }
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        .accessibilityHidden(true)
    }
}

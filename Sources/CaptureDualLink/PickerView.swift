import SwiftUI
import AppKit

struct PickerView: View {
    @ObservedObject var model: AppModel
    var onShowGuide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: MenuBarIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 25)
                    .foregroundStyle(DualLinkStyle.ink)
                    .frame(width: 48, height: 48)
                    .background(DualLinkStyle.paper.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                VStack(spacing: 4) {
                    Text("Capture DualLink").font(.system(size: 20, weight: .semibold))
                    Text("Live view for you and your prop stylist.")
                        .font(.system(size: 12)).foregroundStyle(DualLinkStyle.mutedInk)
                }
                if model.mirrorCount > 0 {
                    Text("\(model.mirrorCount) active")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(DualLinkStyle.ink)
                }
            }
            .frame(maxWidth: .infinity).padding(22)

            Divider()
            if model.hasPermission {
                sourcePicker
            } else {
                permissionView
            }
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Capture detail").foregroundStyle(DualLinkStyle.mutedInk)
                    Spacer()
                    Picker("Capture detail", selection: $model.detail) {
                        ForEach(CaptureDetail.allCases) { detail in Text(detail.rawValue).tag(detail) }
                    }
                    .labelsHidden().frame(width: 230)
                    .onChange(of: model.detail) { _, _ in model.applyCaptureSettings() }
                }
                HStack {
                    Text("Frame rate").foregroundStyle(DualLinkStyle.mutedInk)
                    Spacer()
                    Picker("Frame rate", selection: $model.fps) {
                        Text("15 fps").tag(15); Text("30 fps").tag(30); Text("60 fps").tag(60)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 230)
                    .onChange(of: model.fps) { _, _ in model.applyCaptureSettings() }
                }
                Text("Native keeps the source’s available pixels. Each copy fits its own display.")
                    .font(.system(size: 11)).foregroundStyle(DualLinkStyle.mutedInk).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .font(.system(size: 12)).padding(20)

            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Color(red: 0.55, green: 0.14, blue: 0.14))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 14)
            }

            VStack(spacing: 10) {
                Button(model.creating ? "Connecting…" : "Duplicate Window") {
                    Task { await model.duplicateSelected() }
                }
                .buttonStyle(.borderedProminent).tint(DualLinkStyle.ink)
                .disabled(!model.hasPermission || model.selectedID == nil || model.creating)
                .keyboardShortcut(.return, modifiers: [])
                Button("Setup Guide", action: onShowGuide)
                    .buttonStyle(.plain).foregroundStyle(DualLinkStyle.mutedInk)
            }
            .frame(maxWidth: .infinity)
            .font(.system(size: 12)).padding(.horizontal, 20).padding(.bottom, 20)
        }
        .frame(width: 470)
        .background(DualLinkStyle.sky)
        .foregroundStyle(DualLinkStyle.ink).tint(DualLinkStyle.ink)
        .preferredColorScheme(.light)
        .task { if model.hasPermission { await model.refreshSources() } }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SOURCE WINDOW").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(DualLinkStyle.mutedInk)
                Spacer()
                Button { Task { await model.refreshSources() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).font(.system(size: 11))
                .disabled(model.loading)
            }
            TextField("Search apps or window names", text: $model.search)
                .textFieldStyle(.roundedBorder)
            if model.loading && model.sources.isEmpty {
                ProgressView().frame(maxWidth: .infinity).frame(height: 205)
            } else if model.filteredSources.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow").font(.system(size: 26)).foregroundStyle(DualLinkStyle.mutedInk)
                    Text("No matching windows").font(.headline)
                    Text("Open Live View in Capture One, then refresh.")
                        .font(.system(size: 12)).foregroundStyle(DualLinkStyle.mutedInk)
                }
                .frame(maxWidth: .infinity).frame(height: 205)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.filteredSources) { source in
                            Button {
                                model.selectedID = source.id
                            } label: {
                                HStack(spacing: 10) {
                                    Image(nsImage: appIcon(source))
                                        .resizable().frame(width: 28, height: 28)
                                    VStack(spacing: 4) {
                                        Text(source.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(source.app).font(.system(size: 10)).foregroundStyle(DualLinkStyle.mutedInk)
                                    }
                                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DualLinkStyle.ink)
                                        .frame(width: 28).opacity(model.selectedID == source.id ? 1 : 0)
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedID == source.id ? DualLinkStyle.paper : DualLinkStyle.paper.opacity(0.5),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(source.label)\(model.selectedID == source.id ? ", selected" : "")")
                        }
                    }
                }
                .frame(height: 205)
            }
            Text("Keep Capture One on the laptop. Drag the copy to the stylist’s iPad.")
                .font(.system(size: 11)).foregroundStyle(DualLinkStyle.mutedInk)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var permissionView: some View {
        VStack(alignment: .center, spacing: 14) {
            Label("Allow window capture", systemImage: "macwindow.on.rectangle")
                .font(.system(size: 16, weight: .semibold))
            Text("macOS needs Screen Recording permission to copy another app's window. Choose Capture DualLink in System Settings when prompted.")
                .font(.system(size: 12)).foregroundStyle(DualLinkStyle.mutedInk)
                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
            HStack {
                Button("Allow Window Capture") { model.requestPermission() }
                    .buttonStyle(.borderedProminent).tint(DualLinkStyle.ink)
                Button("Refresh") { Task { await model.refreshSources() } }
            }
        }
        .padding(22)
    }

    private func appIcon(_ source: WindowSource) -> NSImage {
        if let pid = source.window.owningApplication?.processID,
           let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage()
    }
}

import SwiftUI
import AppKit

struct PickerView: View {
    @ObservedObject var model: AppModel
    var onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: MenuBarIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 25)
                    .foregroundStyle(.mint)
                    .frame(width: 48, height: 48)
                    .background(.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Capture DualLink").font(.system(size: 20, weight: .semibold))
                    Text("One window. More places to see it.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.mirrorCount > 0 {
                    Text("\(model.mirrorCount) active")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.mint)
                }
            }
            .padding(22)

            Divider()
            if model.hasPermission {
                sourcePicker
            } else {
                permissionView
            }
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Capture detail").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Capture detail", selection: $model.detail) {
                        ForEach(CaptureDetail.allCases) { detail in Text(detail.rawValue).tag(detail) }
                    }
                    .labelsHidden().frame(width: 230)
                    .onChange(of: model.detail) { _, _ in model.applyCaptureSettings() }
                }
                HStack {
                    Text("Frame rate").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Frame rate", selection: $model.fps) {
                        Text("15 fps").tag(15); Text("30 fps").tag(30); Text("60 fps").tag(60)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 230)
                    .onChange(of: model.fps) { _, _ in model.applyCaptureSettings() }
                }
                Text("Each copy adapts to its display. Native keeps the source's available pixels; it cannot add camera detail.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12)).padding(20)

            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 14)
            }

            HStack {
                Spacer()
                Button(model.creating ? "Connecting…" : "Duplicate Window") {
                    Task { await model.duplicateSelected() }
                }
                .buttonStyle(.borderedProminent).tint(.mint)
                .disabled(!model.hasPermission || model.selectedID == nil || model.creating)
                .keyboardShortcut(.return, modifiers: [])
            }
            .font(.system(size: 12)).padding(.horizontal, 20).padding(.bottom, 20)
        }
        .frame(width: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .task { if model.hasPermission { await model.refreshSources() } }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SOURCE WINDOW").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
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
                    Image(systemName: "macwindow").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("No matching windows").font(.headline)
                    Text("Open Live View in Capture One, then refresh.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
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
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(source.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(source.app).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.selectedID == source.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                                    }
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedID == source.id ? Color.mint.opacity(0.12) : Color.white.opacity(0.025),
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
            Text("Choose Live View, duplicate it, then drag the copy onto your iPad or another display.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var permissionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Allow window capture", systemImage: "macwindow.on.rectangle")
                .font(.system(size: 16, weight: .semibold))
            Text("macOS needs Screen Recording permission to copy another app's window. Choose Capture DualLink in System Settings when prompted.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow Window Capture") { model.requestPermission() }
                    .buttonStyle(.borderedProminent).tint(.mint)
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

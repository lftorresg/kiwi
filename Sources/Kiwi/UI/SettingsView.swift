import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Small helpers for jumping into System Settings and restarting Kiwi.
@MainActor
enum SystemLinks {
    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// macOS applies a new Screen Recording grant only to a fresh process.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// Live system state for the settings and setup windows.
///
/// A plain ObservableObject rather than `@State`: in current SDKs `@State` is a
/// macro whose plugin ships only with Xcode, and Kiwi should build with the
/// Command Line Tools alone.
@MainActor
final class SystemStatus: ObservableObject {
    @Published var launchAtLogin: Bool
    @Published var hasPermission: Bool

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        hasPermission = ScreenGrabber.hasPermission
    }

    func refresh() {
        hasPermission = ScreenGrabber.hasPermission
    }
}

/// Owns the Settings and Setup windows.
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    static let shared = WindowRouter()

    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private let status = SystemStatus()

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: "Kiwi Settings",
                size: NSSize(width: 560, height: 600),
                content: SettingsView(prefs: Prefs.shared, status: status)
            )
        }
        present(settingsWindow)
    }

    func showSetup() {
        if setupWindow == nil {
            setupWindow = makeWindow(
                title: "Welcome to Kiwi",
                size: NSSize(width: 520, height: 600),
                content: SetupView(status: status)
            )
        }
        present(setupWindow)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var status: SystemStatus

    var body: some View {
        TabView {
            tab("General", "gearshape") {
                screenshotsSection
                systemSection
            }
            tab("Redaction", "eye.slash") {
                redactionSection
            }
            tab("Recording", "record.circle") {
                recordingSection
            }
            tab("Wheel", "circle.dashed") {
                wheelSection
            }
            tab("Shortcuts", "keyboard") {
                shortcutsSection
            }
        }
        .onAppear { status.refresh() }
    }

    /// One settings pane: a grouped form under a labelled tab.
    private func tab<Content: View>(
        _ title: String, _ symbol: String, @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .tabItem {
            Label(title, systemImage: symbol)
        }
    }

    private var screenshotsSection: some View {
        Section("Screenshots") {
            Toggle("Open the editor right after a capture", isOn: $prefs.editAfterCapture)
            Toggle("Copy to clipboard after capture", isOn: $prefs.copyOnCapture)
            Toggle("Also save every capture to a folder", isOn: $prefs.saveOnCapture)
            LabeledContent("Save folder") {
                HStack(spacing: 8) {
                    Text(prefs.saveFolderURL.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Toggle("Play shutter sound", isOn: $prefs.playSound)
            Toggle("Show pointer in full-screen captures", isOn: $prefs.showCursor)
            LabeledContent("Keep corner preview for") {
                Picker("", selection: $prefs.previewSeconds) {
                    Text("4 seconds").tag(4.0)
                    Text("6 seconds").tag(6.0)
                    Text("10 seconds").tag(10.0)
                    Text("20 seconds").tag(20.0)
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
    }

    private var redactionSection: some View {
        Section("Redaction") {
            Toggle("Redact every capture before copying or saving", isOn: $prefs.autoRedact)
            Text("Kiwi reads the text in the screenshot on this Mac and covers what it recognises with solid boxes. If the scan fails, nothing is copied. Detection is best effort, so check the result before sharing.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(PIICategory.allCases) { category in
                Toggle(category.title, isOn: categoryBinding(category))
            }
            Toggle("Faces", isOn: $prefs.redactFaces)
        }
    }

    private var recordingSection: some View {
        Section("Recording") {
            Picker("Resolution", selection: $prefs.recordMaxHeight) {
                Text("Native").tag(0)
                Text("4K (2160p)").tag(2160)
                Text("1440p").tag(1440)
                Text("1080p").tag(1080)
                Text("720p").tag(720)
            }
            Picker("Frame rate", selection: $prefs.recordFrameRate) {
                Text("60 fps").tag(60)
                Text("30 fps").tag(30)
            }
            Text("Native keeps the screen's own resolution, up to 4K. A lower resolution and 30 fps make recording lighter on the Mac and the files smaller.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Record in HEVC", isOn: $prefs.recordHEVC)
            Text("HEVC is sharper at a smaller size. Turn it off for H.264, which plays in more apps and on older devices.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Record system audio", isOn: $prefs.recordSystemAudio)
            Toggle("Record microphone", isOn: $prefs.recordMicrophone)
                .onChange(of: prefs.recordMicrophone) { _, enabled in
                    if enabled { confirmMicrophoneAccess() }
                }
            Text("Off by default. macOS asks for permission the first time and shows its orange indicator while the microphone is in use. Recordings with the microphone are saved as MOV.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: recordingHint)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var wheelSection: some View {
        Section("Drag wheel") {
            Toggle("Show the wheel while dragging files", isOn: $prefs.wheelEnabled)
                .onChange(of: prefs.wheelEnabled) { _, enabled in
                    WheelController.shared.setEnabled(enabled)
                }
            LabeledContent("Conversion quality") {
                HStack(spacing: 8) {
                    Slider(value: $prefs.convertQuality, in: 0.5...1.0)
                        .frame(width: 150)
                    Text("\(Int((prefs.convertQuality * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Text("While dragging files, tap ⇧ for Convert, ⌘ for Tools or ⌃ for Actions, then drop on a slice. Drop on the centre to cancel.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("Never show for drags from") {
                Button("Add App…") { addExcludedApp() }
            }
            ForEach(prefs.excludedApps, id: \.self) { bundleID in
                LabeledContent(appName(for: bundleID)) {
                    Button {
                        prefs.excludedApps.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Show the wheel for this app again")
                }
            }
        }
    }

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            ForEach(ShortcutAction.allCases) { action in
                LabeledContent(action.title) {
                    ShortcutRecorder(action: action, shortcut: prefs.shortcut(for: action))
                        .frame(width: 150, height: 26)
                }
            }
            Text("Click a shortcut, then press the new keys. Esc cancels and ⌫ removes the shortcut.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Restore default shortcuts") { ShortcutManager.shared.restoreDefaults() }
            Button("Turn off the macOS shortcuts…") { SystemLinks.openKeyboardSettings() }
            Text("In Keyboard, open Keyboard Shortcuts, pick Screenshots, and untick the ⇧⌘3, ⇧⌘4 and ⇧⌘5 rows so they reach Kiwi.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingHint: String {
        let keys = prefs.shortcut(for: .record).map { " or with \($0.display)" } ?? ""
        return "Recordings are saved in the same folder as screenshots. Stop with the floating Stop button\(keys)."
    }

    private var systemSection: some View {
        Section("System") {
            Toggle("Open Kiwi at login", isOn: $status.launchAtLogin)
                .onChange(of: status.launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }
            LabeledContent("Screen Recording") {
                HStack(spacing: 8) {
                    Text(status.hasPermission ? "Allowed" : "Not allowed")
                        .foregroundStyle(status.hasPermission ? Color.secondary : Color.orange)
                    if !status.hasPermission {
                        Button("Open Settings…") { SystemLinks.openScreenRecordingSettings() }
                    }
                }
            }
        }
    
    }

    private func categoryBinding(_ category: PIICategory) -> Binding<Bool> {
        Binding(
            get: { prefs.redactCategories.contains(category) },
            set: { enabled in
                if enabled {
                    prefs.redactCategories.insert(category)
                } else {
                    prefs.redactCategories.remove(category)
                }
            }
        )
    }

    /// Asks for the microphone as soon as the option is turned on, so the
    /// permission prompt does not appear in the middle of a recording.
    private func confirmMicrophoneAccess() {
        Task { @MainActor in
            if await RecordingController.microphoneAllowed() { return }
            prefs.recordMicrophone = false
            Toast.error("Allow the microphone for Kiwi in System Settings")
            SystemLinks.openMicrophoneSettings()
        }
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        if !prefs.excludedApps.contains(bundleID) {
            prefs.excludedApps.append(bundleID)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = prefs.saveFolderURL.deletingLastPathComponent()
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            prefs.saveFolder = url.path
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Kiwi: launch at login failed: %@", error.localizedDescription)
            Toast.error("Move Kiwi to Applications first")
        }
    }
}

// MARK: - Setup guide

struct SetupView: View {
    @ObservedObject var status: SystemStatus

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                Text("Welcome to Kiwi")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Two quick steps and Kiwi takes over your screenshots.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 36)
            .padding(.bottom, 22)

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    step(
                        number: 1,
                        done: status.hasPermission,
                        title: "Allow Screen Recording",
                        detail: status.hasPermission
                            ? "Done. Kiwi can capture your screen."
                            : "Kiwi needs this to take screenshots. Switch Kiwi on in the list, then relaunch."
                    ) {
                        if !status.hasPermission {
                            Button("Open Settings") {
                                ScreenGrabber.requestPermission()
                                SystemLinks.openScreenRecordingSettings()
                            }
                            Button("Relaunch Kiwi") { SystemLinks.relaunch() }
                        }
                    }

                    step(
                        number: 2,
                        done: false,
                        title: "Hand ⇧⌘4 to Kiwi",
                        detail: "In Keyboard settings, open Keyboard Shortcuts, pick Screenshots, and untick the ⇧⌘3, ⇧⌘4 and ⇧⌘5 rows. macOS keeps them otherwise."
                    ) {
                        Button("Open Keyboard Settings") { SystemLinks.openKeyboardSettings() }
                    }

                    step(
                        number: 3,
                        done: false,
                        title: "Try it",
                        detail: "⇧⌘4 captures, ⇧⌘5 records, ⇧⌘6 captures while you scroll. While dragging files in Finder, tap ⇧, ⌘ or ⌃ for the wheel."
                    ) {
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            Button("Start using Kiwi") {
                Prefs.shared.didOnboard = true
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.kiwi)
            .controlSize(.large)
            .padding(.bottom, 26)
        }
        .frame(minWidth: 520, minHeight: 600)
        .onAppear { status.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status.refresh()
        }
    }

    private func step<Actions: View>(
        number: Int,
        done: Bool,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Theme.kiwi : Color.primary.opacity(0.1))
                    .frame(width: 30, height: 30)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    actions()
                }
                .buttonStyle(.glass)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

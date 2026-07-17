import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import IOKit.hid

@main
struct VibeRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var mappingStore: MappingStore
    @StateObject private var monitor: HIDMonitor
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @StateObject private var appSwitcher: AppSwitcherStore

    init() {
        let store = MappingStore()
        let switcher = AppSwitcherStore()
        _mappingStore = StateObject(wrappedValue: store)
        _appSwitcher = StateObject(wrappedValue: switcher)
        let monitor = HIDMonitor(mappingStore: store, appSwitcher: switcher)
        _monitor = StateObject(wrappedValue: monitor)
        // LSUIElement app: the settings window may never open, so start HID
        // monitoring at launch instead of relying on the window's onAppear.
        DispatchQueue.main.async {
            Permissions.requestInputMonitoringIfNeeded()
            if store.enabled { ShortcutSender.requestAccessibility() }
            monitor.start()
        }
    }

    var body: some Scene {
        WindowGroup("VibeRemote 遥控器设置", id: "settings") {
            MainSettingsView(monitor: monitor, store: mappingStore, launchAtLogin: launchAtLogin, appSwitcher: appSwitcher)
                .frame(minWidth: 1040, minHeight: 700)
                .onAppear {
                    Permissions.requestInputMonitoringIfNeeded()
                    if mappingStore.enabled { ShortcutSender.requestAccessibility() }
                    monitor.start()
                }
        }
        .defaultSize(width: 1180, height: 760)

        WindowGroup("HID 调试器", id: "hid-debugger") {
            HIDDebuggerView(monitor: monitor)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 800, height: 560)

        MenuBarExtra("VibeRemote", systemImage: "r.square.fill") {
            MenuBarView(store: mappingStore, monitor: monitor)
        }

        Settings {
            MainSettingsView(monitor: monitor, store: mappingStore, launchAtLogin: launchAtLogin, appSwitcher: appSwitcher)
                .frame(width: 1040, height: 700)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains(where: { ["--show-settings", "--motion-demo", "--preset-demo", "--app-switcher-settings-demo"].contains($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.windows.first(where: { $0.title == "VibeRemote 遥控器设置" })?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.windows.first(where: { $0.title == "VibeRemote 遥控器设置" })?.close()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }
}

struct MenuBarView: View {
    @ObservedObject var store: MappingStore
    let monitor: HIDMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(monitor.connected ? "遥控器已连接" : "遥控器未连接",
              systemImage: monitor.connected ? "checkmark.circle.fill" : "exclamationmark.circle")
        Divider()
        Toggle("开启按键映射", isOn: Binding(
            get: { store.enabled },
            set: {
                store.enabled = $0
                if $0 { ShortcutSender.requestAccessibility() }
            }
        ))
        Button("打开遥控器设置") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("开始听写") { ShortcutSender.startDictation() }
        Button("打开 HID 调试器") {
            openWindow(id: "hid-debugger")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("退出 VibeRemote") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case remote = "遥控器"
    case appSwitcher = "应用切换器"
    case presets = "预设方案"
    case permissions = "权限与启动"
    case advanced = "高级"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .remote: return "av.remote"
        case .appSwitcher: return "rectangle.3.group"
        case .presets: return "square.grid.2x2"
        case .permissions: return "checkmark.shield"
        case .advanced: return "gearshape"
        }
    }
}

struct MainSettingsView: View {
    @ObservedObject var monitor: HIDMonitor
    @ObservedObject var store: MappingStore
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @ObservedObject var appSwitcher: AppSwitcherStore
    @State private var section = CommandLine.arguments.contains("--app-switcher-settings-demo") ? SettingsSection.appSwitcher : .remote
    @State private var selectedKey = RemoteKey.ok
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 205)
            .safeAreaInset(edge: .bottom) {
                Toggle("开机启动", isOn: Binding(
                    get: { launchAtLogin.enabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .padding()
            }
        } detail: {
            VStack(spacing: 0) {
                HeaderStatusView(monitor: monitor, store: store)
                Divider()
                Group {
                    switch section {
                    case .remote:
                        RemoteSettingsPage(monitor: monitor, store: store, selectedKey: $selectedKey)
                    case .appSwitcher:
                        AppSwitcherSettingsPage(store: appSwitcher)
                    case .presets:
                        PresetsPage(store: store)
                    case .permissions:
                        PermissionsPage(launchAtLogin: launchAtLogin)
                    case .advanced:
                        AdvancedPage(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard CommandLine.arguments.contains("--motion-demo") else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            for key in [RemoteKey.home, .right, .ok, .back] {
                selectedKey = key
                monitor.previewPress(key.rawValue)
                try? await Task.sleep(nanoseconds: reduceMotion ? 500_000_000 : 750_000_000)
            }
            AppSwitcherController.shared.show(store: appSwitcher)
            try? await Task.sleep(nanoseconds: 700_000_000)
            AppSwitcherController.shared.move(1)
            try? await Task.sleep(nanoseconds: 700_000_000)
            AppSwitcherController.shared.move(1)
        }
    }
}

struct HeaderStatusView: View {
    @ObservedObject var monitor: HIDMonitor
    @ObservedObject var store: MappingStore
    @State private var showPresetMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("VibeRemote 遥控器设置").font(.system(size: 28, weight: .bold))
                Spacer()
                Button("预设", systemImage: "chevron.down") { showPresetMenu.toggle() }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .popover(isPresented: $showPresetMenu, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("选择预设方案").font(.headline).padding(.bottom, 4)
                            ForEach(Preset.allCases) { preset in
                                Button { showPresetMenu = false; store.pendingPreset = preset } label: {
                                    Label(preset.rawValue, systemImage: preset == .media ? "playpause" : "sparkles")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).padding(.vertical, 5)
                            }
                        }.padding(16).frame(width: 240)
                    }
            }
            HStack(spacing: 10) {
                StatusBadge(title: "遥控器", value: monitor.connected ? "已连接" : "未连接", ok: monitor.connected, icon: "av.remote")
                StatusBadge(title: "按键映射", value: store.enabled ? "已开启" : "已关闭", ok: store.enabled, icon: "keyboard")
                StatusBadge(title: "输入监控", value: Permissions.inputAllowed ? "已允许" : "需授权", ok: Permissions.inputAllowed, icon: "wave.3.right")
                StatusBadge(title: "辅助功能", value: Permissions.accessibilityAllowed ? "已允许" : "需授权", ok: Permissions.accessibilityAllowed, icon: "accessibility")
                Spacer()
                Toggle("开启映射", isOn: $store.enabled).toggleStyle(.switch)
            }
        }
        .padding(24)
        .confirmationDialog("应用预设方案？", isPresented: Binding(
            get: { store.pendingPreset != nil },
            set: { if !$0 { store.pendingPreset = nil } }
        )) {
            if let preset = store.pendingPreset {
                Button("应用“\(preset.rawValue)”") { store.apply(preset) }
                Button("取消", role: .cancel) { store.pendingPreset = nil }
            }
        } message: {
            Text("这会覆盖当前按键映射。")
        }
        .onAppear {
            guard CommandLine.arguments.contains("--preset-demo") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showPresetMenu = true }
        }
    }
}

struct StatusBadge: View {
    let title: String
    let value: String
    let ok: Bool
    let icon: String

    var body: some View {
        Label {
            Text("\(title) · \(value)")
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : icon)
                .foregroundStyle(ok ? .green : .orange)
        }
        .font(.callout)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct RemoteSettingsPage: View {
    @ObservedObject var monitor: HIDMonitor
    @ObservedObject var store: MappingStore
    @Binding var selectedKey: RemoteKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("我的小米遥控器").font(.title2.bold())
                Text("点击遥控器上的按键进行设置").foregroundStyle(.secondary)
                RemoteDiagram(selected: $selectedKey, pressedCode: monitor.visualPressedCode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(28)
            .frame(minWidth: 430)
            Divider()
            KeyInspector(store: store, key: selectedKey)
                .id(selectedKey)
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)), removal: .opacity))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedKey)
                .frame(width: 370)
                .padding(26)
        }
    }
}

enum PressKind: String, CaseIterable, Identifiable {
    case short = "短按"
    case long = "长按"
    case double = "双击"
    var id: String { rawValue }
    var suffix: String {
        switch self { case .short: return ""; case .long: return ".long"; case .double: return ".double" }
    }
}

enum RemoteKey: String, CaseIterable, Identifiable {
    case power = "0x66", menu = "0x65", up = "0x52", down = "0x51", left = "0x50", right = "0x4F"
    case ok = "0x28", back = "0xF1", home = "0x3E", volumeUp = "0x80", volumeDown = "0x81"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .power: return "电源键"; case .menu: return "菜单键"; case .up: return "上"; case .down: return "下"
        case .left: return "左"; case .right: return "右"; case .ok: return "确认"; case .back: return "返回"
        case .home: return "HOME"; case .volumeUp: return "音量+"; case .volumeDown: return "音量−"
        }
    }
    var icon: String {
        switch self {
        case .power: return "power"; case .menu: return "line.3.horizontal"; case .up: return "chevron.up"
        case .down: return "chevron.down"; case .left: return "chevron.left"; case .right: return "chevron.right"
        case .ok: return "checkmark"; case .back: return "arrow.uturn.backward"; case .home: return "house"
        case .volumeUp: return "plus"; case .volumeDown: return "minus"
        }
    }
    func configKey(_ kind: PressKind) -> String {
        if self == .home && kind == .short { return rawValue + ".short" }
        return rawValue + kind.suffix
    }
}

struct RemoteDiagram: View {
    @Binding var selected: RemoteKey
    let pressedCode: String?
    @ObservedObject private var feedback = VisualFeedback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 48)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.13), radius: 14, y: 6)
                .frame(width: 250, height: 540)
            VStack(spacing: 17) {
                remoteButton(.power, size: 42)
                ZStack {
                    Circle().fill(.black.opacity(0.07)).frame(width: 180, height: 180)
                    remoteButton(.up, size: 42).offset(y: -61)
                    remoteButton(.down, size: 42).offset(y: 61)
                    remoteButton(.left, size: 42).offset(x: -61)
                    remoteButton(.right, size: 42).offset(x: 61)
                    remoteButton(.ok, size: 66)
                }
                HStack(spacing: 28) {
                    remoteButton(.home, size: 48)
                    remoteButton(.back, size: 48)
                    remoteButton(.menu, size: 48)
                }
                VStack(spacing: 0) {
                    remoteButton(.volumeUp, size: 50)
                    remoteButton(.volumeDown, size: 50)
                }
            }
            .padding(.vertical, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("小米遥控器按键图")
    }

    private func remoteButton(_ key: RemoteKey, size: CGFloat) -> some View {
        Button { selected = key } label: {
            ZStack {
                if key == .home && feedback.dictationActive {
                    DictationPulse(size: size, reduceMotion: reduceMotion)
                }
                Image(systemName: key.icon)
                    .font(.system(size: key == .ok ? 20 : 17, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(selected == key ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                    .foregroundStyle(selected == key ? .white : .primary)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.primary.opacity(0.12)))
            }
            .scaleEffect(pressedCode == key.rawValue ? 0.90 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.52), value: pressedCode)
        }
        .buttonStyle(.plain)
        .help(key.name)
        .accessibilityLabel(key.name)
    }
}

struct DictationPulse: View {
    let size: CGFloat
    let reduceMotion: Bool
    @State private var pulse = false
    var body: some View {
        Circle().stroke(Color.accentColor, lineWidth: 3)
            .frame(width: size + 10, height: size + 10)
            .scaleEffect(reduceMotion ? 1 : (pulse ? 1.22 : 1))
            .opacity(reduceMotion ? 0.7 : (pulse ? 0.12 : 0.75))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

struct KeyInspector: View {
    @ObservedObject var store: MappingStore
    let key: RemoteKey
    @State private var kind = PressKind.short
    @State private var showAdvanced = false
    @State private var scriptText = ""
    @State private var saved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var configKey: String { key.configKey(kind) }
    var current: FunctionAction { FunctionAction.find(store.mappings[configKey] ?? "ignore") }
    var scriptKind: String? {
        let value = store.mappings[configKey] ?? ""
        if value == "applescript" || value.hasPrefix("applescript:") { return "applescript" }
        if value == "shell" || value.hasPrefix("shell:") { return "shell" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("\(key.name)键", systemImage: key.icon).font(.title2.bold())
            Picker("按键方式", selection: $kind) {
                Text("短按").tag(PressKind.short)
                if showAdvanced {
                    Text("长按").tag(PressKind.long)
                    Text("双击").tag(PressKind.double)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("当前功能").font(.headline)
                HStack(spacing: 12) {
                    if let url = AppLocator.url(for: store.mappings[configKey] ?? "") {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 34, height: 34)
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent).font(.title3)
                            Text("已找到").font(.caption).foregroundStyle(.green)
                        }
                    } else {
                        Label(current.title, systemImage: current.icon).font(.title3)
                        if (store.mappings[configKey] ?? "").hasPrefix("open:") {
                            Text("未找到该 App").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }

            Menu {
                ForEach(ActionCategory.allCases) { category in
                    Menu(category.rawValue) {
                        ForEach(FunctionAction.actions(in: category)) { action in
                            Button {
                                store.set(action.value, for: configKey)
                            } label: {
                                Label(action.title, systemImage: action.icon)
                            }
                        }
                    }
                }
            } label: {
                Label("选择功能…", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            if current.value == "record" {
                ShortcutRecorder(shortcut: Binding(
                    get: { store.mappings[configKey] ?? "ignore" },
                    set: { store.set($0, for: configKey) }
                )).frame(height: 32)
            }
            if current.value == "choose-app" {
                Button("选择 Applications 中的 App…") { store.chooseApp(for: configKey) }
            }
            if let scriptKind {
                TextEditor(text: $scriptText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                Button("保存脚本") {
                    let encoded = Data(scriptText.utf8).base64EncodedString()
                    store.set("\(scriptKind):\(encoded)", for: configKey)
                }
            }

            DisclosureGroup("高级设置：长按与双击", isExpanded: $showAdvanced) {
                Text("展开后可为这个按键分别设置长按和双击。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
            Spacer()
            HStack {
                Text("配置会自动保存").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if saved { Label("已保存", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).transition(.opacity.combined(with: .scale)) }
            }
        }
        .onChange(of: key) { _ in kind = .short }
        .onChange(of: store.saveGeneration) { _ in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { saved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.16)) { saved = false }
            }
        }
    }
}

enum ActionCategory: String, CaseIterable, Identifiable {
    case common = "常用操作", apps = "App 与窗口", ai = "AI Coding", media = "媒体与系统", custom = "自定义"
    var id: String { rawValue }
}

struct FunctionAction: Identifiable {
    let category: ActionCategory
    let title: String
    let value: String
    let icon: String
    var id: String { category.rawValue + value }

    static let all: [FunctionAction] = [
        .init(category: .common, title: "确认 / Enter", value: "return", icon: "return"),
        .init(category: .common, title: "返回 / Esc", value: "escape", icon: "escape"),
        .init(category: .common, title: "Tab", value: "tab", icon: "arrow.right.to.line"),
        .init(category: .common, title: "Shift + Tab", value: "shift+tab", icon: "arrow.left.to.line"),
        .init(category: .common, title: "向上", value: "up", icon: "arrow.up"),
        .init(category: .common, title: "向下", value: "down", icon: "arrow.down"),
        .init(category: .common, title: "向左", value: "left", icon: "arrow.left"),
        .init(category: .common, title: "向右", value: "right", icon: "arrow.right"),
        .init(category: .common, title: "空格", value: "space", icon: "space"),
        .init(category: .common, title: "删除", value: "delete", icon: "delete.left"),
        .init(category: .common, title: "复制", value: "command+c", icon: "doc.on.doc"),
        .init(category: .common, title: "粘贴", value: "command+v", icon: "doc.on.clipboard"),
        .init(category: .common, title: "撤销", value: "command+z", icon: "arrow.uturn.backward"),
        .init(category: .common, title: "重做", value: "command+shift+z", icon: "arrow.uturn.forward"),
        .init(category: .apps, title: "切换到下一个 App", value: "command+tab", icon: "arrow.right.square"),
        .init(category: .apps, title: "切换到上一个 App", value: "command+shift+tab", icon: "arrow.left.square"),
        .init(category: .apps, title: "打开应用切换器", value: "app-switcher", icon: "rectangle.3.group"),
        .init(category: .apps, title: "打开 ChatGPT", value: "open:chatgpt", icon: "bubble.left.and.bubble.right"),
        .init(category: .apps, title: "打开 Codex", value: "open:codex", icon: "terminal"),
        .init(category: .apps, title: "打开 Cursor", value: "open:cursor", icon: "cursorarrow"),
        .init(category: .apps, title: "打开 Claude", value: "open:claude", icon: "sparkles"),
        .init(category: .apps, title: "打开指定 App", value: "choose-app", icon: "app.badge"),
        .init(category: .apps, title: "Mission Control", value: "control+up", icon: "rectangle.3.group"),
        .init(category: .apps, title: "显示桌面", value: "fn+f11", icon: "desktopcomputer"),
        .init(category: .apps, title: "关闭窗口", value: "command+w", icon: "xmark.square"),
        .init(category: .apps, title: "最小化窗口", value: "command+m", icon: "minus.square"),
        .init(category: .ai, title: "发送消息", value: "return", icon: "paperplane"),
        .init(category: .ai, title: "接受补全", value: "tab", icon: "checkmark.circle"),
        .init(category: .ai, title: "取消生成", value: "escape", icon: "stop.circle"),
        .init(category: .ai, title: "开始系统听写", value: "dictation", icon: "mic"),
        .init(category: .ai, title: "停止系统听写", value: "dictation", icon: "mic.slash"),
        .init(category: .ai, title: "Fn / 切换系统听写", value: "fn", icon: "fn"),
        .init(category: .ai, title: "Command + Enter", value: "command+return", icon: "command"),
        .init(category: .ai, title: "打开 AI 输入框", value: "command+l", icon: "text.cursor"),
        .init(category: .media, title: "音量增加", value: "volume-up", icon: "speaker.plus"),
        .init(category: .media, title: "音量减少", value: "volume-down", icon: "speaker.minus"),
        .init(category: .media, title: "静音", value: "mute", icon: "speaker.slash"),
        .init(category: .media, title: "播放 / 暂停", value: "play-pause", icon: "playpause"),
        .init(category: .media, title: "截图", value: "command+shift+4", icon: "camera.viewfinder"),
        .init(category: .media, title: "锁定屏幕", value: "control+command+q", icon: "lock"),
        .init(category: .custom, title: "录制键盘快捷键", value: "record", icon: "keyboard"),
        .init(category: .custom, title: "打开 App", value: "choose-app", icon: "app"),
        .init(category: .custom, title: "运行 AppleScript", value: "applescript", icon: "applescript"),
        .init(category: .custom, title: "运行 Shell Script", value: "shell", icon: "terminal"),
        .init(category: .custom, title: "不执行任何操作", value: "ignore", icon: "nosign")
    ]

    static func actions(in category: ActionCategory) -> [FunctionAction] { all.filter { $0.category == category } }
    static func find(_ value: String) -> FunctionAction {
        if value.hasPrefix("app:") {
            let path = value.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            return .init(category: .custom, title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, value: value, icon: "app")
        }
        if value.hasPrefix("applescript:") { return .init(category: .custom, title: "运行 AppleScript", value: value, icon: "applescript") }
        if value.hasPrefix("shell:") { return .init(category: .custom, title: "运行 Shell Script", value: value, icon: "terminal") }
        return all.first(where: { $0.value == value }) ?? .init(category: .custom, title: Shortcut.display(value), value: value, icon: "keyboard")
    }
}

enum Preset: String, CaseIterable, Identifiable {
    case chatGPT = "ChatGPT 遥控", codex = "Codex 遥控", cursor = "Cursor 遥控", claude = "Claude Code 遥控"
    case coding = "通用 AI Coding", media = "媒体遥控", defaults = "恢复默认设置"
    var id: String { rawValue }
}

struct PresetsPage: View {
    @ObservedObject var store: MappingStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("预设方案").font(.largeTitle.bold())
            Text("选择适合你的使用方式。应用前会再次确认。") .foregroundStyle(.secondary)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 14) {
                ForEach(Preset.allCases) { preset in
                    Button { store.pendingPreset = preset } label: {
                        Label(preset.rawValue, systemImage: preset == .media ? "playpause" : "sparkles")
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer()
        }.padding(28)
    }
}

struct PermissionsPage: View {
    @ObservedObject var launchAtLogin: LaunchAtLogin
    var body: some View {
        Form {
            Section("权限状态") {
                permissionRow("输入监控", allowed: Permissions.inputAllowed) { Permissions.requestInputMonitoringIfNeeded() }
                permissionRow("辅助功能", allowed: Permissions.accessibilityAllowed) { ShortcutSender.requestAccessibility() }
            }
            Section("启动") {
                Toggle("登录 Mac 时自动启动", isOn: Binding(get: { launchAtLogin.enabled }, set: { launchAtLogin.setEnabled($0) }))
                if let error = launchAtLogin.error { Text(error).foregroundStyle(.red) }
            }
        }.formStyle(.grouped)
    }
    private func permissionRow(_ title: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack { Label(title, systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(allowed ? .green : .orange); Spacer(); Text(allowed ? "已允许" : "需要授权"); if !allowed { Button("授权", action: action) } }
    }
}

struct AdvancedPage: View {
    @ObservedObject var store: MappingStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Form {
            Section("高级调试") {
                Button("打开 HID 调试器") { openWindow(id: "hid-debugger"); NSApp.activate(ignoringOtherApps: true) }
                Text("原始 Hex、Usage Page、Report ID 和导出日志仅在调试器中显示。")
                    .foregroundStyle(.secondary)
            }
            Section("配置") {
                Text(store.configURL.path).textSelection(.enabled)
                Button("恢复默认按键映射", role: .destructive) { store.pendingPreset = .defaults }
            }
        }.formStyle(.grouped)
    }
}

struct HIDDebuggerView: View {
    @ObservedObject var monitor: HIDMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(monitor.connected ? "遥控器已连接" : "遥控器未连接").font(.headline)
            GroupBox("最新事件") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    debugRow("Usage Page", monitor.latest.usagePage); debugRow("Usage", monitor.latest.usage)
                    debugRow("Integer Value", monitor.latest.integerValue); debugRow("Report ID", monitor.latest.reportID)
                    debugRow("Hex", monitor.latest.hexData); debugRow("时间", monitor.latest.time)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            HStack { Button("清除") { monitor.clearLog() }; Button("复制") { monitor.copyLog() }; Button("导出") { monitor.exportLog() } }
            ScrollView { Text(monitor.log.isEmpty ? "等待 HID 事件…" : monitor.log).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .border(.separator)
        }.padding()
    }
    private func debugRow(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value.isEmpty ? "—" : value).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
    }
}

struct AppSwitcherItem: Codable, Identifiable, Equatable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    var name: String
    var claudeHost = false
    var windowTitleKeyword = ""
}

final class AppSwitcherStore: ObservableObject {
    @Published var items: [AppSwitcherItem] { didSet { save() } }
    @Published var runningOnly: Bool { didSet { UserDefaults.standard.set(runningOnly, forKey: "appSwitcherRunningOnly") } }

    init() {
        if let data = UserDefaults.standard.data(forKey: "appSwitcherItems"),
           let saved = try? JSONDecoder().decode([AppSwitcherItem].self, from: data) {
            items = Array(saved.prefix(5))
        } else {
            let defaults = [
                ("com.anthropic.claudefordesktop", "Claude"),
                ("com.openai.chat", "ChatGPT"), ("com.openai.codex", "Codex"),
                ("com.todesktop.230313mzl4w4u92", "Cursor"), ("com.apple.Terminal", "Terminal")
            ]
            items = defaults.compactMap { id, name in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil ? nil : AppSwitcherItem(bundleIdentifier: id, name: name)
            }
        }
        runningOnly = UserDefaults.standard.bool(forKey: "appSwitcherRunningOnly")
    }

    var visibleItems: [AppSwitcherItem] {
        items.filter { item in
            guard installed(item) else { return false }
            return !runningOnly || !NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleIdentifier).isEmpty
        }
    }

    func installed(_ item: AppSwitcherItem) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleIdentifier) != nil
    }

    func addApp() {
        guard items.count < 5 else { return }
        let panel = NSOpenPanel()
        panel.title = "添加到应用切换器"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              !items.contains(where: { $0.bundleIdentifier == id }) else { return }
        items.append(.init(bundleIdentifier: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")))
    }

    func remove(at offsets: IndexSet) { items.remove(atOffsets: offsets) }
    func move(from offsets: IndexSet, to destination: Int) { items.move(fromOffsets: offsets, toOffset: destination) }

    func activate(_ item: AppSwitcherItem) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleIdentifier).first {
            running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            InputFocuser.focusTextInput(bundleIdentifier: item.bundleIdentifier)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            InputFocuser.focusTextInput(bundleIdentifier: item.bundleIdentifier, attempts: 8)
        }
    }

    func icon(for item: AppSwitcherItem) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleIdentifier) else { return NSImage() }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "appSwitcherItems") }
    }
}

struct AppSwitcherSettingsPage: View {
    @ObservedObject var store: AppSwitcherStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("应用切换器").font(.largeTitle.bold())
                    Text("HOME 短按打开，最多添加 5 个常用 App。拖动可调整顺序。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加应用", systemImage: "plus") { store.addApp() }.disabled(store.items.count >= 5)
            }
            Toggle("只显示正在运行的应用", isOn: $store.runningOnly)
            List {
                ForEach($store.items) { $item in
                    HStack(spacing: 14) {
                        Image(nsImage: store.icon(for: item)).resizable().frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("应用名称", text: $item.name).font(.headline)
                            Text(item.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                            if !store.installed(item) { Text("未安装，将自动隐藏").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Toggle("Claude Code 宿主", isOn: $item.claudeHost).toggleStyle(.checkbox)
                        if item.claudeHost {
                            TextField("窗口标题关键词（可选）", text: $item.windowTitleKeyword).frame(width: 180)
                        }
                    }
                    .padding(.vertical, 7)
                }
                .onDelete(perform: store.remove)
                .onMove(perform: store.move)
            }
            Text("Claude Code 可以把 Terminal、Warp、Cursor、iTerm 或其他 App 设为宿主；切换时会激活该宿主 App。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28)
    }
}

final class AppSwitcherSession: ObservableObject {
    @Published var items: [AppSwitcherItem] = []
    @Published var selected = 0
    var currentBundleID = ""
}

struct AppSwitcherOverlayView: View {
    @ObservedObject var session: AppSwitcherSession
    let store: AppSwitcherStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            Text("选择应用").font(.headline)
            HStack(spacing: 18) {
                ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: store.icon(for: item)).resizable().frame(width: index == session.selected ? 70 : 54, height: index == session.selected ? 70 : 54)
                            if item.bundleIdentifier == session.currentBundleID {
                                Text("当前").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.green, in: Capsule()).foregroundStyle(.white).offset(x: 12, y: -8)
                            }
                        }
                        Text(item.claudeHost ? "Claude Code" : item.name).lineLimit(1)
                    }
                    .frame(width: 104)
                    .opacity(index == session.selected ? 1 : 0.55)
                    .padding(.vertical, 10)
                    .background(index == session.selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 14))
                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: session.selected)
                }
            }
            Text("方向键选择 · 确认或 HOME 切换 · 返回取消").font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 180)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

final class AppSwitcherController {
    static let shared = AppSwitcherController()
    private let session = AppSwitcherSession()
    private weak var store: AppSwitcherStore?
    private var panel: NSPanel?
    private var timeout: DispatchWorkItem?
    var isVisible: Bool { panel != nil }

    func show(store: AppSwitcherStore) {
        let items = store.visibleItems
        guard !items.isEmpty else {
            EventOverlay.shared.show(remote: "应用切换器", action: "没有可显示的 App", isError: true)
            return
        }
        self.store = store
        session.items = items
        session.selected = 0
        session.currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 210), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: AppSwitcherOverlayView(session: session, store: store))
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.midX - 310, y: screen.midY - 105))
            }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    panel.animator().alphaValue = 1
                }
            }
            self.panel = panel
        }
        resetTimeout()
    }

    func move(_ delta: Int) {
        guard isVisible, !session.items.isEmpty else { return }
        session.selected = (session.selected + delta + session.items.count) % session.items.count
        resetTimeout()
    }

    func confirm() {
        guard isVisible, session.items.indices.contains(session.selected), let store else { return }
        let item = session.items[session.selected]
        close()
        store.activate(item)
    }

    func close() {
        timeout?.cancel()
        timeout = nil
        panel?.close()
        panel = nil
    }

    private func resetTimeout() {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

final class LaunchAtLogin: ObservableObject {
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    func setEnabled(_ value: Bool) {
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            enabled = SMAppService.mainApp.status == .enabled
            error = nil
        } catch {
            enabled = SMAppService.mainApp.status == .enabled
            self.error = "Launch at Login: \(error.localizedDescription)"
        }
    }
}

enum Permissions {
    static var inputAllowed: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    static var accessibilityAllowed: Bool { AXIsProcessTrusted() }

    static func requestInputMonitoringIfNeeded() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }
}

final class MappingStore: ObservableObject {
    struct Item {
        let code: String
        let name: String
    }

    static let editableKeys = [
        Item(code: "0x52", name: "Up"),
        Item(code: "0x51", name: "Down"),
        Item(code: "0x50", name: "Left"),
        Item(code: "0x4F", name: "Right"),
        Item(code: "0x28", name: "OK"),
        Item(code: "0xF1", name: "Back"),
        Item(code: "0x3E.short", name: "Home (short)"),
        Item(code: "0x3E.long", name: "Home (long)"),
        Item(code: "0x80", name: "Volume +"),
        Item(code: "0x81", name: "Volume −")
    ]

    private static let defaults = [
        "0x52": "up",
        "0x51": "down",
        "0x50": "escape",
        "0x4F": "tab",
        "0x28": "return",
        "0xF1": "shift+tab",
        "0x3E.short": "app-switcher",
        "0x3E.long": "dictation",
        "0x80": "command+]",
        "0x81": "command+[",
        "0x65": "fn",
        "0x66": "ignore"
    ]

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "mappingEnabled") }
    }
    @Published private(set) var mappings: [String: String]
    @Published var pendingPreset: Preset?
    @Published private(set) var saveGeneration = 0

    let configURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let support = base.appendingPathComponent("VibeRemote", isDirectory: true)
        configURL = support.appendingPathComponent("mapping.json")
        let oldConfig = base.appendingPathComponent("HID Event Monitor/mapping.json")
        if !FileManager.default.fileExists(atPath: configURL.path),
           FileManager.default.fileExists(atPath: oldConfig.path) {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: oldConfig, to: configURL)
        }

        if let saved = UserDefaults.standard.object(forKey: "mappingEnabled") as? Bool {
            enabled = saved
        } else {
            enabled = UserDefaults(suiteName: "com.example.HIDEventMonitor")?.object(forKey: "mappingEnabled") as? Bool ?? true
        }
        mappings = Self.defaults

        if let data = try? Data(contentsOf: configURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            mappings.merge(saved) { _, savedValue in savedValue }
            if mappings["0x3E.short"] == "command+tab" {
                mappings["0x3E.short"] = "app-switcher"
                save()
            }
            if mappings["0x65"] == "ignore" {
                mappings["0x65"] = "fn"
                save()
            }
        } else {
            save()
        }
    }

    func set(_ shortcut: String, for code: String) {
        mappings[code] = shortcut
        objectWillChange.send()
        save()
        saveGeneration += 1
    }

    func chooseApp(for code: String) {
        let panel = NSOpenPanel()
        panel.title = "选择要打开的 App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
        set("app:\(bundleID)|\(url.path)", for: code)
    }

    func apply(_ preset: Preset) {
        var values = Self.defaults
        switch preset {
        case .chatGPT: values["0x3E.double"] = "open:chatgpt"
        case .codex: values["0x3E.double"] = "open:codex"
        case .cursor: values["0x3E.double"] = "open:cursor"
        case .claude: values["0x3E.double"] = "open:claude"
        case .coding: break
        case .media:
            values.merge(["0x52": "volume-up", "0x51": "volume-down", "0x28": "play-pause", "0x50": "previous-track", "0x4F": "next-track", "0x80": "volume-up", "0x81": "volume-down"]) { _, new in new }
        case .defaults: break
        }
        mappings = values
        pendingPreset = nil
        save()
        saveGeneration += 1
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.pretty.encode(mappings)
            try data.write(to: configURL, options: .atomic)
        } catch {
            print("Mapping config save failed: \(error.localizedDescription)")
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: String

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onShortcut = { shortcut = $0 }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.onShortcut = { shortcut = $0 }
    }
}

final class RecorderView: NSView {
    var onShortcut: ((String) -> Void)?
    var shortcut = "ignore" { didSet { updateLabel() } }
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        label.alignment = .center
        addSubview(label)
        updateLabel()
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 6, dy: 4)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        label.stringValue = "Press shortcut…"
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func keyDown(with event: NSEvent) {
        guard let name = Shortcut.keyName(for: event.keyCode) else {
            NSSound.beep()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("control") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("command") }
        parts.append(name)
        shortcut = parts.joined(separator: "+")
        onShortcut?(shortcut)
        window?.makeFirstResponder(nil)
        updateLabel()
    }

    override func resignFirstResponder() -> Bool {
        layer?.borderColor = NSColor.separatorColor.cgColor
        updateLabel()
        return super.resignFirstResponder()
    }

    private func updateLabel() {
        label.stringValue = Shortcut.display(shortcut)
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

struct Shortcut {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    static func parse(_ text: String) -> Shortcut? {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, let code = keyCodes[key] else { return nil }
        var flags: CGEventFlags = []
        if parts.contains("command") { flags.insert(.maskCommand) }
        if parts.contains("shift") { flags.insert(.maskShift) }
        if parts.contains("option") { flags.insert(.maskAlternate) }
        if parts.contains("control") { flags.insert(.maskControl) }
        if parts.contains("fn") { flags.insert(.maskSecondaryFn) }
        return Shortcut(keyCode: code, flags: flags)
    }

    static func display(_ text: String) -> String {
        if text == "dictation" { return "Dictation" }
        if text == "ignore" { return "Ignored" }
        return text.split(separator: "+").map {
            switch $0.lowercased() {
            case "command": return "⌘"
            case "shift": return "⇧"
            case "option": return "⌥"
            case "control": return "⌃"
            case "return": return "↩"
            case "tab": return "⇥"
            case "escape": return "Esc"
            case "up": return "↑"
            case "down": return "↓"
            case "left": return "←"
            case "right": return "→"
            case "space": return "Space"
            default: return String($0).uppercased()
            }
        }.joined()
    }

    static func keyName(for keyCode: UInt16) -> String? {
        keyCodes.first(where: { $0.value == keyCode })?.key
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "space": 49, "escape": 53,
        "delete": 51, "f11": 103,
        "[": 33, "]": 30,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47
    ]
}

enum InputFocuser {
    /// 切换到目标 App 后，把键盘焦点放到它窗口里的第一个文本输入框，
    /// 这样听写产生的文字会直接写入该输入框。
    static func focusTextInput(bundleIdentifier: String, attempts: Int = 4) {
        tryFocus(bundleIdentifier: bundleIdentifier, remaining: attempts)
    }

    private static func tryFocus(bundleIdentifier: String, remaining: Int) {
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard AXIsProcessTrusted() else {
                EventOverlay.shared.show(remote: "自动聚焦", action: "需要辅助功能权限", isError: true)
                return
            }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier else {
                tryFocus(bundleIdentifier: bundleIdentifier, remaining: remaining - 1)
                return
            }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            // Electron/Chromium 应用默认不构建辅助功能树，需要显式打开。
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            if focusedElementIsTextInput(axApp) { return }
            var windowValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
                  let window = windowValue, CFGetTypeID(window) == AXUIElementGetTypeID() else {
                tryFocus(bundleIdentifier: bundleIdentifier, remaining: remaining - 1)
                return
            }
            if let input = findTextInput(in: unsafeDowncast(window as AnyObject, to: AXUIElement.self)) {
                AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                // 网页输入框（contenteditable）设 AXFocused 常不生效，再补一次真实点击。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !focusedElementIsTextInput(axApp) { click(input) }
                }
            } else {
                tryFocus(bundleIdentifier: bundleIdentifier, remaining: remaining - 1)
            }
        }
    }

    private static func click(_ element: AXUIElement) {
        var posValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else { return }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(unsafeDowncast(posValue as AnyObject, to: AXValue.self), .cgPoint, &pos)
        AXValueGetValue(unsafeDowncast(sizeValue as AnyObject, to: AXValue.self), .cgSize, &size)
        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func focusedElementIsTextInput(_ axApp: AXUIElement) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        return isTextInput(unsafeDowncast(element as AnyObject, to: AXUIElement.self))
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return false }
        if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String { return true }
        // Electron/网页应用里输入框常是 contenteditable，角色可能不是标准值，
        // 用“可设置 AXValue 的可编辑元素”兜底。
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue && role != kAXCheckBoxRole as String
    }

    private static func findTextInput(in root: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            let element = queue.removeFirst()
            visited += 1
            if isTextInput(element) { return element }
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else { continue }
            queue.append(contentsOf: children)
        }
        return nil
    }
}

enum ShortcutSender {
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func send(_ value: String) {
        guard let shortcut = Shortcut.parse(value) else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false)
        down?.flags = shortcut.flags
        up?.flags = shortcut.flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func perform(_ value: String) {
        if value == "dictation" { startDictation(); return }
        if value == "fn" { startDictation(); return }
        if value.hasPrefix("open:") || value.hasPrefix("app:") { AppLocator.open(value); return }
        if value.hasPrefix("applescript:") {
            guard let source = decodePayload(value) else { return }
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            return
        }
        if value.hasPrefix("shell:") {
            guard let script = decodePayload(value) else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", script]
            try? process.run()
            return
        }
        switch value {
        case "volume-up": mediaKey(NX_KEYTYPE_SOUND_UP)
        case "volume-down": mediaKey(NX_KEYTYPE_SOUND_DOWN)
        case "mute": mediaKey(NX_KEYTYPE_MUTE)
        case "play-pause": mediaKey(NX_KEYTYPE_PLAY)
        case "next-track": mediaKey(NX_KEYTYPE_NEXT)
        case "previous-track": mediaKey(NX_KEYTYPE_PREVIOUS)
        default: send(value)
        }
    }

    private static func decodePayload(_ value: String) -> String? {
        guard let encoded = value.split(separator: ":", maxSplits: 1).last,
              let data = Data(base64Encoded: String(encoded)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func mediaKey(_ key: Int32) {
        for state in [0xA, 0xB] {
            let data1 = Int((key << 16) | Int32(state << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func startDictation() {
        VisualFeedback.shared.dictationActive.toggle()
        sendFunctionKey()
    }

    private static func sendFunctionKey() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: false)
        down?.flags = .maskSecondaryFn
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

final class VisualFeedback: ObservableObject {
    static let shared = VisualFeedback()
    @Published var dictationActive = false
}

enum AppLocator {
    private static let known: [String: ([String], [String])] = [
        "chatgpt": (["com.openai.chat"], ["ChatGPT.app"]),
        "codex": (["com.openai.codex"], ["Codex.app"]),
        "cursor": (["com.todesktop.230313mzl4w4u92"], ["Cursor.app"]),
        "claude": (["com.anthropic.claudefordesktop"], ["Claude.app", "Claude Code.app"])
    ]

    static func url(for value: String) -> URL? {
        if value.hasPrefix("app:") {
            let path = value.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init)
            return path.map(URL.init(fileURLWithPath:))
        }
        let name = String(value.dropFirst("open:".count))
        guard let (bundleIDs, appNames) = known[name] else { return nil }
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        for app in appNames {
            let url = URL(fileURLWithPath: "/Applications").appendingPathComponent(app)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func open(_ value: String) {
        guard let url = url(for: value) else {
            EventOverlay.shared.show(remote: "应用", action: "未找到该 App", isError: true)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

final class EventOverlay {
    static let shared = EventOverlay()
    private var panel: NSPanel?
    private var generation = 0

    func show(remote: String, action: String, isError: Bool = false) {
        generation += 1
        let current = generation
        panel?.close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:
            VStack(spacing: 3) {
                Text("Remote:").font(.caption)
                Text(remote).font(.headline)
                Text("↓").foregroundStyle(.secondary)
                Text(action).font(.headline)
            }
            .frame(width: 220, height: 110)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        )
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 240, y: frame.maxY - 130))
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
            if isError, let origin = panel.screen?.visibleFrame {
                let targetX = origin.maxX - 240
                for (delay, x) in [(0.05, targetX - 5), (0.10, targetX + 5), (0.15, targetX)] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { panel.setFrameOrigin(NSPoint(x: x, y: panel.frame.origin.y)) }
                }
            }
        }
        self.panel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard self?.generation == current else { return }
            guard let panel = self?.panel else { return }
            if reduceMotion {
                panel.close()
                self?.panel = nil
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    guard self?.generation == current else { return }
                    panel.close()
                    self?.panel = nil
                }
            }
        }
    }
}

struct HIDEvent {
    var usagePage = ""
    var usage = ""
    var integerValue = ""
    var reportID = ""
    var hexData = ""
    var time = ""
}

final class HIDMonitor: ObservableObject {
    @Published var connected = false
    @Published var latest = HIDEvent()
    @Published var log = ""
    @Published var visualPressedCode: String?

    let mappingStore: MappingStore
    let appSwitcher: AppSwitcherStore
    private var logEntries: [String] = []

    private var manager: IOHIDManager?
    private var managerProvidesInput = false
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
    private var matchedDevices = Set<ObjectIdentifier>()
    private let vendorID = 0x2717
    private let productID = 0x32b0
    private let productName = "小米语音遥控器"
    private var pressedCode: UInt8?
    private var pressedAt: Date?
    private var pendingSingles: [UInt8: DispatchWorkItem] = [:]
    private var lastMappedReport = Data()
    private var lastMappedAt = Date.distantPast

    init(mappingStore: MappingStore, appSwitcher: AppSwitcherStore) {
        self.mappingStore = mappingStore
        self.appSwitcher = appSwitcher
#if DEBUG
        assert(Self.renderLog(["old", "new"], limit: 1) == "new")
#endif
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let context = Unmanaged.passUnretained(self).toOpaque()
        append("IOHIDManagerCreate: OK")

        let matching: NSArray = [[
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        append("IOHIDManagerSetDeviceMatchingMultiple: OK (VendorID=0x2717, ProductID=0x32B0)")
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceAdded, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, Self.inputValue, context)
        IOHIDManagerRegisterInputReportCallback(manager, Self.inputReport, context)
        append("IOHIDManagerRegisterInputValueCallback: registered (void API, no IOReturn)")
        append("IOHIDManagerRegisterInputReportCallback: registered (void API, no IOReturn)")
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        append("IOHIDManagerScheduleWithRunLoop: OK (void API, no IOReturn)")

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        managerProvidesInput = result == kIOReturnSuccess
        append("IOHIDManagerOpen: \(describe(result))")
        if result != kIOReturnSuccess { append("Manager open failed; using direct IOHIDDevice callbacks") }
    }

    func clearLog() {
        logEntries.removeAll()
        log = ""
    }

    func previewPress(_ code: String) {
        visualPressedCode = code
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            if self?.visualPressedCode == code { self?.visualPressedCode = nil }
        }
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logEntries.joined(separator: "\n"), forType: .string)
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hid-events.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.logEntries.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.append("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func add(_ device: IOHIDDevice) {
        let vendor = property(device, kIOHIDVendorIDKey) ?? -1
        let product = property(device, kIOHIDProductIDKey) ?? -1
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        guard vendor == vendorID, product == productID, name == productName else { return }
        guard matchedDevices.insert(ObjectIdentifier(device)).inserted else { return }

        connected = true
        append("Connected Xiaomi Remote")
        guard !managerProvidesInput else {
            append("Using IOHIDManager input callbacks; direct device callbacks not needed")
            return
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        reportBuffers.append(buffer)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, Self.deviceInputValue, context)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 4096, Self.deviceInputReport, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        append("IOHIDDeviceRegisterInputValueCallback: registered (void API, no IOReturn)")
        append("IOHIDDeviceRegisterInputReportCallback: registered (void API, no IOReturn)")
        append("IOHIDDeviceScheduleWithRunLoop: OK (void API, no IOReturn)")
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        append("IOHIDDeviceOpen: \(describe(result))")
    }

    private func accepts(_ sender: UnsafeMutableRawPointer?) -> Bool {
        guard let sender else { return false }
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        return matchedDevices.contains(ObjectIdentifier(device))
    }

    private func property(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private func describe(_ result: IOReturn) -> String {
        let code = String(format: "0x%08X", UInt32(bitPattern: result))
        let reason: String
        switch result {
        case kIOReturnSuccess: reason = "success"
        case kIOReturnNotPermitted: reason = "not permitted (permission or device access policy)"
        case kIOReturnExclusiveAccess: reason = "exclusive access (another client owns the device)"
        case kIOReturnNoDevice: reason = "no device"
        case kIOReturnNotOpen: reason = "not open"
        case kIOReturnBadArgument: reason = "bad argument"
        default: reason = "unknown IOKit return code"
        }
        return "\(code) - \(reason)"
    }

    private func append(_ text: String) {
        print(text)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.addLogEntry(text)
        }
    }

    private func addLogEntry(_ text: String) {
        logEntries.append(text)
        log = Self.renderLog(logEntries, limit: 400)
    }

    private static func renderLog(_ entries: [String], limit: Int) -> String {
        entries.suffix(limit).joined(separator: "\n")
    }

    private static let deviceAdded: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().add(device)
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
        guard monitor.matchedDevices.remove(ObjectIdentifier(device)) != nil else { return }
        monitor.connected = !monitor.matchedDevices.isEmpty
        monitor.append("Disconnected Xiaomi Remote")
    }

    private static let inputValue: IOHIDValueCallback = { context, _, sender, value in
        guard let context else { return }
        let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
        guard monitor.accepts(sender) else { return }
        monitor.handleValue(value)
    }

    private static let deviceInputValue: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().handleValue(value)
    }

    private func handleValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let bytes = Data(bytes: IOHIDValueGetBytePtr(value), count: IOHIDValueGetLength(value))
        let event = HIDEvent(
            usagePage: String(IOHIDElementGetUsagePage(element)),
            usage: String(IOHIDElementGetUsage(element)),
            integerValue: String(IOHIDValueGetIntegerValue(value)),
            reportID: String(IOHIDElementGetReportID(element)),
            hexData: bytes.hex,
            time: DateFormatter.hidTime.string(from: Date())
        )
        record(event, source: "Value")
    }

    private static let inputReport: IOHIDReportCallback = { context, _, sender, _, reportID, report, length in
        guard let context else { return }
        let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
        guard monitor.accepts(sender) else { return }
        monitor.handleReport(reportID: reportID, report: report, length: length)
    }

    private static let deviceInputReport: IOHIDReportCallback = { context, _, _, _, reportID, report, length in
        guard let context else { return }
        Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().handleReport(reportID: reportID, report: report, length: length)
    }

    private func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let bytes = Data(bytes: report, count: length)
        record(HIDEvent(reportID: String(reportID), hexData: bytes.hex, time: DateFormatter.hidTime.string(from: Date())), source: "Report")
        processMapping(bytes)
    }

    private func processMapping(_ bytes: Data) {
        guard mappingStore.enabled, bytes.count > 3 else { return }

        let now = Date()
        if bytes == lastMappedReport, now.timeIntervalSince(lastMappedAt) < 0.05 { return }
        lastMappedReport = bytes
        lastMappedAt = now

        let code = bytes[3]
        if code != 0 { previewPress(String(format: "0x%02X", code)) }
        if AppSwitcherController.shared.isVisible {
            switch code {
            case 0x52, 0x50: AppSwitcherController.shared.move(-1)
            case 0x51, 0x4F: AppSwitcherController.shared.move(1)
            case 0x28, 0x3E: AppSwitcherController.shared.confirm()
            case 0xF1: AppSwitcherController.shared.close()
            default: break
            }
            return
        }
        if code == 0 {
            guard let releasedCode = pressedCode, let pressedAt else { return }
            self.pressedCode = nil
            self.pressedAt = nil
            let duration = now.timeIntervalSince(pressedAt)
            let base = String(format: "0x%02X", releasedCode)
            let remote = remoteName(releasedCode)
            if duration > 0.7, isConfigured(base + ".long") {
                performMapping(code: base + ".long", remote: "\(remote)（长按）")
            } else if releasedCode == 0x3E, duration >= 0.5 {
                return
            } else {
                finishClick(code: releasedCode, base: base, remote: remote)
            }
            return
        }

        let key = String(format: "0x%02X", code)
        guard RemoteKey(rawValue: key) != nil else { return }
        let hasGesture = code == 0x3E || isConfigured(key + ".long") || isConfigured(key + ".double")
        if hasGesture {
            pressedCode = code
            pressedAt = now
        } else {
            performMapping(code: key, remote: remoteName(code))
        }
    }

    private func finishClick(code: UInt8, base: String, remote: String) {
        let shortKey = code == 0x3E ? base + ".short" : base
        let doubleKey = base + ".double"
        guard isConfigured(doubleKey) else {
            performMapping(code: shortKey, remote: remote)
            return
        }
        if let pending = pendingSingles.removeValue(forKey: code) {
            pending.cancel()
            performMapping(code: doubleKey, remote: "\(remote)（双击）")
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSingles.removeValue(forKey: code)
            self?.performMapping(code: shortKey, remote: remote)
        }
        pendingSingles[code] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func isConfigured(_ code: String) -> Bool {
        guard let value = mappingStore.mappings[code] else { return false }
        return value != "ignore"
    }

    private func remoteName(_ code: UInt8) -> String {
        let names: [UInt8: String] = [
            0x52: "上", 0x51: "下", 0x50: "左", 0x4F: "右", 0x28: "确认",
            0xF1: "返回", 0x3E: "HOME", 0x80: "音量+", 0x81: "音量−",
            0x65: "菜单", 0x66: "电源"
        ]
        return names[code] ?? String(format: "0x%02X", code)
    }

    private func performMapping(code: String, remote: String) {
        guard let action = mappingStore.mappings[code], action != "ignore" else { return }
        if action == "app-switcher" {
            AppSwitcherController.shared.show(store: appSwitcher)
            append("[Mapping] \(remote) → 应用切换器")
            return
        }
        ShortcutSender.perform(action)
        let title = FunctionAction.find(action).title
        EventOverlay.shared.show(remote: remote, action: title)
        append("[Mapping] \(remote) → \(title)")
    }

    private func record(_ event: HIDEvent, source: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = event
            self.addLogEntry("[\(source)] \(event.time)\nUsage Page: \(event.usagePage)\nUsage: \(event.usage)\nInteger Value: \(event.integerValue)\nReport ID: \(event.reportID)\nHex Data: \(event.hexData)")
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

private extension DateFormatter {
    static let hidTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

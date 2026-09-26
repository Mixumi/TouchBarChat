import AppKit
import CoreGraphics
import ScreenCaptureKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let touchBarChatCommitRecordDrafts = Notification.Name("TouchBarChatCommitRecordDrafts")
}

@MainActor
enum InterviewRunState {
    case idle
    case starting
    case running
    case finishing
    case paused
}

private enum AppearanceChoice: String {
    case system
    case light
    case dark

    var windowAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Owns the ordinary, resizable application window. The menu-bar and Touch Bar
/// surfaces are controlled by AppDelegate; neither is required to use this UI.
@MainActor
final class AppUIController: NSWindowController {
    var onStart: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?

    private let presentation = AppWindowPresentation()
    private var titlebarControls: NSTitlebarAccessoryViewController?

    init(store: InterviewStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TouchBarChat"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let savedAppearance = UserDefaults.standard.string(forKey: "touchbarchat.appearance") ?? "system"
        window.appearance = (AppearanceChoice(rawValue: savedAppearance) ?? .system).windowAppearance
        // Match the SwiftUI root view's *content* minimum. NSWindow.minSize
        // includes the title bar and can clip the onboarding footer at 620 pt.
        window.contentMinSize = NSSize(width: 920, height: 620)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: AppRootView(store: store, presentation: presentation)
        )
        super.init(window: window)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let controls = NSHostingView(rootView: TitlebarInterviewControls(presentation: presentation))
        controls.frame = NSRect(x: 0, y: 0, width: 148, height: 42)
        accessory.view = controls
        window.addTitlebarAccessoryViewController(accessory)
        titlebarControls = accessory
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )

        presentation.onStart = { [weak self] in self?.onStart?() }
        presentation.onPause = { [weak self] in self?.onPause?() }
        presentation.onResume = { [weak self] in self?.onResume?() }
        presentation.onStop = { [weak self] in self?.onStop?() }
        presentation.onAppearanceChange = { [weak self] rawValue in
            self?.window?.appearance = (AppearanceChoice(rawValue: rawValue) ?? .system).windowAppearance
        }
    }

    required init?(coder: NSCoder) {
        fatalError("AppUIController is constructed in code")
    }

    @objc private func windowWillClose(_ notification: Notification) {
        commitRecordDrafts()
    }

    func commitRecordDrafts() {
        NotificationCenter.default.post(name: .touchBarChatCommitRecordDrafts, object: nil)
    }

    func showInitialWindow() {
        presentation.showsOnboarding = !UserDefaults.standard.bool(
            forKey: AppWindowPresentation.onboardingCompletedKey
        )
        presentWindow()
    }

    func showMainWindow() {
        presentation.showsOnboarding = !UserDefaults.standard.bool(
            forKey: AppWindowPresentation.onboardingCompletedKey
        )
        presentWindow()
    }

    func minimizeForInterview() {
        window?.miniaturize(nil)
    }

    func updateRunState(_ state: InterviewRunState, message: String) {
        presentation.runState = state
        presentation.statusMessage = message
        if case .running = state {
            presentation.errorMessage = nil
        }
    }

    func showError(_ message: String) {
        presentation.errorMessage = message
        presentWindow()
    }

    private func presentWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class AppWindowPresentation: ObservableObject {
    static let onboardingCompletedKey = "touchbarchat.onboardingCompleted"

    @Published var showsOnboarding = false
    @Published var runState: InterviewRunState = .idle
    @Published var statusMessage = L10n.text("准备就绪")
    @Published var errorMessage: String?

    var onStart: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?
    var onAppearanceChange: ((String) -> Void)?

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        showsOnboarding = false
    }
}

@MainActor
private struct TitlebarInterviewControls: View {
    @ObservedObject var presentation: AppWindowPresentation

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if !presentation.showsOnboarding {
                switch presentation.runState {
                case .idle:
                    primaryIconButton("开启面试", symbol: "play.fill") {
                        NotificationCenter.default.post(name: .touchBarChatCommitRecordDrafts, object: nil)
                        presentation.errorMessage = nil
                        presentation.onStart?()
                    }
                case .starting:
                    ProgressView()
                        .controlSize(.small)
                        .help(L10n.text("正在开启面试"))
                        .accessibilityLabel(L10n.text("正在开启面试"))
                case .running:
                    secondaryIconButton("暂停面试", symbol: "pause.fill") {
                        presentation.onPause?()
                    }
                    secondaryIconButton("结束面试", symbol: "stop.fill", destructive: true) {
                        presentation.onStop?()
                    }
                case .finishing:
                    ProgressView()
                        .controlSize(.small)
                        .help(L10n.text("正在保存最后一句"))
                        .accessibilityLabel(L10n.text("正在保存最后一句"))
                case .paused:
                    primaryIconButton("继续面试", symbol: "play.fill") {
                        presentation.onResume?()
                    }
                    secondaryIconButton("结束面试", symbol: "stop.fill", destructive: true) {
                        presentation.onStop?()
                    }
                }
            }
        }
        .padding(.trailing, 14)
        .frame(width: 148, height: 42)
    }

    private func primaryIconButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(TouchBarChatPrimaryButton())
        .help(L10n.text(title))
        .accessibilityLabel(L10n.text(title))
    }

    private func secondaryIconButton(
        _ title: String,
        symbol: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(destructive ? .red : TouchBarChatStyle.accent)
        .help(L10n.text(title))
        .accessibilityLabel(L10n.text(title))
    }
}

@MainActor
private struct AppRootView: View {
    @ObservedObject var store: InterviewStore
    @ObservedObject var presentation: AppWindowPresentation
    @StateObject private var appLanguage = AppLanguageSettings.shared
    @AppStorage("touchbarchat.appearance") private var appearance = "system"

    var body: some View {
        Group {
            if presentation.showsOnboarding {
                OnboardingView(presentation: presentation)
            } else {
                MainWorkspaceView(store: store, presentation: presentation)
            }
        }
        .tint(TouchBarChatStyle.accent)
        .environment(
            \.locale,
            appLanguage.selection == AppLanguageSettings.systemCode
                ? L10n.locale
                : Locale(identifier: appLanguage.selection)
        )
        .frame(minWidth: 920, minHeight: 620)
        .onAppear { presentation.onAppearanceChange?(appearance) }
        .onChange(of: appearance) { newValue in
            presentation.onAppearanceChange?(newValue)
        }
    }
}

private enum MainDestination: String, Hashable {
    case records
    case settings
}

@MainActor
private struct MainWorkspaceView: View {
    @ObservedObject var store: InterviewStore
    @ObservedObject var presentation: AppWindowPresentation
    @StateObject private var settingsAPIForm = APISettingsFormModel()
    @State private var destination: MainDestination? = .records
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var recordDetailExpanded = false

    private var isInterviewActive: Bool {
        switch presentation.runState {
        case .idle: return false
        case .starting, .running, .finishing, .paused: return true
        }
    }

    private var showsStatusStrip: Bool {
        isInterviewActive
            || presentation.errorMessage != nil
            || store.persistenceError != nil
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "waveform")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(TouchBarChatStyle.accent)
                        .frame(width: 48, height: 48)
                        .background(TouchBarChatStyle.accentWash, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("TouchBarChat")
                            .font(.system(size: 16, weight: .semibold))
                        Text(L10n.text("面试工作区"))
                            .font(.system(size: 13))
                            .foregroundStyle(TouchBarChatStyle.secondaryText)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 30)
                .padding(.bottom, 48)

                VStack(spacing: 8) {
                    navigationItem(.records, title: "面试记录", symbol: "text.book.closed")
                    navigationItem(.settings, title: "设置", symbol: "gearshape")
                }
                .padding(.horizontal, 12)

                Spacer(minLength: 12)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                    Text(L10n.text("记录文字仅保存在本机"))
                        .font(.caption)
                }
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .padding(.horizontal, 25)
                .padding(.bottom, 24)
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 250)
            .background(TouchBarChatStyle.sidebar)
        } detail: {
            VStack(spacing: 0) {
                if showsStatusStrip {
                    runToolbar
                    TouchBarChatStyle.border.frame(height: 1)
                }
                if destination == .settings {
                    SettingsPage(
                        runState: presentation.runState,
                        apiForm: settingsAPIForm,
                        onShowOnboarding: { presentation.showsOnboarding = true }
                    )
                } else {
                    RecordsPage(
                        store: store,
                        isInterviewActive: isInterviewActive,
                        isDetailExpanded: $recordDetailExpanded
                    )
                }
            }
            .frame(minWidth: 680)
            .background(TouchBarChatStyle.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: recordDetailExpanded) { expanded in
            columnVisibility = expanded ? .detailOnly : .all
        }
        .onChange(of: destination) { _ in
            if recordDetailExpanded { recordDetailExpanded = false }
        }
        .onChange(of: columnVisibility) { visibility in
            if visibility == .all && recordDetailExpanded {
                recordDetailExpanded = false
            }
        }
    }

    private func navigationItem(
        _ item: MainDestination,
        title: String,
        symbol: String
    ) -> some View {
        let selected = destination == item
        return Button {
            destination = item
        } label: {
            Label(L10n.text(title), systemImage: symbol)
                .font(.system(size: 15, weight: selected ? .semibold : .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 17)
                .frame(height: 46)
                .background(
                    selected ? TouchBarChatStyle.raisedSurface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            selected ? TouchBarChatStyle.border : Color.clear,
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var runToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .semibold))
                    if !presentation.statusMessage.isEmpty {
                        Text(presentation.statusMessage)
                            .font(.caption)
                            .foregroundStyle(TouchBarChatStyle.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
            }
            if let error = presentation.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .foregroundStyle(Color.orange)
                .padding(12)
                .background(TouchBarChatStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityAddTraits(.updatesFrequently)
            }
            if let persistenceError = store.persistenceError {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(persistenceError)
                            .font(.callout.weight(.medium))
                        Text(
                            L10n.text(
                                store.canRetryPersistence
                                    ? "当前文字仍在内存中；请检查磁盘后重试，暂勿退出应用。"
                                    : "原始记录文件已保留，应用不会用空记录覆盖它。")
                        )
                        .font(.caption)
                        .foregroundStyle(TouchBarChatStyle.secondaryText)
                    }
                    Spacer(minLength: 0)
                    if store.canRetryPersistence {
                        Button(L10n.text("重试保存")) {
                            store.flush()
                            if store.persistenceError == nil { presentation.errorMessage = nil }
                        }
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(TouchBarChatStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 17)
        .background(TouchBarChatStyle.canvas)
    }

    private var statusTitle: String {
        switch presentation.runState {
        case .idle: return L10n.text("准备好时开始面试")
        case .starting: return L10n.text("正在开启")
        case .running: return L10n.text("面试进行中")
        case .finishing: return L10n.text("正在保存转写")
        case .paused: return L10n.text("已暂停")
        }
    }

    private var statusColor: Color {
        switch presentation.runState {
        case .idle, .starting, .finishing: return .secondary
        case .running: return .red
        case .paused: return .orange
        }
    }
}

private enum OnboardingStep: Int, Hashable {
    case permissions = 1
    case api = 2
    case preferences = 3
    case welcome = 4
}

private enum OnboardingPalette {
    // Keep the approved dark onboarding design; supply a matching light set.
    static let left = TouchBarChatStyle.adaptive("onboarding-left", light: 0xF1F1F4, dark: 0x1D1D23)
    static let right = TouchBarChatStyle.adaptive("onboarding-right", light: 0xFAFAFB, dark: 0x1B1B1F)
    static let panel = TouchBarChatStyle.adaptive("onboarding-panel", light: 0xFFFFFF, dark: 0x25252B)
    static let border = TouchBarChatStyle.adaptive("onboarding-border", light: 0xE3E3E9, dark: 0x3D3D45)
    static let text = TouchBarChatStyle.adaptive("onboarding-text", light: 0x202027, dark: 0xF5F2FA)
    static let muted = TouchBarChatStyle.adaptive("onboarding-muted", light: 0x60606C, dark: 0xABABB8)
    static let accent = TouchBarChatStyle.adaptive("onboarding-accent", light: 0x7044CC, dark: 0xBA91FA)
}

/// A quiet, scalable version of the selected waveform artwork, drawn by the
/// native view system so it stays sharp at every Mac window size.
private struct OnboardingWaveLine: Shape {
    let offset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY + offset
        path.move(to: CGPoint(x: rect.minX, y: midY + 13))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.33, y: midY - 46),
            control1: CGPoint(x: rect.width * 0.15, y: midY + 88),
            control2: CGPoint(x: rect.width * 0.23, y: midY - 128)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.72, y: midY + 31),
            control1: CGPoint(x: rect.width * 0.49, y: midY + 105),
            control2: CGPoint(x: rect.width * 0.59, y: midY + 135)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: midY - 9),
            control1: CGPoint(x: rect.width * 0.86, y: midY - 76),
            control2: CGPoint(x: rect.width * 0.92, y: midY - 33)
        )
        return path
    }
}

// MARK: - First-run setup

/// Keeps permission, API, and profile setup in one resumable flow. Finishing
/// onboarding only changes the UI flag; it does not start audio capture.
@MainActor
private struct OnboardingView: View {
    @ObservedObject var presentation: AppWindowPresentation
    @State private var step: OnboardingStep = .permissions
    @State private var welcomeBackStep: OnboardingStep = .preferences
    @State private var skippedSteps: Set<OnboardingStep> = []
    @StateObject private var apiForm = APISettingsFormModel()
    @StateObject private var permissions = PermissionStatusModel()
    @StateObject private var languageSettings = InterviewLanguageSettings.shared

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                brandPanel
                    .frame(width: min(390, max(300, geometry.size.width * 0.32)))
                    .background(OnboardingPalette.left)

                OnboardingPalette.border.frame(width: 1)

                VStack(spacing: 0) {
                    topHeader

                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            heading
                            stepContent
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.horizontal, 34)
                        .padding(.top, 26)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    OnboardingPalette.border.frame(height: 1)
                    navigationFooter
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OnboardingPalette.right)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(OnboardingPalette.right)
        .foregroundStyle(OnboardingPalette.text)
        .tint(OnboardingPalette.accent)
    }

    private var brandPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 78)

            ZStack {
                OnboardingWaveLine(offset: -5)
                    .stroke(OnboardingPalette.accent.opacity(0.92), lineWidth: 1.35)
                OnboardingWaveLine(offset: 26)
                    .stroke(OnboardingPalette.accent.opacity(0.44), lineWidth: 1)
                OnboardingWaveLine(offset: 53)
                    .stroke(OnboardingPalette.accent.opacity(0.23), lineWidth: 1)
            }
            .frame(height: 200)
            .padding(.leading, -44)
            .padding(.trailing, -26)
            .accessibilityHidden(true)

            Spacer(minLength: 44)

            Text(L10n.text("从声音到思路"))
                .font(.system(size: 29, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(OnboardingPalette.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.text("让电脑里的声音，成为你的思考起点。"))
                .font(.system(size: 13))
                .foregroundStyle(OnboardingPalette.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 42)
        .padding(.trailing, 27)
        .padding(.bottom, 54)
    }

    private var topHeader: some View {
        VStack(spacing: 16) {
            Text("TouchBarChat")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardingPalette.muted)

            HStack(spacing: 12) {
                progressItem(.permissions, title: "权限")
                OnboardingPalette.border.frame(width: 20, height: 1)
                progressItem(.api, title: "AI 接口")
                OnboardingPalette.border.frame(width: 20, height: 1)
                progressItem(.preferences, title: "回答偏好")
                OnboardingPalette.border.frame(width: 20, height: 1)
                progressItem(.welcome, title: "欢迎")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 17)
        .padding(.bottom, 11)
    }

    private func progressItem(_ item: OnboardingStep, title: String) -> some View {
        let isCurrent = step == item
        let isComplete = item.rawValue < step.rawValue && !skippedSteps.contains(item)
        return HStack(spacing: 8) {
            Circle()
                .fill(isCurrent || isComplete ? OnboardingPalette.accent : Color.clear)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle().strokeBorder(
                        isCurrent || isComplete ? OnboardingPalette.accent : OnboardingPalette.muted, lineWidth: 1)
                }
            Text(String(format: "%02d", item.rawValue) + " " + L10n.text(title))
                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? OnboardingPalette.accent : OnboardingPalette.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stepTitle)
                .font(.system(size: 31, weight: .semibold))
                .foregroundStyle(OnboardingPalette.text)

            Text(stepSubtitle)
                .font(.system(size: 14))
                .foregroundStyle(OnboardingPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepTitle: String {
        switch step {
        case .permissions: return L10n.text("准备开始")
        case .api: return L10n.text("连接 AI 回答服务")
        case .preferences: return L10n.text("让回答更贴合你")
        case .welcome: return L10n.text("一切就绪，开始吧")
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .permissions:
            return L10n.text("为获得更好的体验，请先完成以下权限设置。")
        case .api:
            return L10n.text("填写兼容 Chat Completions 的接口信息；暂时不需要 AI 回答，也可以跳过。")
        case .preferences:
            return L10n.text("可选：写下你的经历与回答偏好。面试结束后仍可在设置中修改。")
        case .welcome:
            return L10n.text("TouchBarChat 已经准备好。先熟悉一下开始面试后会发生什么。")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .permissions:
            permissionStep
        case .api:
            apiStep
        case .preferences:
            preferencesStep
        case .welcome:
            welcomeStep
        }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("面试官使用的语言"))
                    .font(.system(size: 13, weight: .semibold))
                Picker(
                    L10n.text("面试官使用的语言"),
                    selection: Binding(
                        get: { languageSettings.selectedLanguage },
                        set: { languageSettings.select($0) }
                    )
                ) {
                    ForEach(InterviewLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                Text(L10n.text("转写模型和提问结束判断将使用这个语言；面试开始后不能更改。"))
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingPalette.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnboardingPalette.panel, in: RoundedRectangle(cornerRadius: 13))

            PermissionControls(permissions: permissions, onboardingStyle: true)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(OnboardingPalette.muted)
                Text(L10n.text("仅转写电脑播放的声音；音频在本机识别，不保存音频。首次使用可能需要下载所选语言的 Apple 语音模型。"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(OnboardingPalette.muted)
            .padding(.horizontal, 4)

            Text(L10n.text("若 macOS 提示退出并重新打开应用，请照做；再次打开仍会停留在这一步。"))
                .font(.system(size: 12))
                .foregroundStyle(OnboardingPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var apiStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                onboardingField("接口地址", hint: "填写完整的 Chat Completions URL") {
                    onboardingInput {
                        TextField("https://…/v1/chat/completions", text: $apiForm.endpoint)
                            .textFieldStyle(.plain)
                            .accessibilityLabel(L10n.text("Chat Completions 完整 URL"))
                    }
                }

                onboardingField("模型名称") {
                    onboardingInput {
                        TextField(L10n.text("例如：你的模型名称"), text: $apiForm.model)
                            .textFieldStyle(.plain)
                            .accessibilityLabel(L10n.text("模型名称"))
                    }
                }

                OnboardingPalette.border.frame(height: 1)

                onboardingField("API Key", hint: "留空会保留已保存的 Key") {
                    onboardingInput {
                        SecureField(L10n.text("输入 API Key"), text: $apiForm.apiKey)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("API Key")
                    }
                }

                if apiForm.hasSavedAPIKey {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(OnboardingPalette.accent)
                        Text(L10n.text("已保存在 macOS 钥匙串"))
                            .foregroundStyle(OnboardingPalette.muted)
                        Spacer(minLength: 8)
                        Toggle("保存时清除已存 Key", isOn: $apiForm.clearSavedAPIKey)
                            .toggleStyle(.checkbox)
                            .foregroundStyle(OnboardingPalette.muted)
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnboardingPalette.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(OnboardingPalette.border, lineWidth: 1)
            }

            Label(L10n.text("只有生成回答时才会向接口发送文字，不会发送音频。"), systemImage: "lock.shield")
                .font(.system(size: 12))
                .foregroundStyle(OnboardingPalette.muted)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)

            apiStatusMessage
        }
        .onAppear { apiForm.loadIfNeeded() }
    }

    private var preferencesStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("AI 回答语言"))
                    .font(.system(size: 13, weight: .semibold))
                Picker(
                    L10n.text("AI 回答语言"),
                    selection: Binding(
                        get: { languageSettings.answerLanguage },
                        set: { languageSettings.selectAnswerLanguage($0) }
                    )
                ) {
                    Text(L10n.text("跟随面试语言")).tag(nil as InterviewLanguage?)
                    ForEach(InterviewLanguage.allCases) { language in
                        Text(language.nativeName).tag(Optional(language))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnboardingPalette.panel, in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 11) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(OnboardingPalette.accent)
                        .frame(width: 38, height: 38)
                        .background(OnboardingPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("个人背景与回答偏好"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(L10n.text("只填写希望 AI 在回答中参考的内容。"))
                            .font(.system(size: 12))
                            .foregroundStyle(OnboardingPalette.muted)
                    }
                }

                TextEditor(text: $apiForm.profile)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 150)
                    .padding(12)
                    .background(OnboardingPalette.right, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(OnboardingPalette.border, lineWidth: 1)
                    }
                    .accessibilityLabel(L10n.text("个人背景与回答偏好"))
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnboardingPalette.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(OnboardingPalette.border, lineWidth: 1)
            }

            Text(L10n.text("例如工作经历、项目重点和你喜欢的回答方式。请勿填写密码等敏感信息。"))
                .font(.system(size: 12))
                .foregroundStyle(OnboardingPalette.muted)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)

            apiStatusMessage
        }
    }

    @ViewBuilder
    private var apiStatusMessage: some View {
        if let status = apiForm.statusMessage, status != L10n.text("已保存 API 设置。") {
            Label(status, systemImage: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func onboardingField<Content: View>(
        _ title: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.text(title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.text)
                if let hint {
                    Text(L10n.text(hint))
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingPalette.muted)
                }
            }
            content()
        }
    }

    private func onboardingInput<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(OnboardingPalette.right, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(OnboardingPalette.border, lineWidth: 1)
            }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(TouchBarChatStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(TouchBarChatStyle.accentWash, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("欢迎使用 TouchBarChat"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L10n.text("接下来进入你的面试工作区。"))
                        .font(.system(size: 12))
                        .foregroundStyle(TouchBarChatStyle.secondaryText)
                }
            }

            Rectangle()
                .fill(TouchBarChatStyle.border)
                .frame(height: 1)

            welcomeNote(symbol: "play.circle", title: "开始后自动进入专注状态", detail: "窗口会最小化；在菜单栏可暂停、继续、结束面试或重新打开主窗口。")
            welcomeNote(
                symbol: "rectangle.on.rectangle", title: "实时内容出现在 Touch Bar",
                detail: "面试中只保存文字，Touch Bar 会在转录和 AI 回答之间切换。没有 Touch Bar 时，主窗口仍可查看记录。")
            welcomeNote(symbol: "text.book.closed", title: "结束后再复盘", detail: "每次面试的一问一答会留在记录中，结束后可编辑和整理。")
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OnboardingPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(OnboardingPalette.border, lineWidth: 1)
        }
    }

    private func welcomeNote(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(TouchBarChatStyle.accent)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title))
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.text(detail))
                    .font(.system(size: 12))
                    .foregroundStyle(TouchBarChatStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var navigationFooter: some View {
        HStack(spacing: 14) {
            if step == .permissions {
                Image(systemName: permissions.isReady ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(permissions.isReady ? OnboardingPalette.accent : OnboardingPalette.muted)
                Text(
                    L10n.text(
                        permissions.isReady
                            ? "录制权限与本地语音转写已就绪"
                            : (permissions.isCheckingModernSpeech
                                ? "正在检查本机语音转写能力"
                                : "完成录制权限和本地语音转写设置后继续"))
                )
                .font(.system(size: 12))
                .foregroundStyle(OnboardingPalette.muted)
            } else {
                Button(L10n.text("返回")) {
                    switch step {
                    case .permissions: break
                    case .api: step = .permissions
                    case .preferences: step = .api
                    case .welcome: step = welcomeBackStep
                    }
                }
                .buttonStyle(.borderless)
            }

            Spacer(minLength: 12)

            switch step {
            case .permissions:
                Button(L10n.text("继续")) { step = .api }
                    .buttonStyle(TouchBarChatPrimaryButton())
                    .disabled(!permissions.isReady)
                    .keyboardShortcut(.defaultAction)
            case .api:
                Button(L10n.text("跳过")) {
                    skippedSteps.formUnion([.api, .preferences])
                    welcomeBackStep = .api
                    step = .welcome
                }
                .buttonStyle(.borderless)
                Button(L10n.text("保存并继续")) {
                    if apiForm.save(includeProfile: false) {
                        skippedSteps.subtract([.api, .preferences])
                        step = .preferences
                    }
                }
                .buttonStyle(TouchBarChatPrimaryButton())
                .keyboardShortcut(.defaultAction)
            case .preferences:
                Button(L10n.text("跳过")) {
                    skippedSteps.insert(.preferences)
                    welcomeBackStep = .preferences
                    step = .welcome
                }
                .buttonStyle(.borderless)
                Button(L10n.text("保存并继续")) {
                    if apiForm.save() {
                        skippedSteps.remove(.preferences)
                        welcomeBackStep = .preferences
                        step = .welcome
                    }
                }
                .buttonStyle(TouchBarChatPrimaryButton())
                .keyboardShortcut(.defaultAction)
            case .welcome:
                Button(L10n.text("进入 TouchBarChat")) {
                    presentation.finishOnboarding()
                }
                .buttonStyle(TouchBarChatPrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 34)
        .padding(.top, 14)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background(OnboardingPalette.right)
    }
}

// MARK: - Permission checks

/// Rechecks macOS privacy state and Apple on-device support for the selected
/// interview language. The protected capture retry never starts a stream.
@MainActor
private final class PermissionStatusModel: ObservableObject {
    private enum ModernSpeechStatus {
        case checking
        case supported
        case unsupported
    }

    @Published private(set) var screenGranted = false
    @Published private(set) var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published private var modernSpeechStatus: ModernSpeechStatus = .checking
    @Published private(set) var isRequestingScreen = false
    @Published private(set) var needsScreenRecovery = false
    private var screenRequestID: UUID?
    private var modernSpeechCheck: Task<Void, Never>?

    init() { refresh() }

    var isCheckingModernSpeech: Bool { modernSpeechStatus == .checking }
    var usesModernSpeech: Bool { modernSpeechStatus == .supported }
    var supportsLegacyLocalSpeech: Bool {
        SFSpeechRecognizer(locale: InterviewLanguageSettings.shared.selectedLanguage.locale)?
            .supportsOnDeviceRecognition == true
    }
    var isSpeechReady: Bool {
        switch modernSpeechStatus {
        case .checking: return false
        case .supported: return true
        case .unsupported: return supportsLegacyLocalSpeech && speechStatus == .authorized
        }
    }
    var isReady: Bool { screenGranted && isSpeechReady }

    func refresh() {
        screenGranted = CGPreflightScreenCaptureAccess()
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        if screenGranted { needsScreenRecovery = false }
        modernSpeechCheck?.cancel()
        if #available(macOS 26.0, *) {
            modernSpeechStatus = .checking
            let selectedLocale = InterviewLanguageSettings.shared.selectedLanguage.locale
            modernSpeechCheck = Task { [weak self] in
                let supported = await LocalSpeechTranscriber.canUseModernLocalRecognition(locale: selectedLocale)
                guard !Task.isCancelled else { return }
                self?.modernSpeechStatus = supported ? .supported : .unsupported
            }
        } else {
            modernSpeechStatus = .unsupported
        }
    }

    func requestScreen() {
        guard !isRequestingScreen else { return }
        isRequestingScreen = true
        needsScreenRecovery = false
        // Do not make a second protected request immediately if the person
        // declines this system prompt. Recovery is a separate, explicit action.
        _ = CGRequestScreenCaptureAccess()
        refresh()
        isRequestingScreen = false
        needsScreenRecovery = !screenGranted
    }

    func retryScreenWithScreenCaptureKit() {
        guard !isRequestingScreen else { return }
        isRequestingScreen = true
        let requestID = UUID()
        screenRequestID = requestID
        Task { [weak self] in
            // A protected ScreenCaptureKit lookup can register the app when
            // Core Graphics did not. It does not start a stream or read media.
            _ = try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            self?.finishScreenRequest(requestID)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.finishScreenRequest(requestID)
        }
    }

    private func finishScreenRequest(_ requestID: UUID) {
        guard screenRequestID == requestID else { return }
        screenRequestID = nil
        refresh()
        isRequestingScreen = false
        needsScreenRecovery = !screenGranted
    }

    func requestSpeech() {
        SFSpeechRecognizer.requestAuthorization { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func openScreenSettings() {
        openSettings("Privacy_ScreenCapture")
    }

    func openSpeechSettings() {
        openSettings("Privacy_SpeechRecognition")
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func copyApplicationPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Bundle.main.bundleURL.path, forType: .string)
    }

    var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    var speechDescription: String {
        if isCheckingModernSpeech { return L10n.text("正在检查") }
        if usesModernSpeech { return L10n.text("本地可用") }
        if !supportsLegacyLocalSpeech { return L10n.text("所选语言的本地识别不可用") }
        switch speechStatus {
        case .authorized: return L10n.text("已允许")
        case .notDetermined: return L10n.text("尚未请求")
        case .denied: return L10n.text("已拒绝，请到系统设置中开启")
        case .restricted: return L10n.text("受系统限制")
        @unknown default: return L10n.text("状态未知")
        }
    }
}

/// Shared permission rows for onboarding and the later Settings screen.
@MainActor
private struct PermissionControls: View {
    @ObservedObject var permissions: PermissionStatusModel
    var onboardingStyle = false

    var body: some View {
        VStack(spacing: 0) {
            permissionRow(
                title: "屏幕与系统音频录制",
                subtitle: onboardingStyle
                    ? "用于获取电脑播放的声音进行转写。"
                    : "读取电脑正在播放的声音，不读取屏幕画面",
                symbol: onboardingStyle ? "display" : "waveform",
                status: permissions.screenGranted ? "已允许" : (onboardingStyle ? "未授权" : "未允许"),
                granted: permissions.screenGranted,
                showActions: !permissions.screenGranted
            ) {
                if !permissions.screenGranted {
                    Button(L10n.text(permissions.isRequestingScreen ? "正在请求…" : "请求权限")) {
                        permissions.requestScreen()
                    }
                    .disabled(permissions.isRequestingScreen)
                    Button(L10n.text("系统设置")) { permissions.openScreenSettings() }
                }
            }

            if permissions.needsScreenRecovery {
                screenRecoveryHelp
                    .padding(.leading, 48)
                    .padding(.bottom, 14)
            }

            if onboardingStyle {
                Color.clear.frame(height: 14)
            } else {
                TouchBarChatStyle.border.frame(height: 1).padding(.leading, 48)
            }

            permissionRow(
                title: permissions.usesModernSpeech ? "Apple 本地语音转写" : "语音识别",
                subtitle: permissions.isCheckingModernSpeech
                    ? "正在检查这台 Mac 对所选语言的本地转写能力。"
                    : (permissions.usesModernSpeech
                        ? "在本机将声音转写成文字，无需单独授权语音识别。"
                        : (permissions.supportsLegacyLocalSpeech
                            ? "兼容模式使用 Apple 本地识别，需要语音识别权限。"
                            : "此设备不支持所选语言的 Apple 本地识别，无法开启转写。")),
                symbol: "text.bubble",
                status: permissions.speechDescription,
                granted: permissions.isSpeechReady,
                showActions: !permissions.isCheckingModernSpeech
                    && !permissions.usesModernSpeech
                    && permissions.supportsLegacyLocalSpeech
                    && permissions.speechStatus != .authorized
            ) {
                if !permissions.isCheckingModernSpeech,
                    !permissions.usesModernSpeech,
                    permissions.supportsLegacyLocalSpeech,
                    permissions.speechStatus == .notDetermined
                {
                    Button(L10n.text("请求权限")) { permissions.requestSpeech() }
                } else if !permissions.isCheckingModernSpeech,
                    !permissions.usesModernSpeech,
                    permissions.supportsLegacyLocalSpeech,
                    permissions.speechStatus != .authorized
                {
                    Button(L10n.text("系统设置")) { permissions.openSpeechSettings() }
                }
            }

            HStack {
                Spacer()
                Button {
                    permissions.refresh()
                } label: {
                    Label(L10n.text("重新检查权限"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 10)
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .onReceive(InterviewLanguageSettings.shared.$selectedLanguage) { _ in
            permissions.refresh()
        }
    }

    private var screenRecoveryHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("macOS 仍未确认录制权限"))
                .font(.system(size: 12, weight: .semibold))
            Text(
                L10n.text(
                    "如果已同意授权，请退出并重新打开应用。若未弹出授权或系统列表没有“%@”，可用系统采集框架重试；仍未出现时，请在上方“录屏与系统录音”列表点＋添加此应用，不要添加到“仅系统录音”。",
                    permissions.applicationName)
            )
            .font(.system(size: 12))
            .foregroundStyle(TouchBarChatStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            if onboardingStyle {
                HStack(spacing: 8) {
                    Button(L10n.text("再次请求")) { permissions.retryScreenWithScreenCaptureKit() }
                        .disabled(permissions.isRequestingScreen)
                    Button(L10n.text("打开系统设置")) { permissions.openScreenSettings() }
                    Button(L10n.text("显示应用位置")) { permissions.revealApplication() }
                    Button(L10n.text("复制应用路径")) { permissions.copyApplicationPath() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button(L10n.text("再次请求")) { permissions.retryScreenWithScreenCaptureKit() }
                        .disabled(permissions.isRequestingScreen)
                    Button(L10n.text("打开系统设置")) { permissions.openScreenSettings() }
                    Spacer(minLength: 8)
                    Menu {
                        Button(L10n.text("显示应用位置")) { permissions.revealApplication() }
                        Button(L10n.text("复制应用路径")) { permissions.copyApplicationPath() }
                    } label: {
                        Label(L10n.text("更多操作"), systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(TouchBarChatStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func permissionRow<Actions: View>(
        title: String,
        subtitle: String,
        symbol: String,
        status: String,
        granted: Bool,
        showActions: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        if onboardingStyle {
            HStack(alignment: .center, spacing: 15) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(OnboardingPalette.text)
                    .frame(width: 44, height: 44)
                    .background(OnboardingPalette.border.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text(title))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnboardingPalette.text)
                    Text(L10n.text(subtitle))
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 7) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(granted ? Color.green : OnboardingPalette.muted)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(L10n.text(status))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(OnboardingPalette.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(OnboardingPalette.border.opacity(0.5), in: Capsule())

                    VStack(alignment: .trailing, spacing: 4, content: actions)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .frame(minWidth: 120, alignment: .trailing)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnboardingPalette.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(OnboardingPalette.border, lineWidth: 1)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(TouchBarChatStyle.accent)
                        .frame(width: 34, height: 34)
                        .background(TouchBarChatStyle.accentWash, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text(title))
                            .font(.system(size: 13, weight: .semibold))
                        Text(L10n.text(subtitle))
                            .font(.caption)
                            .foregroundStyle(TouchBarChatStyle.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(granted ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(L10n.text(status))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(TouchBarChatStyle.primaryText)
                    }
                }
                if showActions {
                    HStack(spacing: 8, content: actions)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.leading, 48)
                }
            }
            .padding(.vertical, 14)
        }
    }
}

// MARK: - AI configuration form

/// Holds an editable draft. API keys enter the Keychain only on explicit save;
/// opening the form never reads the saved key back into a text field.
@MainActor
private final class APISettingsFormModel: ObservableObject {
    @Published var endpoint = ""
    @Published var model = ""
    @Published var profile = ""
    @Published var apiKey = ""
    @Published var hasSavedAPIKey = false
    @Published var clearSavedAPIKey = false
    @Published var statusMessage: String?
    private var hasLoaded = false

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        load()
    }

    func load() {
        do {
            let draft = try AISettingsStore.shared.currentDraft()
            endpoint = draft.endpointText
            model = draft.model
            profile = draft.profile
            hasSavedAPIKey = draft.hasSavedAPIKey
            apiKey = ""
            clearSavedAPIKey = false
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @discardableResult
    func save(includeProfile: Bool = true) -> Bool {
        do {
            // The connection step must not commit an unfinished draft from the
            // later, optional preferences step when the user navigates back.
            let profileToSave =
                includeProfile
                ? profile
                : try AISettingsStore.shared.currentDraft().profile
            try AISettingsStore.shared.save(
                endpointText: endpoint,
                model: model,
                profile: profileToSave,
                apiKeyInput: apiKey,
                clearSavedAPIKey: clearSavedAPIKey
            )
            hasSavedAPIKey =
                !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (hasSavedAPIKey && !clearSavedAPIKey)
            apiKey = ""
            clearSavedAPIKey = false
            statusMessage = L10n.text("已保存 API 设置。")
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }
}

@MainActor
private struct APISettingsFields: View {
    @ObservedObject var form: APISettingsFormModel
    let compact: Bool
    let labelWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            formRow(title: "接口地址", subtitle: "填写完整的 Chat Completions URL。") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("https://…/v1/chat/completions", text: $form.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.regular)
                        .accessibilityLabel(L10n.text("Chat Completions 完整 URL"))
                    Text(L10n.text("远程接口需使用 HTTPS；本机回环地址可使用 HTTP。"))
                        .font(.caption)
                        .foregroundStyle(TouchBarChatStyle.secondaryText)
                }
            }
            rowDivider
            formRow(title: "模型名称", subtitle: "生成回答所使用的模型名称。") {
                TextField(L10n.text("例如：你的模型名称"), text: $form.model)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
            }
            rowDivider
            formRow(title: "API Key", subtitle: "密钥安全保存在 macOS 钥匙串中。") {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField(L10n.text("输入新 Key；留空保留已存 Key"), text: $form.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.regular)
                        .accessibilityLabel("API Key")
                    if form.hasSavedAPIKey {
                        HStack(alignment: .center, spacing: 12) {
                            Label(L10n.text("已保存在钥匙串"), systemImage: "checkmark.shield.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(TouchBarChatStyle.secondaryText)
                            Spacer(minLength: 0)
                            Toggle("保存时清除已存 Key", isOn: $form.clearSavedAPIKey)
                                .toggleStyle(.checkbox)
                                .controlSize(.small)
                                .font(.caption)
                        }
                    }
                }
            }
            rowDivider
            formRow(title: "个人背景与回答偏好", subtitle: "提供经历与期望的回答风格，让回答更贴近你。") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $form.profile)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(height: compact ? 92 : 96)
                        .padding(7)
                        .accessibilityLabel(L10n.text("个人背景与回答偏好"))
                    if form.profile.isEmpty {
                        Text(L10n.text("例如：求职方向、项目经历、希望的回答风格…"))
                            .font(.system(size: 13))
                            .foregroundStyle(TouchBarChatStyle.secondaryText)
                            .padding(.leading, 12)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(TouchBarChatStyle.border, lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .touchBarChatPanel(cornerRadius: 12)
    }

    private var rowDivider: some View {
        TouchBarChatStyle.border.frame(height: 1).padding(.horizontal, 18)
    }

    @ViewBuilder
    private func formRow<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 10) {
                rowLabel(title: title, subtitle: subtitle)
                content()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 16) {
                rowLabel(title: title, subtitle: subtitle)
                    .frame(width: labelWidth, alignment: .leading)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rowLabel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(title))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TouchBarChatStyle.primaryText)
            Text(L10n.text(subtitle))
                .font(.caption)
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance
    case languages
    case aiAnswer
    case permissions
    case touchBar
    case onboarding

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: L10n.text("外观")
        case .languages: L10n.text("语言")
        case .aiAnswer: L10n.text("AI 回答")
        case .permissions: L10n.text("系统权限")
        case .touchBar: "Touch Bar"
        case .onboarding: L10n.text("引导页")
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .languages: "character.bubble"
        case .aiAnswer: "bubble.left"
        case .permissions: "lock"
        case .touchBar: "rectangle.on.rectangle"
        case .onboarding: "sidebar.left"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: L10n.text("选择 TouchBarChat 的颜色模式。")
        case .languages: L10n.text("设置面试转写和 AI 回答使用的语言。")
        case .aiAnswer: L10n.text("配置 AI 接口与回答偏好，定制符合你风格的回答。")
        case .permissions: L10n.text("检查录制权限与 Apple 本地语音转写能力。")
        case .touchBar: L10n.text("了解面试时的转录与 AI 回答显示方式。")
        case .onboarding: L10n.text("需要时重新查看初次设置流程。")
        }
    }
}

// MARK: - Settings

/// Uses native grouped controls; language options are locked during capture
/// so the recognizer and in-flight session cannot silently switch languages.
@MainActor
private struct SettingsPage: View {
    let runState: InterviewRunState
    @ObservedObject var apiForm: APISettingsFormModel
    let onShowOnboarding: () -> Void
    @StateObject private var permissions = PermissionStatusModel()
    @StateObject private var languageSettings = InterviewLanguageSettings.shared
    @StateObject private var appLanguage = AppLanguageSettings.shared
    @State private var category: SettingsCategory = .aiAnswer
    @State private var confirmsDiscardingAPIDraft = false
    @AppStorage("touchbarchat.appearance") private var appearance = "system"

    private var isInterviewActive: Bool {
        switch runState {
        case .idle: return false
        case .starting, .running, .finishing, .paused: return true
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let railWidth = min(190, max(154, geometry.size.width * 0.21))
            let detailWidth = geometry.size.width - railWidth - 1
            let compactForm = detailWidth < 480
            let labelWidth = min(224, max(154, detailWidth * 0.30))

            HStack(spacing: 0) {
                categoryNavigation
                    .frame(width: railWidth)
                    .frame(maxHeight: .infinity)
                    .background(TouchBarChatStyle.raisedSurface)
                TouchBarChatStyle.border.frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(category.title)
                                .font(.system(size: 28, weight: .semibold))
                            Text(category.subtitle)
                                .font(.system(size: 14))
                                .foregroundStyle(TouchBarChatStyle.secondaryText)
                        }
                        detailContent(compact: compactForm, labelWidth: labelWidth)
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, compactForm ? 20 : 24)
                    .padding(.top, 30)
                    .padding(.bottom, 36)
                }
                .background(TouchBarChatStyle.canvas)
            }
        }
        .background(TouchBarChatStyle.canvas)
        .navigationTitle(L10n.text("设置"))
        .onAppear { apiForm.loadIfNeeded() }
        .alert(L10n.text("放弃未保存的 API 修改？"), isPresented: $confirmsDiscardingAPIDraft) {
            Button(L10n.text("继续查看引导页"), role: .destructive, action: onShowOnboarding)
            Button(L10n.text("返回设置"), role: .cancel) {}
        } message: {
            Text(L10n.text("当前表单中的未保存内容会丢失；已保存的配置和面试记录不会改变。"))
        }
    }

    private var categoryNavigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("设置"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            ForEach(SettingsCategory.allCases) { item in
                Button {
                    category = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 14))
                            .frame(width: 18)
                        Text(item.title)
                            .font(.system(size: 13, weight: category == item ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(category == item ? TouchBarChatStyle.accent : TouchBarChatStyle.primaryText)
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .background(
                        category == item ? TouchBarChatStyle.accentWash : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.top, 30)
    }

    @ViewBuilder
    private func detailContent(compact: Bool, labelWidth: CGFloat) -> some View {
        switch category {
        case .appearance:
            appearanceDetail(compact: compact)
        case .languages:
            languagesDetail(compact: compact)
        case .aiAnswer:
            aiAnswerDetail(compact: compact, labelWidth: labelWidth)
        case .permissions:
            permissionsDetail
        case .touchBar:
            touchBarDetail
        case .onboarding:
            onboardingDetail(compact: compact)
        }
    }

    private func appearanceDetail(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            simpleSettingRow(
                title: "颜色模式",
                subtitle: "切换整个应用的浅色或深色外观。",
                compact: compact
            ) {
                appearancePicker
            }
            Text(L10n.text("选择“跟随系统”时，TouchBarChat 会随 macOS 的外观自动切换。"))
                .font(.caption)
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .padding(.leading, 8)
        }
    }

    private var appearancePicker: some View {
        Picker(L10n.text("颜色模式"), selection: $appearance) {
            Text(L10n.text("跟随系统")).tag("system")
            Text(L10n.text("浅色")).tag("light")
            Text(L10n.text("深色")).tag("dark")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 300)
    }

    private func languagesDetail(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            simpleSettingRow(
                title: "界面语言",
                subtitle: "默认跟随 macOS，也可以单独选择 TouchBarChat 的界面语言。",
                compact: compact
            ) {
                Picker(
                    L10n.text("界面语言"),
                    selection: Binding(
                        get: { appLanguage.selection },
                        set: { appLanguage.select($0) }
                    )
                ) {
                    Text(L10n.text("跟随系统")).tag(AppLanguageSettings.systemCode)
                    ForEach(AppLanguageSettings.supportedCodes, id: \.self) { code in
                        Text(interfaceLanguageName(code)).tag(code)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }
            simpleSettingRow(
                title: "面试官使用的语言",
                subtitle: "决定本地语音转写和问题结束判断使用的语言。",
                compact: compact
            ) {
                Picker(
                    L10n.text("面试官使用的语言"),
                    selection: Binding(
                        get: { languageSettings.selectedLanguage },
                        set: { languageSettings.select($0) }
                    )
                ) {
                    ForEach(InterviewLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .disabled(isInterviewActive)
            }
            simpleSettingRow(
                title: "AI 回答语言",
                subtitle: "可指定回答语言，也可跟随面试官的语言。",
                compact: compact
            ) {
                Picker(
                    L10n.text("AI 回答语言"),
                    selection: Binding(
                        get: { languageSettings.answerLanguage },
                        set: { languageSettings.selectAnswerLanguage($0) }
                    )
                ) {
                    Text(L10n.text("跟随面试语言")).tag(nil as InterviewLanguage?)
                    ForEach(InterviewLanguage.allCases) { language in
                        Text(language.nativeName).tag(Optional(language))
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .disabled(isInterviewActive)
            }
            Text(L10n.text("面试进行中不能更改转写和 AI 回答语言。界面语言可随时切换。"))
                .font(.caption)
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .padding(.leading, 8)
        }
    }

    private func interfaceLanguageName(_ code: String) -> String {
        switch code {
        case "zh-Hans": "简体中文"
        case "en": "English"
        case "ko": "한국어"
        case "ja": "日本語"
        case "ru": "Русский"
        case "fr": "Français"
        case "pt-BR": "Português (Brasil)"
        default: code
        }
    }

    private func aiAnswerDetail(compact: Bool, labelWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            APISettingsFields(form: apiForm, compact: compact, labelWidth: labelWidth)
                .disabled(isInterviewActive)
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "info.circle")
                    .foregroundStyle(TouchBarChatStyle.secondaryText)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("只发送文字，不发送音频。"))
                        .font(.caption)
                        .foregroundStyle(TouchBarChatStyle.secondaryText)
                        .help(L10n.text("生成回答时，当前问题、最多三组近期问答草稿与个人背景会发送到你配置的接口；不会发送音频。"))
                    if isInterviewActive {
                        Text(L10n.text("面试进行中无法修改；结束后可调整。"))
                            .font(.caption)
                            .foregroundStyle(TouchBarChatStyle.secondaryText)
                    }
                    if let status = apiForm.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status == L10n.text("已保存 API 设置。") ? Color.green : Color.red)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            HStack {
                Spacer()
                Button(L10n.text("保存设置")) { apiForm.save() }
                    .buttonStyle(TouchBarChatPrimaryButton())
                    .disabled(isInterviewActive)
            }
        }
    }

    private var permissionsDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            PermissionControls(permissions: permissions)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .touchBarChatPanel(cornerRadius: 12)
            Text(L10n.text("只采集电脑播放的声音，不采集麦克风；语音仅在本机识别。macOS 26 优先使用 Apple 新版所选语言模型，旧版系统使用需要授权的本地兼容模式。"))
                .font(.caption)
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }

    private var touchBarDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.text("逐行阅读"), systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TouchBarChatStyle.primaryText)
            Text(L10n.text("面试官发言时显示实时转录；AI 开始回答后切换到回答，最新两行会随内容逐行上移。"))
                .font(.callout)
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("AI 回答阶段可用 Touch Bar 上的上下按钮逐行回看；追上最新内容后继续自动跟随。"))
                .font(.caption)
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .touchBarChatPanel(cornerRadius: 12)
    }

    private func onboardingDetail(compact: Bool) -> some View {
        simpleSettingRow(
            title: "重新查看引导页",
            subtitle: isInterviewActive
                ? "请在结束当前面试后查看。"
                : "不会清除已有的 API 配置与面试记录。",
            compact: compact
        ) {
            Button(L10n.text("重新查看引导页")) {
                if hasUnsavedAPIChanges {
                    confirmsDiscardingAPIDraft = true
                } else {
                    onShowOnboarding()
                }
            }
            .buttonStyle(.bordered)
            .disabled(isInterviewActive)
        }
    }

    private var hasUnsavedAPIChanges: Bool {
        guard let saved = try? AISettingsStore.shared.currentDraft() else { return true }
        return apiForm.endpoint != saved.endpointText
            || apiForm.model != saved.model
            || apiForm.profile != saved.profile
            || !apiForm.apiKey.isEmpty
            || apiForm.clearSavedAPIKey
    }

    @ViewBuilder
    private func simpleSettingRow<Control: View>(
        title: String,
        subtitle: String,
        compact: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 14) {
                    simpleSettingLabel(title: title, subtitle: subtitle)
                    control()
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    simpleSettingLabel(title: title, subtitle: subtitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    control()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .touchBarChatPanel(cornerRadius: 12)
    }

    private func simpleSettingLabel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(title))
                .font(.system(size: 14, weight: .semibold))
            Text(L10n.text(subtitle))
                .font(.caption)
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Interview records

/// Presents saved sessions by local calendar day without editing live capture.
@MainActor
private struct RecordsPage: View {
    @ObservedObject var store: InterviewStore
    let isInterviewActive: Bool
    @Binding var isDetailExpanded: Bool
    @State private var selectedSessionID: UUID?
    @State private var collapsedDays: Set<Date> = []

    private struct SessionDayGroup: Identifiable {
        let day: Date
        let sessions: [InterviewSession]
        var id: Date { day }
    }

    private var sessionGroups: [SessionDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.sessions) {
            calendar.startOfDay(for: $0.startedAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            SessionDayGroup(
                day: day,
                sessions: (grouped[day] ?? []).sorted { $0.startedAt > $1.startedAt }
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if !isDetailExpanded {
                    sessionList
                        .frame(width: min(404, max(280, geometry.size.width * 0.325)))
                    TouchBarChatStyle.border.frame(width: 1)
                }
                if let selectedSessionID,
                    let session = store.sessions.first(where: { $0.id == selectedSessionID })
                {
                    SessionDetailView(
                        store: store,
                        session: session,
                        isInterviewActive: isInterviewActive,
                        isDetailExpanded: $isDetailExpanded
                    )
                    .id(session.id)
                } else {
                    emptySelection
                }
            }
        }
        .onAppear {
            if let activeSessionID = store.activeSessionID {
                selectedSessionID = activeSessionID
            } else {
                selectAvailableSession()
            }
        }
        .onChange(of: store.sessions.map(\.id)) { _ in
            selectAvailableSession()
            if store.sessions.isEmpty { isDetailExpanded = false }
        }
        .onChange(of: store.activeSessionID) { activeSessionID in
            if let activeSessionID {
                selectedSessionID = activeSessionID
            } else {
                selectAvailableSession()
            }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.text("面试记录"))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(TouchBarChatStyle.primaryText)
                Spacer()
                Button {
                    isDetailExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 37, height: 32)
                        .background(
                            TouchBarChatStyle.raisedSurface,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .disabled(selectedSessionID == nil)
                .help(L10n.text("全宽阅读当前记录"))
                .accessibilityLabel(L10n.text("全宽阅读当前记录"))
            }
            .padding(.horizontal, 20)
            .frame(height: 86)

            if store.sessions.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 21, weight: .light))
                    Text(
                        L10n.text(
                            store.persistenceError != nil
                                ? "记录暂时无法读取"
                                : "还没有记录")
                    )
                    .font(.subheadline)
                }
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 17) {
                        ForEach(sessionGroups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                dateGroupHeader(group.day)
                                if !collapsedDays.contains(group.day) {
                                    ForEach(group.sessions) { session in
                                        sessionRow(session)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 28)
                }
            }
        }
        .background(TouchBarChatStyle.recordList)
    }

    private func dateGroupHeader(_ day: Date) -> some View {
        let calendar = Calendar.current
        let relative =
            calendar.isDateInToday(day)
            ? L10n.text("今天")
            : (calendar.isDateInYesterday(day) ? L10n.text("昨天") : nil)
        return Button {
            if collapsedDays.contains(day) {
                collapsedDays.remove(day)
            } else {
                collapsedDays.insert(day)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: collapsedDays.contains(day) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
                Text(relative ?? fullDate(day))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TouchBarChatStyle.primaryText)
                if relative != nil {
                    Text(fullDate(day))
                        .font(.system(size: 13))
                        .foregroundStyle(TouchBarChatStyle.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            L10n.text(
                "%@，%@",
                relative ?? fullDate(day),
                L10n.text(collapsedDays.contains(day) ? "展开" : "折叠")
            ))
    }

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func sessionRow(_ session: InterviewSession) -> some View {
        let isSelected = selectedSessionID == session.id
        let excerpt =
            session.editedMarkdown.map(markdownExcerpt)
            ?? session.exchanges.first?.displayQuestion
            ?? session.displayTranscript
        return Button {
            selectedSessionID = session.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TouchBarChatStyle.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    Text(session.endedAt == nil ? L10n.text("进行中") : timeString(session.startedAt))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(TouchBarChatStyle.secondaryText)
                }
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: 13))
                        .foregroundStyle(TouchBarChatStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .frame(minHeight: 82)
            .background(
                isSelected ? TouchBarChatStyle.accentWash : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    TouchBarChatStyle.accent
                        .frame(width: 5)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title)，\(fullDate(session.startedAt)) \(timeString(session.startedAt))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func markdownExcerpt(_ source: String) -> String {
        source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" }?
            .replacingOccurrences(of: "**", with: "")
            ?? L10n.text("空白文档")
    }

    private var emptySelection: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(TouchBarChatStyle.accent.opacity(0.7))
            Text(
                L10n.text(
                    store.persistenceError != nil
                        ? "记录暂时无法读取"
                        : "面试记录会在这里")
            )
            .font(.title3.weight(.medium))
            Text(
                L10n.text(
                    store.persistenceError != nil
                        ? "原文件已经保留。请查看上方提示，不要新建覆盖。"
                        : "开始面试后，问答和完整转写将自动保存为本机文字记录。")
            )
            .font(.callout)
            .foregroundStyle(TouchBarChatStyle.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TouchBarChatStyle.canvas)
    }

    private func selectAvailableSession() {
        if let selectedSessionID,
            store.sessions.contains(where: { $0.id == selectedSessionID })
        {
            return
        }
        selectedSessionID = store.sessions.first?.id
    }
}

/// Renders the generated Markdown or a persisted review-time override. A live
/// session is read-only; edits and export are available after it ends.
@MainActor
private struct SessionDetailView: View {
    @ObservedObject var store: InterviewStore
    let session: InterviewSession
    let isInterviewActive: Bool
    @Binding var isDetailExpanded: Bool
    @State private var titleDraft: String
    @State private var markdownDraft: String
    @State private var lastSyncedTitle: String
    @State private var lastSyncedMarkdown: String
    @State private var isEditing = false
    @State private var confirmingDelete = false
    @State private var confirmingRestore = false
    @State private var exportError: String?
    @State private var showsOriginalTranscript = false

    init(
        store: InterviewStore,
        session: InterviewSession,
        isInterviewActive: Bool,
        isDetailExpanded: Binding<Bool>
    ) {
        self.store = store
        self.session = session
        self.isInterviewActive = isInterviewActive
        _isDetailExpanded = isDetailExpanded
        _titleDraft = State(initialValue: session.title)
        _markdownDraft = State(initialValue: session.displayMarkdown)
        _lastSyncedTitle = State(initialValue: session.title)
        _lastSyncedMarkdown = State(initialValue: session.displayMarkdown)
    }

    private var isEditable: Bool { session.endedAt != nil && !isInterviewActive }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    documentHeader

                    if !isEditable {
                        Label(L10n.text("面试进行中，记录只读；结束后可编辑。"), systemImage: "lock")
                            .font(.callout)
                            .foregroundStyle(TouchBarChatStyle.secondaryText)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(TouchBarChatStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                            .padding(.top, 24)
                    }
                    if let error = store.persistenceError {
                        Label(L10n.text("记录保存失败：%@", error), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.top, 14)
                    }
                    if let exportError {
                        Label(exportError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.top, 14)
                    }

                    TouchBarChatStyle.border
                        .frame(height: 1)
                        .padding(.top, 21)
                        .padding(.bottom, 24)

                    if isEditing && isEditable {
                        TextEditor(text: $markdownDraft)
                            .font(.system(size: 14, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 440)
                            .padding(18)
                            .background(TouchBarChatStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(TouchBarChatStyle.border, lineWidth: 1)
                            }
                            .accessibilityLabel(L10n.text("编辑面试记录 Markdown"))
                    } else {
                        conversationBody
                    }

                    if !session.transcript.isEmpty
                        && (!session.exchanges.isEmpty || session.editedMarkdown != nil)
                        && session.editedMarkdown?.contains(session.originalTranscriptHeading) != true
                        && !isEditing
                    {
                        originalTranscriptDisclosure
                            .padding(.top, 27)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 80)
                .padding(.bottom, 45)
                .frame(maxWidth: isDetailExpanded ? 880 : 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            detailActions
                .padding(.top, 19)
                .padding(.trailing, 22)
        }
        .background(TouchBarChatStyle.canvas)
        .confirmationDialog(L10n.text("删除这场面试记录？"), isPresented: $confirmingDelete) {
            Button(L10n.text("删除记录"), role: .destructive) {
                store.deleteSession(id: session.id)
            }
        } message: {
            Text(L10n.text("此操作会删除本机保存的转写和问答，无法撤销。"))
        }
        .confirmationDialog(L10n.text("恢复自动整理的内容？"), isPresented: $confirmingRestore) {
            Button(L10n.text("恢复"), role: .destructive) {
                store.restoreSessionMarkdown(id: session.id)
                markdownDraft = session.generatedMarkdown
                lastSyncedMarkdown = session.generatedMarkdown
            }
        } message: {
            Text(L10n.text("这会替换已编辑的 Markdown；原始问答和转写仍保留在本机。"))
        }
        .onChange(of: session.endedAt) { _ in
            titleDraft = session.title
            markdownDraft = session.displayMarkdown
            lastSyncedTitle = session.title
            lastSyncedMarkdown = session.displayMarkdown
            isEditing = false
        }
        .onChange(of: session.title) { latest in
            if titleDraft == lastSyncedTitle { titleDraft = latest }
            lastSyncedTitle = latest
        }
        .onChange(of: session.displayMarkdown) { latest in
            if markdownDraft == lastSyncedMarkdown { markdownDraft = latest }
            lastSyncedMarkdown = latest
        }
        .onChange(of: isInterviewActive) { active in
            if active { isEditing = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .touchBarChatCommitRecordDrafts)) { _ in
            saveOwnDrafts()
        }
        .onDisappear {
            saveOwnDrafts()
        }
    }

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            Group {
                if isEditing && isEditable {
                    TextField(L10n.text("面试标题"), text: $titleDraft)
                        .textFieldStyle(.plain)
                        .onSubmit { saveOwnDrafts() }
                        .accessibilityLabel(L10n.text("编辑面试标题"))
                } else {
                    Text(session.title)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(TouchBarChatStyle.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 9) {
                Text(displayDate(session.startedAt))
                Text("·")
                Text(L10n.text("%d 个问题", session.exchanges.count))
                if session.endedAt == nil {
                    Text(L10n.text("· 进行中"))
                        .foregroundStyle(TouchBarChatStyle.accent)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(TouchBarChatStyle.secondaryText)
        }
    }

    private func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    @ViewBuilder
    private var conversationBody: some View {
        let labels = InterviewMarkdownLabels(language: session.language)
        if let editedMarkdown = session.editedMarkdown {
            MarkdownDocumentPreview(markdown: editedMarkdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if !session.exchanges.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(session.exchanges.indices, id: \.self) { index in
                    let exchange = session.exchanges[index]
                    HStack(alignment: .top, spacing: 18) {
                        Text("\(index + 1)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TouchBarChatStyle.primaryText)
                            .frame(width: 38, height: 38)
                            .background(TouchBarChatStyle.accentWash, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 17) {
                            exchangeLine(labels.interviewer, markdown: exchange.displayQuestion)
                            exchangeLine(labels.ai, markdown: exchange.displayAnswer ?? labels.noAnswer)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if index < session.exchanges.count - 1 {
                        TouchBarChatStyle.border
                            .frame(height: 1)
                            .padding(.top, 25)
                            .padding(.bottom, 25)
                    }
                }
            }
        } else if !session.displayTranscript.isEmpty {
            MarkdownDocumentPreview(markdown: session.displayTranscript)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(L10n.text("还没有转写内容。"))
                .font(.callout)
                .foregroundStyle(TouchBarChatStyle.secondaryText)
        }
    }

    private func exchangeLine(_ label: String, markdown: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TouchBarChatStyle.primaryText)
                .frame(width: 70, alignment: .leading)
            MarkdownDocumentPreview(markdown: markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var originalTranscriptDisclosure: some View {
        DisclosureGroup(isExpanded: $showsOriginalTranscript) {
            Text(session.transcript)
                .font(.system(size: 14))
                .foregroundStyle(TouchBarChatStyle.secondaryText)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 13)
                .padding(.bottom, 14)
        } label: {
            Text(InterviewMarkdownLabels(language: session.language).originalTranscript)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TouchBarChatStyle.secondaryText)
        }
        .padding(.vertical, 15)
        .overlay(alignment: .top) { TouchBarChatStyle.border.frame(height: 1) }
        .overlay(alignment: .bottom) { TouchBarChatStyle.border.frame(height: 1) }
    }

    private var detailActions: some View {
        HStack(spacing: 9) {
            if isEditing && isEditable {
                actionButton("取消编辑", symbol: "xmark") {
                    titleDraft = session.title
                    markdownDraft = session.displayMarkdown
                    isEditing = false
                }
                actionButton("保存修改", symbol: "checkmark", selected: true) {
                    saveOwnDrafts()
                    isEditing = false
                }
            } else {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TouchBarChatStyle.accent)
                    .frame(width: 42, height: 34)
                    .background(TouchBarChatStyle.accentWash, in: RoundedRectangle(cornerRadius: 8))
                    .help(L10n.text("阅读模式"))
                    .accessibilityLabel(L10n.text("阅读模式"))
                if isEditable {
                    actionButton("编辑 Markdown", symbol: "pencil") {
                        titleDraft = session.title
                        markdownDraft = session.displayMarkdown
                        isEditing = true
                    }
                }
            }

            if isEditable {
                actionButton("导出 Markdown", symbol: "square.and.arrow.up") {
                    saveOwnDrafts()
                    exportSession()
                }
            }
            actionButton(
                isDetailExpanded ? "退出全宽阅读" : "全宽阅读",
                symbol: isDetailExpanded
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            ) {
                isDetailExpanded.toggle()
            }
            if isEditable && !isEditing {
                Menu {
                    if session.editedMarkdown != nil {
                        Button(L10n.text("恢复自动整理的内容")) { confirmingRestore = true }
                    }
                    Button(L10n.text("删除这场面试"), role: .destructive) {
                        confirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 42, height: 34)
                        .background(
                            TouchBarChatStyle.raisedSurface,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .menuStyle(.borderlessButton)
                .help(L10n.text("更多记录操作"))
                .accessibilityLabel(L10n.text("更多记录操作"))
            }
        }
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? TouchBarChatStyle.accent : TouchBarChatStyle.primaryText)
                .frame(width: 42, height: 34)
                .background(
                    selected ? TouchBarChatStyle.accentWash : TouchBarChatStyle.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
        .help(L10n.text(title))
        .accessibilityLabel(L10n.text(title))
    }

    private func saveOwnDrafts() {
        guard isEditable, isEditing else { return }
        if titleDraft != session.title {
            store.updateSessionTitle(id: session.id, title: titleDraft)
        }
        if markdownDraft != session.displayMarkdown {
            store.updateSessionMarkdown(id: session.id, text: markdownDraft)
        }
    }

    private func exportSession() {
        guard let markdown = store.exportMarkdown(id: session.id) else {
            exportError = L10n.text("暂时无法导出这场面试。")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = L10n.text("TouchBarChat-面试记录.md")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            exportError = nil
        } catch {
            exportError = L10n.text("导出失败：%@", error.localizedDescription)
        }
    }
}

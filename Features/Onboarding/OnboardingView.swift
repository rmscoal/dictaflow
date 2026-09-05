import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: DictaFlowAppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: OnboardingPresentation {
        appState.onboardingPresentation ?? .initialSetup
    }

    private var step: OnboardingStep {
        presentation.step
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                pageContent
                    .id(step)
                    .transition(pageTransition)

                brand
                    .scaleEffect(step == .welcome ? 1 : 0.58)
                    .position(brandPosition(in: geometry.size))

                if presentation.mode == .initialSetup {
                    stepIndicator
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 26)
                }
            }
            .clipped()
        }
        .background(OnboardingTheme.background)
        .foregroundStyle(OnboardingTheme.primaryText)
        .animation(pageAnimation, value: step)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch step {
        case .welcome:
            welcomePage
        case .permissions:
            permissionsPage
        case .offlineModel:
            offlineModelPage
        case .shortcut:
            shortcutPage
        case .ready:
            readyPage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 118)

            WaveformDecoration()
                .frame(width: 260, height: 48)
                .padding(.bottom, 30)

            Text("Your voice, turned into text.")
                .font(.system(size: 27, weight: .semibold))

            Text("Private dictation that runs locally on your Mac.")
                .font(.system(size: 14))
                .foregroundStyle(OnboardingTheme.secondaryText)
                .padding(.top, 9)

            Button("Get Started") {
                advance()
            }
            .buttonStyle(PrimaryOnboardingButtonStyle())
            .padding(.top, 34)

            Spacer(minLength: 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionsPage: some View {
        OnboardingPageLayout(
            title: "Allow DictaFlow to work for you",
            subtitle: "Your microphone records speech. Accessibility places the finished text into the app you were using."
        ) {
            VStack(spacing: 12) {
                PermissionCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Record your voice for local transcription.",
                    stateTitle: appState.microphonePermissionState.title,
                    isAllowed: appState.microphonePermissionState == .granted,
                    actionTitle: microphoneActionTitle,
                    actionDisabled: appState.isRequestingMicrophonePermission,
                    action: handleMicrophonePermission
                )

                PermissionCard(
                    icon: "text.cursor",
                    title: "Accessibility",
                    detail: "Insert the transcript into the focused app.",
                    stateTitle: appState.accessibilityPermissionState.title,
                    isAllowed: appState.accessibilityPermissionState == .granted,
                    actionTitle: accessibilityActionTitle,
                    actionDisabled: false,
                    action: handleAccessibilityPermission
                )
            }
        } footer: {
            navigationFooter(
                backTitle: presentation.mode == .permissionRecovery ? "Not Now" : "Back",
                continueTitle: permissionContinueTitle,
                continueDisabled: grantedPermissionCount < 2
            )
        }
    }

    private var offlineModelPage: some View {
        let model = appState.whisperConfiguration.model
        let isPrepared = appState.isWhisperModelPrepared(model)

        return OnboardingPageLayout(
            title: "Prepare offline transcription",
            subtitle: "Download a Whisper model to continue. You can switch models later in Settings."
        ) {
            VStack(spacing: 14) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(OnboardingTheme.controlFill)
                        Image(systemName: "cpu")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(OnboardingTheme.accent)
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("Whisper \(model.displayName)")
                                .font(.system(size: 15, weight: .semibold))
                            if model == .recommendedDefault {
                                Text("Recommended")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(OnboardingTheme.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(OnboardingTheme.accent.opacity(0.13), in: Capsule())
                            }
                        }

                        Text("\(model.approximateDiskSizeDescription) · Stored only on this Mac")
                            .font(.system(size: 12))
                            .foregroundStyle(OnboardingTheme.secondaryText)
                    }

                    Spacer()

                    Button(modelActionTitle(isPrepared: isPrepared)) {
                        appState.prepareAndUseModel(model)
                    }
                    .buttonStyle(CompactOnboardingButtonStyle(isProminent: !isPrepared))
                    .disabled(isPrepared || modelPreparationIsBusy)
                }
                .padding(18)
                .background(OnboardingTheme.tileFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(OnboardingTheme.border, lineWidth: 1)
                }

                if modelPreparationIsBusy {
                    VStack(spacing: 7) {
                        if let progress = modelDownloadProgress {
                            ProgressView(value: progress)
                                .tint(OnboardingTheme.accent)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(OnboardingTheme.accent)
                        }

                        HStack {
                            Text("Downloading and verifying locally")
                            Spacer()
                            if let progress = modelDownloadProgress {
                                Text("\(Int(progress * 100))%")
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingTheme.secondaryText)
                    }
                    .padding(.horizontal, 4)
                } else if isPrepared {
                    Label("Model downloaded and verified", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OnboardingTheme.success)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else if appState.whisperModelPreparationFailed {
                    Label(appState.whisperModelPreparationStatusText, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingTheme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
        } footer: {
            navigationFooter(
                backTitle: "Back",
                continueTitle: "Continue",
                continueDisabled: !isPrepared || modelPreparationIsBusy
            )
        }
    }

    private var shortcutPage: some View {
        OnboardingPageLayout(
            title: "Choose how dictation starts",
            subtitle: "Use one global shortcut anywhere on your Mac. Select the shortcut below if you want to change it."
        ) {
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Global shortcut")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OnboardingTheme.secondaryText)
                        Text(appState.isEditingGlobalShortcut ? "Press your new shortcut" : "Select to change")
                            .font(.system(size: 11))
                            .foregroundStyle(OnboardingTheme.tertiaryText)
                    }

                    Spacer()

                    Button {
                        appState.beginGlobalShortcutEditing()
                    } label: {
                        Text(appState.isEditingGlobalShortcut ? "Press keys…" : appState.hotkeyDisplayText)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(OnboardingTheme.primaryText)
                            .padding(.horizontal, 13)
                            .frame(height: 32)
                            .background(OnboardingTheme.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(appState.isEditingGlobalShortcut ? OnboardingTheme.accent : OnboardingTheme.border, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.onboardingPracticeIsBusy)
                }
                .padding(17)
                .background(OnboardingTheme.tileFill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if appState.isEditingGlobalShortcut {
                        GlobalShortcutCaptureView(
                            isCapturing: true,
                            onShortcut: appState.handleGlobalShortcutCandidate,
                            onCancel: appState.cancelGlobalShortcutEditing
                        )
                        .frame(width: 1, height: 1)
                    }
                }

                if let message = appState.globalShortcutEditingMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingTheme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Try it now")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Use the shortcut once to start, then again to finish.")
                                .font(.system(size: 11))
                                .foregroundStyle(OnboardingTheme.secondaryText)
                        }

                        Spacer()

                        Button(practiceButtonTitle) {
                            appState.toggleDictation()
                        }
                        .buttonStyle(CompactOnboardingButtonStyle(isProminent: false))
                        .disabled(transcriptionPracticeIsBusy)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: practiceResultSymbol)
                            .foregroundStyle(practiceResultColor)
                            .padding(.top, 1)

                        Text(practiceResultText)
                            .font(.system(size: 12))
                            .foregroundStyle(practiceResultTextColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(13)
                    .frame(minHeight: 48)
                    .background(OnboardingTheme.controlFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .padding(17)
                .background(OnboardingTheme.tileFill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        } footer: {
            navigationFooter(
                backTitle: "Back",
                continueTitle: "Continue",
                continueDisabled: appState.onboardingPracticeIsBusy || appState.isEditingGlobalShortcut,
                backDisabled: appState.onboardingPracticeIsBusy
            )
        }
    }

    private var readyPage: some View {
        OnboardingPageLayout(
            title: "DictaFlow is ready",
            subtitle: "Everything stays on your Mac. Use your shortcut whenever you want to turn speech into text."
        ) {
            VStack(spacing: 0) {
                ReadyRow(icon: "mic.fill", title: "Microphone", value: "Allowed")
                ReadyDivider()
                ReadyRow(icon: "text.cursor", title: "Text insertion", value: "Allowed")
                ReadyDivider()
                ReadyRow(icon: "cpu", title: "Offline model", value: appState.whisperConfiguration.model.displayName)
                ReadyDivider()
                ReadyRow(icon: "keyboard", title: "Shortcut", value: appState.hotkeyDisplayText)
            }
            .padding(.horizontal, 18)
            .background(OnboardingTheme.tileFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(OnboardingTheme.border, lineWidth: 1)
            }
        } footer: {
            navigationFooter(
                backTitle: "Back",
                continueTitle: "Start Using DictaFlow",
                continueDisabled: false
            )
        }
    }

    private var brand: some View {
        HStack(spacing: 12) {
            OnboardingMark()
                .frame(width: 52, height: 52)

            Text("DictaFlow")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
        }
        .fixedSize()
    }

    private var stepIndicator: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                Circle()
                    .fill(stepIndicatorColor(for: item))
                    .frame(
                        width: item == step ? 13 : 6,
                        height: item == step ? 13 : 6
                    )
                    .shadow(
                        color: item == step ? Color.white.opacity(0.24) : .clear,
                        radius: 5
                    )
                    .accessibilityLabel(stepAccessibilityLabel(for: item))
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onboarding progress")
    }

    private func navigationFooter(
        backTitle: String,
        continueTitle: String,
        continueDisabled: Bool,
        backDisabled: Bool = false
    ) -> some View {
        HStack {
            Button(backTitle) {
                goBack()
            }
            .buttonStyle(SecondaryOnboardingButtonStyle())
            .disabled(backDisabled)

            Spacer()

            Button(continueTitle) {
                advance()
            }
            .buttonStyle(PrimaryOnboardingButtonStyle())
            .disabled(continueDisabled)
        }
    }

    private var grantedPermissionCount: Int {
        var count = 0
        if appState.microphonePermissionState == .granted { count += 1 }
        if appState.accessibilityPermissionState == .granted { count += 1 }
        return count
    }

    private var permissionContinueTitle: String {
        switch grantedPermissionCount {
        case 0:
            return "Allow both to continue"
        case 1:
            return "Allow one more"
        default:
            return presentation.mode == .permissionRecovery ? "Finish Setup" : "Continue"
        }
    }

    private var microphoneActionTitle: String? {
        switch appState.microphonePermissionState {
        case .undetermined:
            return appState.isRequestingMicrophonePermission ? "Requesting…" : "Allow Microphone"
        case .granted:
            return nil
        case .denied, .restricted:
            return "Open Settings"
        }
    }

    private var accessibilityActionTitle: String? {
        switch appState.accessibilityPermissionState {
        case .undetermined:
            return "Allow Accessibility"
        case .granted:
            return nil
        case .denied:
            return "Open Settings"
        }
    }

    private func handleMicrophonePermission() {
        switch appState.microphonePermissionState {
        case .undetermined:
            appState.requestMicrophonePermissionForOnboarding()
        case .granted:
            break
        case .denied, .restricted:
            appState.openMicrophoneSettings()
        }
    }

    private func handleAccessibilityPermission() {
        switch appState.accessibilityPermissionState {
        case .undetermined:
            appState.requestAccessibilityPermissionForOnboarding()
        case .granted:
            break
        case .denied:
            appState.openAccessibilitySettings()
        }
    }

    private var modelPreparationIsBusy: Bool {
        switch appState.transcriptionState {
        case .preparingModel, .downloadingModel:
            return true
        default:
            return false
        }
    }

    private var modelDownloadProgress: Double? {
        guard case .downloadingModel(let model, let progress) = appState.transcriptionState,
              model == appState.whisperConfiguration.model else {
            return nil
        }
        return progress
    }

    private func modelActionTitle(isPrepared: Bool) -> String {
        if isPrepared { return "Ready" }
        if modelPreparationIsBusy { return "Downloading…" }
        return "Download Model"
    }

    private var transcriptionPracticeIsBusy: Bool {
        !appState.recordingState.isRecording && appState.onboardingPracticeIsBusy
    }

    private var practiceButtonTitle: String {
        if appState.recordingState.isRecording { return "Finish Practice" }
        if appState.onboardingPracticeIsBusy { return "Transcribing…" }
        return "Start Practice"
    }

    private var practiceResultText: String {
        switch appState.onboardingPracticeResult {
        case .transcription(let text):
            return text
        case .noSpeech:
            return "No speech was detected. Try again."
        case nil:
            break
        }
        if appState.recordingState.isRecording { return "Listening… Speak a short sentence." }
        if appState.onboardingPracticeIsBusy { return "Turning your recording into text locally…" }
        return "Your practice transcript will appear here."
    }

    private var practiceResultSymbol: String {
        switch appState.onboardingPracticeResult {
        case .transcription:
            return "checkmark.circle.fill"
        case .noSpeech:
            return "exclamationmark.circle.fill"
        case nil:
            break
        }
        if appState.recordingState.isRecording { return "waveform" }
        return "text.bubble"
    }

    private var practiceResultColor: Color {
        switch appState.onboardingPracticeResult {
        case .transcription:
            return OnboardingTheme.success
        case .noSpeech:
            return OnboardingTheme.warning
        case nil:
            return OnboardingTheme.tertiaryText
        }
    }

    private var practiceResultTextColor: Color {
        appState.onboardingPracticeResult == nil ? OnboardingTheme.secondaryText : OnboardingTheme.primaryText
    }

    private func brandPosition(in size: CGSize) -> CGPoint {
        if step == .welcome {
            return CGPoint(x: size.width / 2, y: 62)
        }
        // Scaled brand is about 125pt wide; center it so its leading edge meets the 34pt page padding.
        return CGPoint(x: 34 + 125 / 2, y: 40)
    }

    private func stepIndicatorColor(for item: OnboardingStep) -> Color {
        if item == step || item.rawValue < step.rawValue {
            return .white
        }
        return OnboardingTheme.tertiaryText.opacity(0.68)
    }

    private func stepAccessibilityLabel(for item: OnboardingStep) -> String {
        if item == step { return "Current step \(item.rawValue + 1) of \(OnboardingStep.allCases.count)" }
        if item.rawValue < step.rawValue { return "Completed step \(item.rawValue + 1)" }
        return "Upcoming step \(item.rawValue + 1)"
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .trailing)),
            removal: .opacity.combined(with: .move(edge: .leading))
        )
    }

    private var pageAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.88)
    }

    private func advance() {
        withAnimation(pageAnimation) {
            appState.advanceOnboarding()
        }
    }

    private func goBack() {
        withAnimation(pageAnimation) {
            appState.returnToPreviousOnboardingStep()
        }
    }
}

private struct OnboardingPageLayout<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .frame(maxWidth: 570)

            content
                .frame(maxWidth: 580)
                .padding(.top, 26)

            Spacer(minLength: 18)

            footer
                .frame(maxWidth: 580)
                .padding(.bottom, 55)
        }
        .padding(.top, 76)
        .padding(.horizontal, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PermissionCard: View {
    let icon: String
    let title: String
    let detail: String
    let stateTitle: String
    let isAllowed: Bool
    let actionTitle: String?
    let actionDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(OnboardingTheme.controlFill)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isAllowed ? OnboardingTheme.success : OnboardingTheme.accent)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(OnboardingTheme.secondaryText)
            }

            Spacer()

            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(CompactOnboardingButtonStyle(isProminent: false))
                    .disabled(actionDisabled)
            } else {
                Label(stateTitle, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.success)
            }
        }
        .padding(16)
        .background(OnboardingTheme.tileFill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        }
    }
}

private struct ReadyRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(OnboardingTheme.secondaryText)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OnboardingTheme.primaryText)
        }
        .frame(height: 49)
    }
}

private struct ReadyDivider: View {
    var body: some View {
        Rectangle()
            .fill(OnboardingTheme.border)
            .frame(height: 1)
    }
}

private struct OnboardingMark: View {
    private let barHeights: [CGFloat] = [8, 15, 23, 15, 8]

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay {
                HStack(spacing: 2.5) {
                    ForEach(Array(barHeights.enumerated()), id: \.offset) { _, height in
                        Capsule()
                            .fill(OnboardingTheme.logoInk)
                            .frame(width: 3, height: height)
                    }
                }
            }
    }
}

private struct WaveformDecoration: View {
    private let heights: [CGFloat] = [6, 11, 18, 30, 42, 26, 15, 9, 14, 25, 37, 22, 12, 7]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(OnboardingTheme.accent.opacity(0.84))
                    .frame(width: 4, height: height)
            }
        }
    }
}

private struct PrimaryOnboardingButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 22)
            .frame(minWidth: 126, minHeight: 38)
            .background(OnboardingTheme.accent.opacity(configuration.isPressed ? 0.76 : 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct SecondaryOnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(OnboardingTheme.secondaryText)
            .padding(.horizontal, 17)
            .frame(minHeight: 38)
            .background(OnboardingTheme.controlFill.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CompactOnboardingButtonStyle: ButtonStyle {
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isProminent ? Color.white : OnboardingTheme.primaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: 31)
            .background(
                isProminent ? OnboardingTheme.accent : OnboardingTheme.controlFill,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.46)
    }
}

private enum OnboardingTheme {
    static let background = Color(red: 0.090, green: 0.098, blue: 0.114)
    static let tileFill = Color(red: 0.137, green: 0.145, blue: 0.165)
    static let controlFill = Color.white.opacity(0.055)
    static let border = Color.white.opacity(0.085)
    static let primaryText = Color(red: 0.961, green: 0.965, blue: 0.973)
    static let secondaryText = Color(red: 0.58, green: 0.60, blue: 0.64)
    static let tertiaryText = Color(red: 0.40, green: 0.43, blue: 0.48)
    static let accent = Color(red: 0.302, green: 0.471, blue: 0.984)
    static let success = Color(red: 0.275, green: 0.706, blue: 0.443)
    static let warning = Color(red: 0.94, green: 0.67, blue: 0.31)
    static let logoInk = Color(red: 0.12, green: 0.16, blue: 0.24)
}

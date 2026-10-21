import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var sidebarCollapsedOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if appState.onboardingPresentation != nil {
                OnboardingView(appState: appState)
            } else {
                GeometryReader { geometry in
                    let collapsed = sidebarCollapsedOverride ?? (geometry.size.width <= 1000)
                    HStack(spacing: 0) {
                        AppSidebar(appState: appState, collapsed: collapsed)
                        VStack(spacing: 0) {
                            MainWindowToolbar(appState: appState, sidebarCollapsed: collapsed) {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                    sidebarCollapsedOverride = !collapsed
                                }
                            }
                            if let issue = appState.interfaceIssue, appState.modelPickerPresentation == nil {
                                Group {
                                    if issue.severity == .error {
                                        EmberErrorBanner(title: issue.title, message: issue.message, actionTitle: "Dismiss") { appState.dismissInterfaceIssue() }
                                    } else {
                                        EmberInformationBanner(title: issue.title, message: issue.message) { appState.dismissInterfaceIssue() }
                                    }
                                }
                                .padding(.horizontal, AppLayout.contentPadding).padding(.bottom, 14)
                            }
                            page
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .overlay(alignment: .topTrailing) {
                                    if let notice = appState.downloadCompletionNotice {
                                        DownloadCompletionNotification(appState: appState, notice: notice)
                                            .padding(.top, 14).padding(.trailing, AppLayout.contentPadding)
                                            .transition(.move(edge: .trailing).combined(with: .opacity))
                                    }
                                }
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appState.downloadCompletionNotice?.id)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: AppLayout.windowMinWidth, minHeight: AppLayout.windowMinHeight)
        .foregroundStyle(AppTheme.primaryText)
        .background(AppTheme.background)
        .tint(AppTheme.accent)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $appState.modelPickerPresentation) { presentation in
            ModelPickerSheet(appState: appState, presentation: presentation)
        }
        .alert("Recording failed", isPresented: Binding(
            get: { appState.recordingFailureMessage != nil },
            set: { if !$0 { appState.dismissRecordingFailure() } }
        )) {
            Button("OK", role: .cancel) { appState.dismissRecordingFailure() }
        } message: {
            Text(appState.recordingFailureMessage ?? "Check your microphone and sound output, then try again.")
        }
    }

    @ViewBuilder private var page: some View {
        switch appState.mainWindowPage {
        case .dictation: DictationWorkspaceView(appState: appState)
        case .history: HistoryView(appState: appState, model: appState.history)
        case .settings: SettingsView(appState: appState)
        case .updates: UpdatesView(appState: appState)
        }
    }
}

import SwiftUI

/// Popover listing downloads in progress only.
/// Finished, failed, and cancelled downloads are not shown here.
struct DownloadActivitiesPopover: View {
    @ObservedObject var appState: DictaFlowAppState
    @Binding var isPresented: Bool
    @State private var pendingCancellation: ModelDownloadActivity?
    @State private var confirmsCancelAll = false

    var body: some View {
        let activities = appState.activeDownloadActivities
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if activities.count > 1 {
                    Button("Cancel all") { confirmsCancelAll = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.destructive)
                        .help("Cancel all downloads in progress")
                        .accessibilityLabel("Cancel all downloads")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            EmberDivider()

            if activities.isEmpty {
                Text("No downloads in progress")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(activities, id: \.id) { activity in
                            row(activity)
                            if activity.id != activities.last?.id { EmberDivider() }
                        }
                    }
                }
                .frame(maxHeight: 320)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: 340)
        .foregroundStyle(AppTheme.primaryText)
        .background(AppTheme.tileFill)
        .tint(AppTheme.accent)
        .onChange(of: activities.isEmpty) { _, isEmpty in
            if isEmpty { isPresented = false }
        }
        .alert("Cancel download?", isPresented: Binding(
            get: { pendingCancellation != nil },
            set: { if !$0 { pendingCancellation = nil } }
        ), presenting: pendingCancellation) { activity in
            Button("Keep downloading", role: .cancel) { pendingCancellation = nil }
            Button("Cancel download", role: .destructive) {
                appState.cancelDownloadActivity(activity)
                pendingCancellation = nil
            }
        } message: { activity in
            Text("The partial download of \(activity.name) will be removed. Downloading again will start from the beginning.")
        }
        .alert("Cancel all downloads?", isPresented: $confirmsCancelAll) {
            Button("Keep downloading", role: .cancel) { confirmsCancelAll = false }
            Button("Cancel all", role: .destructive) {
                appState.cancelAllDownloadActivities()
                confirmsCancelAll = false
            }
        } message: {
            Text("The partial downloads will be removed. Downloading again will start from the beginning.")
        }
    }

    private func row(_ activity: ModelDownloadActivity) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    isPresented = false
                    appState.openDownloadActivity(activity)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.name).font(.system(size: 12, weight: .medium))
                        Text(activity.statusText).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(activity.name) in the model picker")

                if let progress = activity.progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                Button { pendingCancellation = activity } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(EmberIconButtonStyle())
                .help("Cancel download")
                .accessibilityLabel("Cancel \(activity.name) download")
            }
            EmberDownloadProgress(value: activity.progress)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }
}

import SwiftUI

struct AppSidebar: View {
    @ObservedObject var appState: DictaFlowAppState
    let collapsed: Bool
    @FocusState private var focusedPage: MainWindowPage?
    @Environment(\.colorScheme) private var colorScheme
    private let primaryPages: [MainWindowPage] = [.dictation, .history, .settings]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: AppLayout.headerHeight - 22).accessibilityHidden(true)
            HStack(spacing: 10) {
                EmberAppMark()
                if !collapsed {
                    Text("DictaFlow").font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .padding(.horizontal, collapsed ? 0 : 9)
            .padding(.bottom, 28)

            if !collapsed {
                Text("Workspace").font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 10).padding(.bottom, 7)
            }
            VStack(spacing: 3) {
                ForEach(primaryPages) { page in navigationButton(page) }
            }
            .onMoveCommand { direction in
                let offset = direction == .down ? 1 : direction == .up ? -1 : 0
                guard offset != 0 else { return }
                let index = primaryPages.firstIndex(of: focusedPage ?? appState.mainWindowPage) ?? 0
                let page = primaryPages[(index + offset + primaryPages.count) % primaryPages.count]
                appState.showMainWindowPage(page)
                focusedPage = page
            }
            Spacer(minLength: 24)
            navigationButton(.updates)
        }
        .padding(.horizontal, collapsed ? 8 : 12)
        .padding(.top, 22).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            EmberMaterialFill(tint: AppTheme.sidebar, tintOpacity: colorScheme == .dark ? 0.96 : 0.94)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppTheme.border).frame(width: 1)
        }
        .frame(width: collapsed ? AppLayout.collapsedSidebarWidth : AppLayout.sidebarWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("DictaFlow navigation")
    }

    private func navigationButton(_ page: MainWindowPage) -> some View {
        let selected = appState.mainWindowPage == page
        return Button { appState.showMainWindowPage(page) } label: {
            HStack(spacing: 11) {
                Image(systemName: page.symbol).font(.system(size: 15)).frame(width: 16)
                if !collapsed { Text(page.title).font(.system(size: 13)); Spacer(minLength: 0) }
            }
            .foregroundStyle(selected ? AppTheme.accent : AppTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, collapsed ? 8 : 11).padding(.vertical, 13)
            .background(selected ? AppTheme.selectedFill : .clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .focused($focusedPage, equals: page)
        .help(page.title)
        .accessibilityLabel(page.title)
        .accessibilityIdentifier("nav-\(page.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

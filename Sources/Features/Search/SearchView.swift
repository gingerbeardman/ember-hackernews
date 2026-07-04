import SwiftUI

struct SearchView: View {
    @State private var vm = SearchViewModel()
    @State private var path = NavigationPath()
    @State private var showingSave = false
    @Environment(SettingsStore.self) private var settings

    private let suggestions = ["Swift", "AI", "Rust", "Startups", "Security", "Apple", "Postgres"]

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Search")
                .navigationDestination(for: HNItem.self) { StoryDetailView(item: $0) }
                .navigationDestination(for: UserRoute.self) { UserView(username: $0.username) }
                .sheet(isPresented: $showingSave) {
                    AddSavedSearchView(initialQuery: vm.query)
                }
        }
        .searchable(text: $vm.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search stories and discussions")
        .task(id: searchKey) {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await vm.runSearch()
        }
        .onAppear {
            #if DEBUG
            if let seeded = LaunchArgs.query, vm.query.isEmpty { vm.query = seeded }
            #endif
        }
    }

    private var searchKey: String { "\(vm.query)|\(vm.mode.rawValue)" }

    @ViewBuilder private var content: some View {
        switch vm.phase {
        case .idle:
            suggestionsView
        case .searching:
            ScrollView { SkeletonList(count: 6) }.background(Theme.background)
        case .failed(let message):
            ErrorStateView(message: message) { Task { await vm.runSearch() } }
                .background(Theme.background)
        case .empty:
            EmptyStateView(systemImage: "magnifyingglass",
                           title: "No results",
                           message: "Try different keywords or switch the sort order.")
                .background(Theme.background)
        case .results:
            resultsList
        }
    }

    private var resultsList: some View {
        List {
            ForEach(vm.results) { story in
                ZStack {
                    NavigationLink(value: story) { EmptyView() }.opacity(0)
                    StoryRow(item: story,
                             onSelectUser: { path.append(UserRoute(username: $0)) })
                }
                .listRowInsets(EdgeInsets(top: 0, leading: Spacing.l, bottom: 0, trailing: Spacing.l))
                .listRowSeparatorTint(Theme.separator)
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            resultsHeader
        }
    }

    private var resultsHeader: some View {
        HStack(spacing: Spacing.m) {
            modePicker

            Button { showingSave = true } label: {
                Image(systemName: "bell.badge")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(settings.accent.color)
            .accessibilityLabel("Save Search")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.s)
        .background(Theme.background)
    }

    private var modePicker: some View {
        Picker("Sort", selection: Binding(
            get: { vm.mode },
            set: { newValue in Task { await vm.setMode(newValue) } }
        )) {
            ForEach(SearchMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .textCase(nil)
    }

    private var suggestionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("Popular topics")
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, Spacing.xl)

                FlowChips(items: suggestions) { tag in
                    vm.query = tag
                    Haptics.selection()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.l)
        }
        .background(Theme.background)
    }
}

/// Simple wrapping chip layout.
private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        FlexibleLayout(spacing: Spacing.s) {
            ForEach(items, id: \.self) { item in
                Button {
                    onTap(item)
                } label: {
                    Text(item)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.s)
                        .background(Theme.surface)
                        .foregroundStyle(Theme.textPrimary)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

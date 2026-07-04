import SwiftUI
import UIKit

/// Manage saved searches: the queries (and domains) Ember watches, each with a
/// per-search notification toggle. Pushed within an existing navigation stack
/// (the Me tab, or Settings when signed out).
struct SavedSearchesView: View {
    @Environment(SavedSearchStore.self) private var store
    @Environment(NotificationService.self) private var notifications
    @Environment(\.openURL) private var openURL
    @State private var showingAdd = false

    var body: some View {
        Form {
            if store.searches.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "bell.badge",
                        title: "No Saved Searches",
                        message: "Save a search to be notified when new matching stories are posted — like links to your own site.")
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(store.searches) { search in
                        row(for: search)
                    }
                    .onDelete { offsets in
                        for index in offsets { store.remove(store.searches[index].id) }
                    }
                } footer: {
                    Text("Checked each time you refresh the Stories feed. New matches arrive as notifications.")
                }
            }

            if notifications.authorizationStatus == .denied {
                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label("Notifications Are Off — Open Settings", systemImage: "bell.slash")
                    }
                } footer: {
                    Text("Turn on notifications for Ember to receive saved-search alerts.")
                }
            }
        }
        .navigationTitle("Saved Searches")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Saved Search")
            }
        }
        .sheet(isPresented: $showingAdd) { AddSavedSearchView() }
        .task { await notifications.refreshStatus() }
    }

    private func row(for search: SavedSearch) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: search.scope.systemImage)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(search.displayLabel)
                    .foregroundStyle(Theme.textPrimary)
                Text(search.scope.title)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Toggle("Notify", isOn: Binding(
                get: { search.notify },
                set: { newValue in Task { await store.setNotify(newValue, for: search.id) } }
            ))
            .labelsHidden()
        }
    }
}

/// Sheet for creating a saved search. Can be prefilled (e.g. from the Search tab).
struct AddSavedSearchView: View {
    @Environment(SavedSearchStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var scope: SavedSearch.Scope
    /// Once the user picks a scope by hand, stop auto-inferring it from the query.
    @State private var scopeManuallySet = false
    @State private var notify = true
    @State private var isSaving = false

    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
        _scope = State(initialValue: .inferred(from: initialQuery))
    }

    private var canSave: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(scope == .domain ? "example.com" : "keywords", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(scope == .domain ? .URL : .default)
                        .onChange(of: query) { _, newQuery in
                            // Follow the query until the user overrides the scope.
                            if !scopeManuallySet { scope = .inferred(from: newQuery) }
                        }
                    Picker("Match", selection: Binding(
                        get: { scope },
                        set: { scope = $0; scopeManuallySet = true }
                    )) {
                        ForEach(SavedSearch.Scope.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } footer: {
                    Text(scope == .domain
                         ? "Watch a website. You'll be alerted when links to this domain are posted to Hacker News."
                         : "Match these words anywhere in a story's title, text, or URL.")
                }
                Section {
                    Toggle("Notify Me", isOn: $notify)
                } footer: {
                    Text("Ember checks each time you refresh the Stories feed.")
                }
            }
            .navigationTitle("New Saved Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await store.add(query: query, scope: scope, notify: notify,
                                            using: LiveHNService.shared)
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

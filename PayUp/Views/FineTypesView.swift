import SwiftUI

struct FineTypesView: View {
    @Environment(\.teamDataStore) private var store

    @State private var editing: FineType?
    @State private var pendingDelete: FineType?
    @State private var error: String?
    @State private var newName = ""
    @State private var newAmount = ""
    @State private var queue: RapidEntryQueue<FineTypeDraft>?
    @State private var warning: String?
    @FocusState private var focus: Field?

    private enum Field { case name, amount }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ScreenHeader(title: "Fines", subtitle: subtitle)

                    DataStateContainer(state: store.state, refreshError: store.refreshError, retry: { await store.refresh() }) {
                        addRow

                        if let warning {
                            Text(warning)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        ForEach(queue?.visibleDrafts ?? []) { draft in
                            PendingRow(
                                title: draft.payload.name,
                                detail: Money.string(draft.payload.amountPence),
                                state: draft.state,
                                retry: { queue?.retry(draft.id) },
                                discard: { queue?.discard(draft.id) }
                            )
                        }

                        if let error {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: 0xFF6B6B))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        if store.fineTypes.isEmpty && (queue?.visibleDrafts.isEmpty ?? true) {
                            EmptyStateView(
                                icon: "sterlingsign.circle",
                                title: "No fines yet",
                                message: "These are the offences and what each one costs — gloves, late arrival, own goal, whatever your club has agreed. Build the list that matches your rules.",
                                actionTitle: "Add your first fine",
                                action: { focus = .name }
                            )
                        } else {
                            ForEach(store.fineTypes) { type in
                                Button { editing = type } label: { FineTypeRow(type: type) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button { setActive(type, !type.active) } label: {
                                            Label(
                                                type.active ? "Archive" : "Restore",
                                                systemImage: type.active ? "archivebox" : "arrow.uturn.backward"
                                            )
                                        }
                                        Button(role: .destructive) { pendingDelete = type } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .refreshable { await store.refresh() }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .task { await store.loadIfNeeded() }
            .sheet(item: $editing) { type in
                FineTypeEditor(type: type).environment(\.teamDataStore, store)
            }
            .alert(
                pendingDelete.map { "Delete \($0.name)?" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { type in
                Button("Delete", role: .destructive) { delete(type) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { type in
                Text(deleteMessage(for: type))
            }
        }
    }

    private var subtitle: String {
        store.fineTypes.isEmpty ? "The offences and their amounts" : "Tap to edit · long-press to archive"
    }

    /// Same rapid-entry treatment as the squad: building a fines list is the
    /// first thing a new owner does, and it's the same typing task.
    private var addRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accent)

            TextField("", text: $newName, prompt: Text("Add offence").foregroundStyle(Theme.textFaint))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.beige)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .name)
                .onSubmit { focus = .amount }

            Text("£")
                .font(.tally(16, .bold))
                .foregroundStyle(Theme.accent)
            TextField("", text: $newAmount, prompt: Text("2").foregroundStyle(Theme.textFaint))
                .font(.tally(16, .bold))
                .foregroundStyle(Theme.beige)
                .keyboardType(.decimalPad)
                .frame(width: 46)
                .focused($focus, equals: .amount)

            Button(action: add) {
                Image(systemName: "return")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canAdd ? Theme.bg : Theme.textFaint)
                    .frame(width: 32, height: 32)
                    .background(canAdd ? Theme.accent : Theme.surfaceHi, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .cardSurface()
    }

    private var canAdd: Bool {
        EntryValidation.cleanName(newName) != nil && (Money.pence(from: newAmount) ?? -1) >= 0
    }

    private func add() {
        guard let name = EntryValidation.cleanName(newName),
              let pence = Money.pence(from: newAmount) else { return }
        warning = EntryValidation.duplicateWarning(
            for: name, existing: store.fineTypes.map(\.name)
        )
        newName = ""
        newAmount = ""
        focus = .name
        Haptics.tap()
        ensureQueue().submit(FineTypeDraft(name: name, amountPence: pence))
    }

    private func ensureQueue() -> RapidEntryQueue<FineTypeDraft> {
        if let queue { return queue }
        let created = RapidEntryQueue<FineTypeDraft> { draft in
            try await store.addFineType(name: draft.name, amountPence: draft.amountPence)
        }
        queue = created
        return created
    }

    private func setActive(_ type: FineType, _ active: Bool) {
        error = nil
        Task {
            do { try await store.setFineTypeActive(type, active: active) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Deleting only removes the link — issued fines keep their own description
    /// and amount, so nothing in the history becomes unreadable.
    private func deleteMessage(for type: FineType) -> String {
        let issued = store.fines.count { $0.fineTypeId == type.id }
        guard issued > 0 else { return "It's never been used, so nothing else changes." }
        return "It's been issued \(issued) time\(issued == 1 ? "" : "s"). Those fines keep their name and amount — only the option to give it again goes. Archive it instead if you might want it back."
    }

    private func delete(_ type: FineType) {
        pendingDelete = nil
        error = nil
        Task {
            do { try await store.deleteFineType(type) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct FineTypeRow: View {
    let type: FineType

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(type.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(type.active ? Theme.beige : Theme.textDim)
                if !type.active {
                    Text("Archived")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            Spacer(minLength: 6)
            Text(Money.string(type.amountPence))
                .font(.tally(17, .bold))
                .foregroundStyle(type.active ? Theme.accent : Theme.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }
}

struct FineTypeEditor: View {
    @Environment(\.teamDataStore) private var store
    @Environment(\.dismiss) private var dismiss

    let type: FineType?

    @State private var name = ""
    @State private var amountText = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var amountPence: Int? { Money.pence(from: amountText) }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (amountPence ?? -1) >= 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Offence")
                        TextField("", text: $name, prompt: Text("e.g. Late arrival").foregroundStyle(Theme.textFaint))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.beige)
                            .textInputAutocapitalization(.sentences)
                            .focused($nameFocused)
                            .padding(16)
                            .cardSurface()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Amount")
                        HStack(spacing: 4) {
                            Text("£")
                                .font(.tally(24, .bold))
                                .foregroundStyle(Theme.accent)
                            TextField("", text: $amountText, prompt: Text("2").foregroundStyle(Theme.textFaint))
                                .font(.tally(24, .bold))
                                .foregroundStyle(Theme.beige)
                                .keyboardType(.decimalPad)
                        }
                        .padding(16)
                        .cardSurface()
                    }

                    if let error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xFF6B6B))
                    }

                    Button(busy ? "Saving…" : (type == nil ? "Add fine" : "Save"), action: save)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(busy || !isValid)

                    if type != nil {
                        Text("Editing the amount won't change fines already issued — each one keeps what it was worth on the day.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textDim)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle(type == nil ? "New fine" : "Edit fine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.textDim)
                }
            }
        }
        .presentationBackground(Theme.bg)
        .onAppear {
            if let type {
                name = type.name
                amountText = Money.string(type.amountPence).replacingOccurrences(of: "£", with: "")
            } else {
                nameFocused = true
            }
        }
    }

    private func save() {
        guard isValid, let amountPence else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        busy = true
        error = nil
        Task {
            do {
                if let type {
                    try await store.updateFineType(type, name: trimmed, amountPence: amountPence)
                } else {
                    try await store.addFineType(name: trimmed, amountPence: amountPence)
                }
                Haptics.bump()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

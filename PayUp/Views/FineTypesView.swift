import SwiftUI
import SwiftData

struct FineTypesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.teamSession) private var session
    @Query(sort: [SortDescriptor(\FineType.sortOrder)]) private var allTypes: [FineType]

    private var types: [FineType] { allTypes.scoped(to: session.team?.id) }

    @State private var editing: FineType?
    @State private var creatingNew = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ScreenHeader(title: "Fines", subtitle: "Tap to edit · long-press to archive") {
                        HeaderAddButton { creatingNew = true }
                    }

                    ForEach(types) { type in
                        Button {
                            editing = type
                        } label: {
                            FineTypeRow(type: type)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                type.isArchived.toggle()
                                try? context.save()
                            } label: {
                                Label(type.isArchived ? "Restore" : "Archive",
                                      systemImage: type.isArchived ? "arrow.uturn.backward" : "archivebox")
                            }
                            Button(role: .destructive) { delete(type) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $editing) { type in
                FineTypeEditor(type: type)
            }
            .sheet(isPresented: $creatingNew) {
                FineTypeEditor(type: nil, nextSortOrder: (types.map(\.sortOrder).max() ?? -1) + 1)
            }
        }
    }

    private func delete(_ type: FineType) {
        context.delete(type)
        try? context.save()
    }
}

private struct FineTypeRow: View {
    let type: FineType

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(type.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(type.isArchived ? Theme.textDim : Theme.beige)
                if type.isArchived {
                    Text("Archived")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                } else if !type.fines.isEmpty {
                    Text("\(type.fines.count) issued")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                }
            }
            Spacer(minLength: 6)
            Text(Money.string(type.amountPence))
                .font(.tally(17, .bold))
                .foregroundStyle(type.isArchived ? Theme.textFaint : Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }
}

struct FineTypeEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.teamSession) private var session

    let type: FineType?
    var nextSortOrder: Int = 0

    @State private var name = ""
    @State private var amountText = ""
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

                    Button(type == nil ? "Add fine" : "Save", action: save)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(!isValid)

                    if let existing = type, !existing.fines.isEmpty {
                        Text("Editing the amount won't change the \(existing.fines.count) already issued — those keep what they were worth on the day.")
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
        if let type {
            type.name = trimmed
            type.amountPence = amountPence
        } else {
            context.insert(FineType(
                name: trimmed,
                amountPence: amountPence,
                sortOrder: nextSortOrder,
                teamId: session.team?.id
            ))
        }
        try? context.save()
        Haptics.bump()
        dismiss()
    }
}

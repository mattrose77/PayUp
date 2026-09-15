import SwiftUI

struct TeamSettingsView: View {
    @Environment(\.teamSession) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var copied = false
    @State private var pendingRemoval: TeamMember?
    @State private var confirmingLeave = false
    @State private var error: String?

    private var team: Team? { session.team }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    nameSection
                    membersSection
                    if let error {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: 0xFF6B6B))
                    }
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.textDim)
                }
            }
        }
        .presentationBackground(Theme.bg)
        .onAppear { name = team?.name ?? "" }
        .alert(
            pendingRemoval.map { "Remove \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { member in
            Button("Remove", role: .destructive) { remove(member) }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("They'll lose access to the team. Players, matchdays and fines all stay exactly as they are.")
        }
        .alert("Leave this team?", isPresented: $confirmingLeave) {
            Button("Leave", role: .destructive) { leave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need the join code to get back in. Nothing about the team's fines changes.")
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Team name")
            TextField("", text: $name, prompt: Text("e.g. Minety FC").foregroundStyle(Theme.textFaint))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.beige)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(16)
                .cardSurface()
                .onSubmit(saveName)
            Button("Save name", action: saveName)
                .buttonStyle(QuietButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Members

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Members")
                Spacer()
                Text("\(session.members.count) of \(TeamRules.maxMembers)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }

            ForEach(session.members) { member in
                memberRow(member)
            }

            if !session.isFull {
                emptySlot
            }
        }
    }

    private func memberRow(_ member: TeamMember) -> some View {
        let isMe = member.userId == session.currentMember?.userId
        let canRemove = session.isOwner && member.role != .owner
        let canLeave = isMe && member.role != .owner

        return HStack(spacing: 13) {
            Avatar(initials: member.initials, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(member.displayName + (isMe ? " (you)" : ""))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.beige)
                Text(member.role.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 6)

            if canRemove {
                Button("Remove") { pendingRemoval = member }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFF6B6B))
                    .buttonStyle(.plain)
            } else if canLeave {
                Button("Leave team") { confirmingLeave = true }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFF6B6B))
                    .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    private var emptySlot: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Invite one other person to help run the fines. They'll have the same access as you.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            Text(team?.joinCode ?? "—")
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)

            HStack(spacing: 10) {
                Button(action: copyCode) {
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                }
                .buttonStyle(QuietButtonStyle())

                if let code = team?.joinCode {
                    ShareLink(item: shareMessage(code)) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share")
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }

            if session.isOwner {
                Button("Generate a new code", action: regenerate)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(Theme.surfaceHi, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }

    // MARK: - Actions

    private func shareMessage(_ code: String) -> String {
        "Join \(team?.name ?? "our team") on PayUp. Code: \(code)"
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        run { try await session.rename(to: trimmed) }
    }

    private func copyCode() {
        guard let code = team?.joinCode else { return }
        UIPasteboard.general.string = code
        Haptics.bump()
        withAnimation(.snappy(duration: 0.2)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }

    private func regenerate() {
        run { try await session.regenerateJoinCode() }
    }

    private func remove(_ member: TeamMember) {
        pendingRemoval = nil
        run { try await session.remove(member) }
    }

    private func leave() {
        run {
            try await session.leave()
            dismiss()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        error = nil
        Task {
            do {
                try await work()
                Haptics.bump()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

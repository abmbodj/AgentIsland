import SwiftUI

/// The title keeps its place in the row while editing, with explicit save and cancel controls.
struct SessionTitle: View {
    @ObservedObject var model: PanelModel
    let keys: [String]
    let title: String
    @FocusState private var focused: Bool
    private var editing: Bool { model.isEditingTitle(keys) }

    var body: some View {
        HStack(spacing: 2) {
            if editing {
                TextField("Session title", text: $model.titleDraft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 40, minHeight: 22)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: Theme.secondary), lineWidth: 1))
                    .onSubmit { model.saveTitle() }
                    .accessibilityLabel("Session title")
                    .accessibilityHint("Return saves. Escape cancels. Clear the title to restore its original name.")
                titleButton("checkmark", label: "Save title") { model.saveTitle() }
                titleButton("xmark", label: "Cancel rename") { model.editingTitle = nil }
            } else {
                Text(title).lineLimit(1)
                titleButton("pencil", label: "Rename session") { model.editTitle(keys: keys, title: title) }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color(nsColor: Theme.ink))
        .onAppear { if editing { DispatchQueue.main.async { focused = true } } }
        .onDisappear { if editing { model.editingTitle = nil } }
        .onChange(of: editing) { _, editing in
            if editing {
                // The controller first makes the non-activating panel key; then the new field can focus.
                DispatchQueue.main.async { focused = true }
            } else { focused = false }
        }
    }

    private func titleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(nsColor: Theme.secondary))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(radius: 4))
        .help(label)
        .accessibilityLabel(label)
    }
}

import SwiftUI

struct PlanReaderSource: Equatable {
    var session: SessionInfo?
}

extension PanelModel {
    var planVisibleEntries: [ChatEntry] {
        entries.filter { entry in
            guard entry.kind == "assistant" || (entry.kind == "tool" && entry.name == "ExitPlanMode") else { return true }
            guard let anchor = plans.compactMap(\.entryIndex).last(where: { $0 < entry.index }) else { return true }
            return entries.contains { $0.index > anchor && $0.index < entry.index && $0.kind == "user" }
        }
    }

    func openSessionPlan(_ session: SessionInfo) {
        planReader = PlanReaderSource(session: session)
        planVersion = nil
        editingPlan = false
    }
    var readerSession: SessionInfo? {
        guard let original = planReader?.session else { return nil }
        return snapshot.sessions.first { $0.id == original.id } ?? original
    }
    var readerPlans: [ChatPlan] {
        guard let session = readerSession else { return plans }
        if let documents = session.plans, !documents.isEmpty { return documents }
        if let request = session.pending.last(where: { $0.kind == "plan" || $0.tool == "ExitPlanMode" }) {
            return [ChatPlan(version: 1, markdown: request.detail, status: "ready")]
        }
        if let original = planReader?.session {
            if let documents = original.plans, !documents.isEmpty { return documents }
            if let request = original.pending.last(where: { $0.kind == "plan" || $0.tool == "ExitPlanMode" }) {
                return [ChatPlan(version: 1, markdown: request.detail, status: "unavailable")]
            }
        }
        return []
    }
    var selectedPlan: ChatPlan? { readerPlans.first { $0.version == planVersion } ?? readerPlans.last }
    var sourcePlanActive: Bool {
        guard let original = planReader?.session else { return true }
        guard let live = snapshot.sessions.first(where: { $0.id == original.id }), ![.ended, .stale, .error].contains(live.state) else { return false }
        if let request = original.pending.last(where: { $0.kind == "plan" || $0.tool == "ExitPlanMode" }) {
            return live.pending.contains { $0.id == request.id }
        }
        return live.hasPlan
    }
    func decidePlan(_ plan: ChatPlan, action: String) {
        guard !sendingPlan, let chat, chat.handoff == nil, !disconnected, plan.status == "ready", plans.last(where: { $0.status != "unavailable" })?.version == plan.version else { return }
        sendingPlan = true; planError = nil
        let id = chat.id
        let feedback = planFeedback
        DispatchQueue.global().async {
            var request: [String: Any] = ["op": "chatPlan", "id": id, "version": plan.version, "action": action]
            if action == "revise" { request["feedback"] = feedback }
            let result = Result { try CoreBridge.shared.call(request) }
            DispatchQueue.main.async { [self] in
                sendingPlan = false
                guard self.chat?.id == id else { return }
                switch result {
                case .success:
                    replySettings = nil
                    if action != "revise" { planFeedback = "" }
                    editingPlan = false
                case let .failure(error): planError = error.localizedDescription
                }
                pollChat()
            }
        }
    }
}

struct InlinePlan: View {
    @ObservedObject var model: PanelModel
    let plan: ChatPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Plan · v\(plan.version)", systemImage: "doc.text").fontWeight(.semibold); Spacer(); Label(plan.status == "ready" ? "Ready for review" : plan.status.capitalized, systemImage: plan.status == "ready" ? "exclamationmark.circle" : "doc.text").foregroundStyle(plan.status == "ready" ? Color(nsColor: Theme.amber) : Color(nsColor: Theme.secondary)) }
                .font(.system(size: 12))
            ScrollView { MarkdownDocument(markdown: plan.markdown).padding(.trailing, 4) }.frame(maxHeight: 220)
            Button("Expand plan") { model.planVersion = plan.version; model.planReader = PlanReaderSource(); model.editingPlan = false }
                .buttonStyle(.borderless)
            PlanActions(model: model, plan: plan, historical: model.plans.last(where: { $0.status != "unavailable" })?.version != plan.version)
        }.padding(10).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PlanReader: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.readerSession?.project ?? model.chat?.title ?? "Plan").lineLimit(1).fontWeight(.semibold)
                    Text(Fmt.agentName(model.readerSession?.agent ?? model.chat?.agent ?? "claude")).font(.system(size: 10)).foregroundStyle(Color(nsColor: Theme.secondary))
                }
                Spacer()
                if let plan = model.selectedPlan {
                    Picker("Version", selection: Binding(get: { model.selectedPlan?.version ?? 1 }, set: { model.planVersion = $0; model.editingPlan = false })) {
                        ForEach(model.readerPlans) { p in Text("v\(p.version) · \(p.status)").tag(p.version) }
                    }.labelsHidden().fixedSize()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(plan.markdown, forType: .string) }.buttonStyle(.borderless)
                }
            }.font(.system(size: 12))
            if let plan = model.selectedPlan, !plan.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView { MarkdownDocument(markdown: plan.markdown).padding(.vertical, 4) }
                if model.readerSession == nil {
                    PlanActions(model: model, plan: plan, historical: model.readerPlans.last(where: { $0.status != "unavailable" })?.version != plan.version)
                }
            } else {
                Text("Plan content is unavailable. Continue in the source session to review it.").font(.system(size: 13))
                Spacer()
            }
            if let session = model.readerSession {
                Text(model.sourcePlanActive ? "Complete the plan decision in \(Fmt.agentName(session.agent))." : "This plan request is no longer active. Saved content remains available.")
                    .font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.secondary))
                Button("Continue in \(Fmt.agentName(session.agent))") { model.onJump(session) }.buttonStyle(.borderedProminent).tint(Color(nsColor: Theme.ink)).foregroundStyle(Color.black)
            }
        }.padding(12).frame(maxWidth: .infinity).frame(height: PanelModel.chatHeight)
            .background(Color.black).foregroundStyle(Color(nsColor: Theme.ink))
    }
}

struct PlanActions: View {
    @ObservedObject var model: PanelModel
    let plan: ChatPlan
    var historical: Bool
    private var disabled: Bool { model.sendingPlan || model.disconnected || model.chatStatus == "running" || model.chat?.handoff != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.planError ?? plan.error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).textSelection(.enabled) }
            if historical { Text("Historical version").font(.system(size: 12)) }
            else if plan.status == "ready" {
                if model.editingPlan {
                    Text("Revision feedback").font(.system(size: 12, weight: .semibold))
                    TextEditor(text: $model.planFeedback).font(.system(size: 13)).frame(height: 64)
                        .accessibilityLabel("Revision feedback")
                        .onTapGesture { model.onSummon() }
                    HStack {
                        Button("Cancel") { model.editingPlan = false }.disabled(model.sendingPlan)
                        Spacer()
                        Button(model.sendingPlan ? "Sending…" : "Send feedback") { model.decidePlan(plan, action: "revise") }
                            .disabled(disabled || model.planFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    HStack {
                        Button("Reject plan") { model.decidePlan(plan, action: "reject") }
                        Button("Revise plan") { model.editingPlan = true; model.onSummon() }
                        Spacer()
                        Button(model.sendingPlan ? "Sending…" : "Implement plan") { model.decidePlan(plan, action: "implement") }.buttonStyle(.borderedProminent).tint(Color(nsColor: Theme.ink)).foregroundStyle(Color.black)
                    }.disabled(disabled)
                }
            } else { Text(plan.status == "writing" ? "Writing plan…" : plan.status.capitalized).font(.system(size: 12)) }
        }.buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.ink))
    }
}

//! Full-source, version-scoped review decisions. A process ending alone never completes a plan.
//! A plan joins the transcript only once it is finished; a failed draft leaves nothing behind.
use serde::Serialize;
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub version: u64,
    pub markdown: String,
    pub status: &'static str,
    /// The transcript row the finished plan sits at; none while writing.
    pub entry_index: Option<usize>,
    pub error: Option<String>,
}
#[derive(Debug, Default)]
pub struct PlanBook { documents: Vec<Plan> }
impl PlanBook {
    pub fn documents(&self) -> &[Plan] { &self.documents }
    pub fn supersede_ready(&mut self) {
        for plan in &mut self.documents {
            if plan.status == "ready" { plan.status = "superseded"; }
        }
    }
    pub fn latest(&self) -> Option<&Plan> { self.documents.last() }
    pub fn begin(&mut self) -> u64 {
        let version = self.latest().map_or(1, |p| p.version + 1);
        self.documents.push(Plan { version, markdown: String::new(), status: "writing", entry_index: None, error: None });
        version
    }
    pub fn update(&mut self, markdown: &str) {
        if let Some(p) = self.documents.last_mut().filter(|p| p.status == "writing") { p.markdown = markdown.into(); }
    }
    /// Whether the draft being written has content worth showing.
    pub fn has_draft(&self) -> bool { self.latest().is_some_and(|p| p.status == "writing" && !p.markdown.trim().is_empty()) }
    /// `Some(row)` places the finished plan at that transcript row; `None` drops the draft.
    pub fn finish(&mut self, entry_index: Option<usize>) {
        if !self.latest().is_some_and(|p| p.status == "writing") { return }
        let len = self.documents.len();
        match entry_index {
            Some(i) => {
                let p = &mut self.documents[len - 1];
                p.status = "ready"; p.entry_index = Some(i);
                for p in &mut self.documents[..len - 1] { if matches!(p.status, "ready" | "revising") { p.status = "superseded"; } }
            }
            None => {
                self.documents.pop();
                for p in &mut self.documents { if p.status == "revising" { p.status = "ready"; } }
            }
        }
    }
    /// A plan read from an external session's history: shown, but decided in its own app.
    pub fn record(&mut self, markdown: &str, entry_index: usize) {
        let version = self.latest().map_or(1, |p| p.version + 1);
        self.documents.push(Plan { version, markdown: markdown.into(), status: "proposed", entry_index: Some(entry_index), error: None });
    }
    pub fn decide(&mut self, version: u64, action: &str, feedback: &str) -> Result<(), String> {
        let p = self.documents.iter_mut().rev().find(|p| p.status != "unavailable").ok_or("No plan is ready.")?;
        if p.version != version || p.status != "ready" { return Err("That plan is no longer ready for a decision.".into()); }
        p.status = match action { "implement" => "implementing", "reject" => "rejected", "revise" if !feedback.trim().is_empty() => "revising", "revise" => return Err("Write revision feedback first.".into()), _ => return Err("Unknown plan action.".into()) };
        p.error = None; Ok(())
    }
    pub fn launch_failed(&mut self, version: u64, error: &str) {
        if let Some(p) = self.documents.iter_mut().find(|p| p.version == version) { p.status = "ready"; p.error = Some(error.into()); }
    }
}

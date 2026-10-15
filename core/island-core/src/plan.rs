//! Full-source, version-scoped review decisions. A process ending alone never completes a plan.
use serde::Serialize;
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub version: u64,
    pub markdown: String,
    pub status: &'static str,
    pub entry_index: usize,
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
    pub fn begin(&mut self, entry_index: usize) -> u64 {
        let version = self.latest().map_or(1, |p| p.version + 1);
        self.documents.push(Plan { version, markdown: String::new(), status: "writing", entry_index, error: None });
        version
    }
    pub fn update(&mut self, markdown: &str) {
        if let Some(p) = self.documents.last_mut().filter(|p| p.status == "writing") { p.markdown = markdown.into(); }
    }
    pub fn finish(&mut self, success: bool, error: Option<String>) {
        let ready = success && self.latest().is_some_and(|p| !p.markdown.trim().is_empty());
        if let Some(p) = self.documents.last_mut().filter(|p| p.status == "writing") {
            p.status = if ready { "ready" } else { "unavailable" }; p.error = error;
        } else { return }
        if ready { let len = self.documents.len(); for p in &mut self.documents[..len-1] { if matches!(p.status, "ready" | "revising") { p.status = "superseded"; } } }
        else { let len = self.documents.len(); for p in &mut self.documents[..len-1] { if p.status == "revising" { p.status = "ready"; } } }
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

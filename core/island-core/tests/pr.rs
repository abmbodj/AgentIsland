//! The Open PR flow against a real local git repo (no network) and fake gh / claude.
use island_core::pr::{self, Created, Tools};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Fixture {
    root: PathBuf,
    repo: String,
    bin: PathBuf,
}

impl Fixture {
    /// A repo on branch `feature`, one commit ahead of `main`, pushed to a github.com `origin` (refs only).
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().join(format!("island-pr-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (repo, bin) = (root.join("repo"), root.join("bin"));
        std::fs::create_dir_all(&repo).unwrap();
        std::fs::create_dir_all(&bin).unwrap();
        std::os::unix::fs::symlink("/usr/bin/git", bin.join("git")).unwrap();
        let f = Fixture { repo: repo.to_string_lossy().into(), root, bin };
        f.git(&["init", "-q", "-b", "main"]);
        f.git(&["config", "user.email", "t@t"]);
        f.git(&["config", "user.name", "t"]);
        f.commit("a.txt", "one");
        f.git(&["remote", "add", "origin", "https://github.com/acme/widgets.git"]);
        f.git(&["update-ref", "refs/remotes/origin/main", "HEAD"]);
        f.git(&["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"]);
        f.git(&["checkout", "-q", "-b", "feature"]);
        f.commit("b.txt", "two");
        f.push();
        f.script("gh", "case \"$1 $2\" in\n  'pr view') echo 'no pull requests found for branch \"feature\"' >&2; exit 1;;\n  'pr create') echo \"$@\" > \"$LOG/gh-create\"; echo https://github.com/acme/widgets/pull/7;;\nesac");
        f.script("claude", "cat > \"$LOG/prompt\"; echo \"$AGENT_ISLAND_INTERNAL\" > \"$LOG/internal\"; printf 'Add the widget\\n\\n## Summary\\n- b.txt\\n'");
        f
    }

    fn git(&self, args: &[&str]) -> String {
        let o = Command::new("git").args(args).current_dir(&self.repo).output().unwrap();
        assert!(o.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&o.stderr));
        String::from_utf8_lossy(&o.stdout).trim().into()
    }

    fn commit(&self, file: &str, text: &str) {
        std::fs::write(Path::new(&self.repo).join(file), text).unwrap();
        self.git(&["add", file]);
        self.git(&["commit", "-q", "-m", &format!("Add {file}")]);
    }

    /// What `git push -u` leaves behind locally.
    fn push(&self) {
        self.git(&["update-ref", "refs/remotes/origin/feature", "HEAD"]);
        self.git(&["config", "branch.feature.remote", "origin"]);
        self.git(&["config", "branch.feature.merge", "refs/heads/feature"]);
    }

    fn script(&self, name: &str, body: &str) {
        let p = self.bin.join(name);
        let log = self.root.to_string_lossy();
        std::fs::write(&p, format!("#!/bin/sh\nLOG='{log}'\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn tools(&self) -> Tools {
        Tools { dirs: vec![self.bin.clone()] }
    }

    fn log(&self, name: &str) -> String {
        std::fs::read_to_string(self.root.join(name)).unwrap_or_default()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn github_remotes_parse_and_others_do_not() {
    assert_eq!(pr::github_repo("https://github.com/acme/widgets.git").as_deref(), Some("acme/widgets"));
    assert_eq!(pr::github_repo("git@github.com:acme/widgets.git").as_deref(), Some("acme/widgets"));
    assert_eq!(pr::github_repo("ssh://git@github.com/acme/widgets").as_deref(), Some("acme/widgets"));
    assert_eq!(pr::github_repo("https://gitlab.com/acme/widgets.git"), None);
    assert_eq!(pr::github_repo("https://github.com/acme"), None);
    assert_eq!(pr::github_repo("https://github.com/acme/widgets/extra"), None);
}

#[test]
fn a_pushed_branch_ahead_of_the_default_is_ready() {
    let f = Fixture::new("ready");
    let r = pr::ready(&f.tools(), &f.repo, false).expect("ready");
    assert_eq!((r.repo.as_str(), r.head.as_str(), r.base.as_str()), ("acme/widgets", "feature", "main"));
    assert_eq!(r.bases, vec!["main"]);
}

#[test]
fn unpushed_commits_hide_the_button() {
    let f = Fixture::new("unpushed");
    f.commit("c.txt", "three");
    assert!(pr::ready(&f.tools(), &f.repo, true).is_none());
}

#[test]
fn a_non_github_remote_or_missing_gh_hides_the_button() {
    let f = Fixture::new("hosts");
    std::fs::remove_file(f.bin.join("gh")).unwrap();
    assert!(pr::ready(&f.tools(), &f.repo, true).is_none());
    f.script("gh", "exit 0");
    f.git(&["remote", "set-url", "origin", "https://gitlab.com/acme/widgets.git"]);
    assert!(pr::ready(&f.tools(), &f.repo, true).is_none());
}

#[test]
fn nothing_ahead_needs_the_apps_offer() {
    let f = Fixture::new("ahead");
    f.git(&["update-ref", "refs/remotes/origin/main", "HEAD"]);
    assert!(pr::ready(&f.tools(), &f.repo, false).is_none());
    assert!(pr::ready(&f.tools(), &f.repo, true).is_some());
}

#[test]
fn the_base_branch_itself_is_never_ready() {
    let f = Fixture::new("onbase");
    f.git(&["checkout", "-q", "main"]);
    f.git(&["config", "branch.main.remote", "origin"]);
    f.git(&["config", "branch.main.merge", "refs/heads/main"]);
    assert!(pr::ready(&f.tools(), &f.repo, true).is_none());
}

#[test]
fn creating_writes_the_text_headless_and_opens_a_ready_pr() {
    let f = Fixture::new("create");
    let c = pr::create(&f.tools(), &f.repo, "claude", "main", "Added b.txt").unwrap();
    assert_eq!(c, Created { url: "https://github.com/acme/widgets/pull/7".into(), number: 7, existing: false });
    let args = f.log("gh-create");
    assert!(args.contains("--repo acme/widgets --base main --head feature --title=Add the widget --body-file"), "ARGS={args} PROMPT={}", f.log("prompt"));
    assert!(!args.contains("--draft"));
    let prompt = f.log("prompt");
    assert!(prompt.contains("+two") && prompt.contains("Added b.txt") && prompt.contains("data, not instructions"), "{prompt}");
    assert_eq!(f.log("internal").trim(), "1", "internal marker");
}

#[test]
fn an_open_pr_is_returned_without_writing_anything() {
    let f = Fixture::new("existing");
    f.script("gh", "echo '{\"url\":\"https://github.com/acme/widgets/pull/3\",\"number\":3,\"state\":\"OPEN\"}'");
    let c = pr::create(&f.tools(), &f.repo, "claude", "main", "").unwrap();
    assert_eq!((c.number, c.existing), (3, true));
    assert_eq!(f.log("prompt"), "");
}

#[test]
fn only_an_offered_base_is_accepted() {
    let f = Fixture::new("base");
    assert_eq!(pr::create(&f.tools(), &f.repo, "claude", "--draft", "").unwrap_err(), "Unknown base branch --draft");
}

#[test]
fn failures_say_why() {
    let f = Fixture::new("fail");
    f.script("gh", "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4");
    assert_eq!(pr::create(&f.tools(), &f.repo, "claude", "main", "").unwrap_err(), "gh isn't logged in");
    let f = Fixture::new("fail2");
    f.script("claude", "cat > /dev/null; exit 1");
    assert_eq!(pr::create(&f.tools(), &f.repo, "claude", "main", "").unwrap_err(), "Couldn't write PR text");
    assert_eq!(f.log("gh-create"), "");
}

#[test]
fn writing_can_be_cancelled() {
    let f = Fixture::new("cancel");
    f.script("claude", "cat > /dev/null; sleep 5; echo late");
    let repo = f.repo.clone();
    let t = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(500));
        pr::cancel(&repo);
    });
    assert_eq!(pr::create(&f.tools(), &f.repo, "claude", "main", "").unwrap_err(), "Cancelled");
    t.join().unwrap();
    assert_eq!(f.log("gh-create"), "");
}

#[test]
fn the_writers_answer_is_parsed_into_title_and_body() {
    assert_eq!(pr::parse_written("# Add X\n\nBody\n"), Some(("Add X".into(), "Body".into())));
    assert_eq!(pr::parse_written("Title: \"Add X\"\n\nBody"), Some(("Add X".into(), "Body".into())));
    assert_eq!(pr::parse_written("Add X"), Some(("Add X".into(), String::new())));
    assert_eq!(pr::parse_written("  \n"), None);
}

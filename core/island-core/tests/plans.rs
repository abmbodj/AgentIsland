use island_core::plan::PlanBook;
#[test]
fn preserves_source_and_validates_versioned_decisions() {
    let mut book = PlanBook::default();
    let source = format!("# Plan\n{}\n```rust\nfn main() {{}}\n```", "full source\n".repeat(1000));
    let v = book.begin();
    book.update(&source);
    book.finish(Some(2));
    assert_eq!(book.latest().unwrap().markdown, source);
    assert!(book.decide(v, "revise", "  ").is_err());
    book.decide(v, "revise", "change it").unwrap();
    assert!(book.decide(v, "implement", "").is_err());
    let next = book.begin();
    assert_eq!(next, v + 1);
    book.update("revised"); book.finish(Some(4));
    assert_eq!(book.documents()[0].status, "superseded");
    assert!(book.decide(v, "implement", "").is_err());
    book.decide(next, "reject", "").unwrap();
    assert!(book.decide(next, "implement", "").is_err());
}
#[test]
fn incomplete_generation_leaves_nothing() {
    let mut book = PlanBook::default(); let v = book.begin();
    book.update("partial"); book.finish(None);
    assert!(book.latest().is_none());
    assert!(book.decide(v, "implement", "").is_err());
}

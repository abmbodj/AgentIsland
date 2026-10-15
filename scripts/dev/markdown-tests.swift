import Foundation
@main struct MarkdownTests {
 static func main() {
  let blocks = MarkdownBlock.parse("# Heading\n\n- [x] Checked\n1. Ordered\n> Quote\n\n| A | B |\n| --- | --- |\n| x | y |\n\n```swift\nlet x = 1")
  assert(blocks.contains(.heading(1, "Heading")))
  assert(blocks.contains(.list("☑", "Checked")))
  assert(blocks.contains(.list("1.", "Ordered")))
  assert(blocks.contains(.quote("Quote")))
  assert(blocks.contains(.table([["A", "B"], ["x", "y"]])))
  assert(blocks.contains(.code("swift", "let x = 1")))
  assert(MarkdownBlock.parse("**partial [link\n<raw>") == [.paragraph("**partial [link\n<raw>")])
  assert(MarkdownBlock.parse("~~~sh\necho hi\n~~~") == [.code("sh", "echo hi")])
  print("Markdown document checks passed")
 }
}

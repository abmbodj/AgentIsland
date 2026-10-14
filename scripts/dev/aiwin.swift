// Print the island window's on-screen frame.
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Agent Island" && (w[kCGWindowLayer as String] as? Int) == 25 {
    let b = w[kCGWindowBounds as String] as! [String: Any]; print("window x=\(b["X"]!) y=\(b["Y"]!) \(b["Width"]!)x\(b["Height"]!)")
}

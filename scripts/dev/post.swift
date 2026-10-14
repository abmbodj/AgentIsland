// Debug builds only: drive the island. Usage: post <expand|respond|jump|openGroup> <arg>
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("com.abmbodj.agentisland.debug." + CommandLine.arguments[1]), object: CommandLine.arguments[2], userInfo: nil, deliverImmediately: true)

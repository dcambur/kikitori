import Foundation
import KikitoriCore

// kikitori-cli: headless checks of the pipeline pieces.
//   sources                       list apps that have audio, playing first
let args = CommandLine.arguments.dropFirst()
switch args.first {
case "sources":
    for s in try AudioSources.list() {
        print("\(s.isPlaying ? "▶︎" : " ") \(s.name)  [\(s.id)]  processes: \(s.processObjects.count)")
    }
default:
    print("usage: kikitori-cli sources")
}

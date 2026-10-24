// EXPERIMENT (for docs/design/speaker-labels.md), not product code.
//
//   swift run kk-spike-diar <audio> <out.json>
//
// FluidAudio's offline pipeline (pyannote segmentation, WeSpeaker embeddings, VBx clustering) on a
// whole file: the embedding-based reference to compare the streaming Sortformer with. Writes
// [{speaker, start, end}]; score it with Experiments/speakers/score.py --segments.
import FluidAudio
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else { print("usage: kk-spike-diar <audio> <out.json>"); exit(2) }
let manager = OfflineDiarizerManager()
try await manager.prepareModels()
let began = Date()
let result = try await manager.process(URL(fileURLWithPath: args[0]))
print(String(format: "offline diarization in %.1f s: %d segments, speakers %@", Date().timeIntervalSince(began),
             result.segments.count, Set(result.segments.map(\.speakerId)).sorted().joined(separator: ",")))
let rows = result.segments.map { ["speaker": $0.speakerId, "start": Double($0.startTimeSeconds), "end": Double($0.endTimeSeconds)] as [String: Any] }
try JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: args[1]))

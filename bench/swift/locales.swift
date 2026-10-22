import Speech
import Foundation

@main struct Main {
    static func main() async {
        let st = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
        let dt = await DictationTranscriber.supportedLocales.map(\.identifier).sorted()
        print("SpeechTranscriber supported:", st.filter { $0.hasPrefix("ja") }, "of", st.count)
        print("SpeechTranscriber installed:", installed)
        print("DictationTranscriber ja:", dt.filter { $0.hasPrefix("ja") })
    }
}

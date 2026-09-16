import Foundation
@main struct ReplaySegmentation {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let lines = try String(contentsOfFile:path,encoding:.utf8).split(separator:"\n")
        var segmenter = Segmenter(); var result:[String] = []
        for line in lines {
            let row = try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
            guard row["type"] as? String == "asr_final", let text = row["text"] as? String else { continue }
            // Replay actual authoritative ASR endpoints in order, with no invented audio.
            result += segmenter.ingest(text,final:true)
        }
        result += segmenter.flushCarry(force:true)
        for (i,text) in result.enumerated() { print("\(i+1). \(text)") }
        assert(result.contains { $0.contains("has a well thought out theory") && $0.contains("a positive future") })
        assert(result.contains { $0.contains("conventional wisdom in the") && $0.contains("Industry that I just strongly disagree with") })
        assert(result.contains { $0.contains("going to invest") && $0.contains("your values are") })
        assert(!result.contains { $0 == "Manifesto." || $0 == "lot in there." })
    }
}

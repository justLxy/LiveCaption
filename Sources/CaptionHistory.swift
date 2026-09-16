import Foundation

struct CaptionEntry: Identifiable, Equatable {
    let id: UUID
    var english: String
    var chinese: String?
}
struct CaptionHistory {
    private(set) var entries: [CaptionEntry] = []
    mutating func append(id:UUID, english:String, limit:Int) {
        entries.append(CaptionEntry(id:id,english:english,chinese:nil)); trim(to:limit)
    }
    mutating func upsert(_ segment: CaptionSegment, limit: Int) {
        if let index = entries.firstIndex(where: { $0.id == segment.id }) {
            entries[index].english = segment.english
            entries[index].chinese = nil
        } else { append(id: segment.id, english: segment.english, limit: limit) }
    }
    mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }
    mutating func translate(id:UUID, chinese:String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].chinese = chinese
    }
    mutating func trim(to limit:Int) {
        if entries.count > limit { entries.removeFirst(entries.count-limit) }
    }
}

import Foundation

struct CaptionEntry: Identifiable, Equatable {
    let id: UUID
    let english: String
    var chinese: String?
}
struct CaptionHistory {
    private(set) var entries: [CaptionEntry] = []
    mutating func append(id:UUID, english:String, limit:Int) {
        entries.append(CaptionEntry(id:id,english:english,chinese:nil)); trim(to:limit)
    }
    mutating func translate(id:UUID, chinese:String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].chinese = chinese
    }
    mutating func trim(to limit:Int) {
        if entries.count > limit { entries.removeFirst(entries.count-limit) }
    }
}

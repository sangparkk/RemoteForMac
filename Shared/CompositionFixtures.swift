import Foundation

struct CompositionFixture {
    let name: String
    let baseline: TextSnapshot
    let updates: [TextSnapshot]
    let expected: String

    static func snapshot(_ text: String, markedLength: Int = 0) -> TextSnapshot {
        let count = text.utf16.count
        return TextSnapshot(text: text, selection: TextRange(location: count, length: 0),
                            marked: markedLength == 0 ? nil : TextRange(location: count - markedLength, length: markedLength))
    }

    static let all: [CompositionFixture] = [
        .init(name: "한글 검색", baseline: snapshot(""),
              updates: [snapshot("ㅎ", markedLength: 1), snapshot("하", markedLength: 1),
                        snapshot("한", markedLength: 1), snapshot("한ㄱ", markedLength: 1),
                        snapshot("한그", markedLength: 1), snapshot("한글", markedLength: 1),
                        snapshot("한글 "), snapshot("한글 ㄱ", markedLength: 1),
                        snapshot("한글 거", markedLength: 1), snapshot("한글 검", markedLength: 1),
                        snapshot("한글 검ㅅ", markedLength: 1), snapshot("한글 검새", markedLength: 1),
                        snapshot("한글 검색", markedLength: 1), snapshot("한글 검색")], expected: "한글 검색"),
        .init(name: "겹받침", baseline: snapshot(""),
              updates: [snapshot("ㄱ", markedLength: 1), snapshot("가", markedLength: 1),
                        snapshot("갑", markedLength: 1), snapshot("값", markedLength: 1), snapshot("값")], expected: "값"),
        .init(name: "복합 모음", baseline: snapshot(""),
              updates: [snapshot("ㄱ", markedLength: 1), snapshot("고", markedLength: 1),
                        snapshot("과", markedLength: 1), snapshot("괒", markedLength: 1),
                        snapshot("과자", markedLength: 1), snapshot("과자")], expected: "과자"),
        .init(name: "한영 전환", baseline: snapshot(""),
              updates: [snapshot("ㅇ", markedLength: 1), snapshot("아", markedLength: 1),
                        snapshot("아이", markedLength: 1), snapshot("아이유", markedLength: 1)]
                + ["아이유 ", "아이유 l", "아이유 li", "아이유 liv", "아이유 live", "아이유 live 2",
                   "아이유 live 20", "아이유 live 202", "아이유 live 2026"].map { snapshot($0) }, expected: "아이유 live 2026"),
        .init(name: "조합 중 삭제", baseline: snapshot(""),
              updates: [snapshot("값", markedLength: 1), snapshot("갑", markedLength: 1),
                        snapshot("가", markedLength: 1), snapshot("ㄱ", markedLength: 1), snapshot("")], expected: ""),
        .init(name: "확정 후 연속 삭제", baseline: snapshot("한글 검색"),
              updates: ["한글 검", "한글 ", "한글", "한", ""].map { snapshot($0) }, expected: ""),
        .init(name: "선택 교체", baseline: .init(text: "기존 검색어", selection: .init(location: 3, length: 3), marked: nil),
              updates: [snapshot("기존 ㅎ", markedLength: 1), snapshot("기존 한", markedLength: 1), snapshot("기존 한")], expected: "기존 한"),
        .init(name: "중간 커서", baseline: .init(text: "앞뒤", selection: .init(location: 1, length: 0), marked: nil),
              updates: [.init(text: "앞한뒤", selection: .init(location: 2, length: 0), marked: .init(location: 1, length: 1)),
                        .init(text: "앞한뒤", selection: .init(location: 2, length: 0), marked: nil)], expected: "앞한뒤")
    ]
}

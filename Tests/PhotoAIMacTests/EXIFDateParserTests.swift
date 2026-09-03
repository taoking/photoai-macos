import Foundation
import Testing
@testable import PhotoAIMac

struct EXIFDateParserTests {
    /// 手写解析必须与被它替换掉的 `DateFormatter` 逐个输入等价，
    /// 否则重扫会悄悄改写全库的拍摄时间。
    @Test
    func matchesTheDateFormatterItReplaced() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        let inputs = [
            "2026:07:19 16:47:02",
            "1999:01:01 00:00:00",
            "2024:02:29 23:59:59",
            "2026:12:31 12:00:00",
            "0000:00:00 00:00:00",
            "2026:13:01 10:00:00",
            "2026:02:30 10:00:00",
            "2026:07:19 24:00:00",
            "2026:07:19 16:47",
            "2026-07-19 16:47:02",
            "",
            "not a date at all"
        ]

        for input in inputs {
            #expect(
                EXIFDateParser.date(from: input) == formatter.date(from: input),
                "解析结果与 DateFormatter 不一致：\(input)"
            )
        }
    }
}

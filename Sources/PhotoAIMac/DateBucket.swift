import Foundation

/// 图库的时间维度筛选。
///
/// 找照片最自然的入口是时间，而侧边栏此前十二个目的地里没有任何时间维度。
/// 本机实测 1,874 项中 1,862 项带拍摄时间（99.4%），因此按拍摄时间分桶是可靠的。
///
/// 它与 `LibraryFilter` 正交：日期决定"看哪一段时间"，筛选决定"看其中的哪些"，
/// 两者可以同时生效。
enum DateBucket: Hashable, Sendable {
    case year(Int)
    case month(year: Int, month: Int)
    case day(year: Int, month: Int, day: Int)
    /// 没有拍摄时间的照片。单独成桶而不是悄悄排除，
    /// 否则用户按日期筛选时会觉得照片凭空少了几张。
    case undated

    /// 时区在首次使用时取一次，与 `EXIFDateParser` 的处理保持一致。
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    func matches(_ asset: PhotoAsset) -> Bool {
        guard let captureDate = asset.captureDate else { return self == .undated }
        let components = Self.calendar.dateComponents([.year, .month, .day], from: captureDate)
        switch self {
        case let .year(year):
            return components.year == year
        case let .month(year, month):
            return components.year == year && components.month == month
        case let .day(year, month, day):
            return components.year == year && components.month == month && components.day == day
        case .undated:
            return false
        }
    }

    var title: String {
        switch self {
        case let .year(year):
            return "\(year) 年"
        case let .month(_, month):
            return "\(month) 月"
        case let .day(_, _, day):
            return "\(day) 日"
        case .undated:
            return "无拍摄时间"
        }
    }

    /// 图库标题栏上用的完整描述，需要在脱离层级的地方也能读懂。
    var fullTitle: String {
        switch self {
        case let .year(year):
            return "\(year) 年"
        case let .month(year, month):
            return "\(year) 年 \(month) 月"
        case let .day(year, month, day):
            return "\(year) 年 \(month) 月 \(day) 日"
        case .undated:
            return "无拍摄时间"
        }
    }
}

/// 侧边栏「按日期」一节的一个年份，及其下的月份。
struct DateSection: Identifiable, Hashable, Sendable {
    let year: Int
    let count: Int
    let months: [DateMonth]

    var id: Int { year }
    var bucket: DateBucket { .year(year) }
}

struct DateMonth: Identifiable, Hashable, Sendable {
    let year: Int
    let month: Int
    let count: Int
    let days: [DateDay]

    var id: Int { year * 100 + month }
    var bucket: DateBucket { .month(year: year, month: month) }
}

struct DateDay: Identifiable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    let count: Int

    var id: Int { year * 10_000 + month * 100 + day }
    var bucket: DateBucket { .day(year: year, month: month, day: day) }
}

enum DateSectionBuilder {
    /// 按年、月、日归类并统计数量。三级都按倒序排列，与图库默认的"新的在前"一致。
    ///
    /// 整棵树一次扫描算完：侧边栏每一行都现算一次会把整个资产表扫很多遍。
    static func sections(for assets: [PhotoAsset]) -> (sections: [DateSection], undatedCount: Int) {
        var countsByDay: [Int: [Int: [Int: Int]]] = [:]
        var undatedCount = 0

        for asset in assets {
            guard let captureDate = asset.captureDate else {
                undatedCount += 1
                continue
            }
            let components = DateBucket.calendar.dateComponents(
                [.year, .month, .day],
                from: captureDate
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                undatedCount += 1
                continue
            }
            countsByDay[year, default: [:]][month, default: [:]][day, default: 0] += 1
        }

        let sections = countsByDay.map { year, months in
            let monthEntries = months.map { month, days in
                DateMonth(
                    year: year,
                    month: month,
                    count: days.values.reduce(0, +),
                    days: days
                        .map { DateDay(year: year, month: month, day: $0.key, count: $0.value) }
                        .sorted { $0.day > $1.day }
                )
            }
            .sorted { $0.month > $1.month }

            return DateSection(
                year: year,
                count: monthEntries.reduce(0) { $0 + $1.count },
                months: monthEntries
            )
        }
        .sorted { $0.year > $1.year }

        return (sections, undatedCount)
    }
}

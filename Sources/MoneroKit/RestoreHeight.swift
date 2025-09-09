import Foundation

public class RestoreHeight {
    private static let DIFFICULTY_TARGET = 120
    private static let blockHeights: [String: Int64] = [
        "2014-05-01": 18844,
        "2014-06-01": 65406,
        "2014-07-01": 108882,
        "2014-08-01": 153594,
        "2014-09-01": 198072,
        "2014-10-01": 241088,
        "2014-11-01": 285305,
        "2014-12-01": 328069,
        "2015-01-01": 372369,
        "2015-02-01": 416505,
        "2015-03-01": 456631,
        "2015-04-01": 501084,
        "2015-05-01": 543973,
        "2015-06-01": 588326,
        "2015-07-01": 631187,
        "2015-08-01": 675484,
        "2015-09-01": 719725,
        "2015-10-01": 762463,
        "2015-11-01": 806528,
        "2015-12-01": 849041,
        "2016-01-01": 892866,
        "2016-02-01": 936736,
        "2016-03-01": 977691,
        "2016-04-01": 1015848,
        "2016-05-01": 1037417,
        "2016-06-01": 1059651,
        "2016-07-01": 1081269,
        "2016-08-01": 1103630,
        "2016-09-01": 1125983,
        "2016-10-01": 1147617,
        "2016-11-01": 1169779,
        "2016-12-01": 1191402,
        "2017-01-01": 1213861,
        "2017-02-01": 1236197,
        "2017-03-01": 1256358,
        "2017-04-01": 1278622,
        "2017-05-01": 1300239,
        "2017-06-01": 1322564,
        "2017-07-01": 1344225,
        "2017-08-01": 1366664,
        "2017-09-01": 1389113,
        "2017-10-01": 1410738,
        "2017-11-01": 1433039,
        "2017-12-01": 1454639,
        "2018-01-01": 1477201,
        "2018-02-01": 1499599,
        "2018-03-01": 1519796,
        "2018-04-01": 1542067,
        "2018-05-01": 1562861,
        "2018-06-01": 1585135,
        "2018-07-01": 1606715,
        "2018-08-01": 1629017,
        "2018-09-01": 1651347,
        "2018-10-01": 1673031,
        "2018-11-01": 1695128,
        "2018-12-01": 1716687,
        "2019-01-01": 1738923,
        "2019-02-01": 1761435,
        "2019-03-01": 1781681,
        "2019-04-01": 1803081,
        "2019-05-01": 1824671,
        "2019-06-01": 1847005,
        "2019-07-01": 1868590,
        "2019-08-01": 1890878,
        "2019-09-01": 1913201,
        "2019-10-01": 1934732,
        "2019-11-01": 1957051,
        "2019-12-01": 1978433,
        "2020-01-01": 2001315,
        "2020-02-01": 2023656,
        "2020-03-01": 2044552,
        "2020-04-01": 2066806,
        "2020-05-01": 2088411,
        "2020-06-01": 2110702,
        "2020-07-01": 2132318,
        "2020-08-01": 2154590,
        "2020-09-01": 2176790,
        "2020-10-01": 2198370,
        "2020-11-01": 2220670,
        "2020-12-01": 2242241,
        "2021-01-01": 2264584,
        "2021-02-01": 2286892,
        "2021-03-01": 2307079,
        "2021-04-01": 2329385,
        "2021-05-01": 2351004,
        "2021-06-01": 2373306,
        "2021-07-01": 2394882,
        "2021-08-01": 2417162,
        "2021-09-01": 2439490,
        "2021-10-01": 2461020,
        "2021-11-01": 2483377,
        "2021-12-01": 2504932,
        "2022-01-01": 2527316,
        "2022-02-01": 2549605,
        "2022-03-01": 2569711,
        "2022-04-01": 2591995,
        "2022-05-01": 2613603,
        "2022-06-01": 2635840,
        "2022-07-01": 2657395,
        "2022-08-01": 2679705,
        "2022-09-01": 2701991,
        "2022-10-01": 2723607,
        "2022-11-01": 2745899,
        "2022-12-01": 2767427,
        "2023-01-01": 2789763,
        "2023-02-01": 2811996,
        "2023-03-01": 2832118,
        "2023-04-01": 2854365,
        "2023-05-01": 2875972,
        "2025-09-01": 3490175,
    ]

    public static func getHeight(date: Date) -> Int64 {
        (try? getHeightOrEstimate(date: date)) ?? 0
    }

    private static func getHeightOrEstimate(date: Date) throws -> Int64 {
        let utcTimeZone = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone

        // Subtract 4 days to give some leeway
        guard let adjustedDate = calendar.date(byAdding: .day, value: -2, to: date) else {
            return 0
        }

        let year = calendar.component(.year, from: adjustedDate)
        let month = calendar.component(.month, from: adjustedDate)

        // Check if before May 2014 (month 5)
        if year < 2014 {
            return 0
        }
        if year == 2014 && month <= 4 {
            return 0
        }

        let query = adjustedDate

        // Date formatter for UTC
        let formatter = DateFormatter()
        formatter.timeZone = utcTimeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let queryDate = formatter.string(from: date)

        // Get first day of the month
        let firstOfMonth = calendar.dateInterval(of: .month, for: adjustedDate)!.start
        let prevDate = formatter.string(from: firstOfMonth)

        // Lookup blockheight at first of the month
        var prevBc = Self.blockHeights[prevDate]
        var currentMonth = firstOfMonth

        if prevBc == nil {
            // If too recent, go back in time and find latest one we have
            while prevBc == nil {
                guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth) else {
                    throw NSError(domain: "BlockheightError", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "endless loop looking for blockheight"])
                }

                currentMonth = previousMonth
                let currentYear = calendar.component(.year, from: currentMonth)

                if currentYear < 2014 {
                    throw NSError(domain: "BlockheightError", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "endless loop looking for blockheight"])
                }

                let currentDateString = formatter.string(from: currentMonth)
                prevBc = Self.blockHeights[currentDateString]
            }
        }

        var height = prevBc!
        let finalPrevDate = formatter.string(from: currentMonth)

        // Now we have a blockheight & a date ON or BEFORE the restore date requested
        if queryDate == finalPrevDate {
            return height
        }

        // See if we have a blockheight after this date
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth) else {
            return height
        }

        let nextDate = formatter.string(from: nextMonth)
        let nextBc = Self.blockHeights[nextDate]

        if let nextBc = nextBc {
            // We have a range - interpolate the blockheight we are looking for
            let diff = nextBc - height
            let timeDiff = nextMonth.timeIntervalSince(currentMonth)
            let diffDays = Int64(timeDiff / (24 * 60 * 60)) // Convert to days

            let queryTimeDiff = query.timeIntervalSince(currentMonth)
            let days = Int64(queryTimeDiff / (24 * 60 * 60))

            let blocksCount = Double(diff) * (Double(days) / Double(diffDays))
            height = Int64(round(Double(height) + blocksCount))
        } else {
            let queryTimeDiff = query.timeIntervalSince(currentMonth)
            let days = Int64(queryTimeDiff / (24 * 60 * 60))

            // Note: You'll need to define DIFFICULTY_TARGET constant
            let dailyBlocks = Double(24 * 60 * 60) / Double(DIFFICULTY_TARGET)
            height = Int64(round(Double(height) + Double(days) * dailyBlocks))
        }

        return height
    }
}

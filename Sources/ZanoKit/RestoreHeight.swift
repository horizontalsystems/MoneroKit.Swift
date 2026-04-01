import Foundation

public class RestoreHeight {
    // Zano has ~60 second block time (hybrid PoW/PoS)
    private static let DIFFICULTY_TARGET = 60

    // Zano mainnet launched May 9, 2019 (block 1 timestamp: 1557342384)
    // Block heights retrieved from daemon via JSON-RPC on 2026-02-18
    private static let blockHeights: [String: Int64] = [
        // 2019 - Genesis was May 9, 2019
        "2019-05-01": 0, // Before genesis
        "2019-06-01": 33753,
        "2019-07-01": 76449,
        "2019-08-01": 120_919,
        "2019-09-01": 164_985,
        "2019-10-01": 207_604,
        "2019-11-01": 252_030,
        "2019-12-01": 295_035,

        // 2020
        "2020-01-01": 339_494,
        "2020-02-01": 383_940,
        "2020-03-01": 425_579,
        "2020-04-01": 470_098,
        "2020-05-01": 513_253,
        "2020-06-01": 557_689,
        "2020-07-01": 600_704,
        "2020-08-01": 645_191,
        "2020-09-01": 689_563,
        "2020-10-01": 732_593,
        "2020-11-01": 777_139,
        "2020-12-01": 820_149,

        // 2021
        "2021-01-01": 864_507,
        "2021-02-01": 908_839,
        "2021-03-01": 949_403,
        "2021-04-01": 993_618,
        "2021-05-01": 1_036_823,
        "2021-06-01": 1_081_230,
        "2021-07-01": 1_124_184,
        "2021-08-01": 1_168_666,
        "2021-09-01": 1_213_065,
        "2021-10-01": 1_256_083,
        "2021-11-01": 1_300_706,
        "2021-12-01": 1_343_923,

        // 2022
        "2022-01-01": 1_388_500,
        "2022-02-01": 1_432_998,
        "2022-03-01": 1_473_418,
        "2022-04-01": 1_517_892,
        "2022-05-01": 1_561_036,
        "2022-06-01": 1_605_647,
        "2022-07-01": 1_648_647,
        "2022-08-01": 1_693_251,
        "2022-09-01": 1_737_858,
        "2022-10-01": 1_781_224,
        "2022-11-01": 1_825_835,
        "2022-12-01": 1_869_049,

        // 2023
        "2023-01-01": 1_913_644,
        "2023-02-01": 1_958_240,
        "2023-03-01": 1_998_574,
        "2023-04-01": 2_043_191,
        "2023-05-01": 2_086_475,
        "2023-06-01": 2_131_038,
        "2023-07-01": 2_174_187,
        "2023-08-01": 2_218_818,
        "2023-09-01": 2_263_535,
        "2023-10-01": 2_306_751,
        "2023-11-01": 2_351_357,
        "2023-12-01": 2_394_645,

        // 2024
        "2024-01-01": 2_439_151,
        "2024-02-01": 2_483_864,
        "2024-03-01": 2_525_559,
        "2024-04-01": 2_569_856,
        "2024-05-01": 2_613_175,
        "2024-06-01": 2_657_650,
        "2024-07-01": 2_700_899,
        "2024-08-01": 2_745_562,
        "2024-09-01": 2_790_360,
        "2024-10-01": 2_833_504,
        "2024-11-01": 2_878_227,
        "2024-12-01": 2_921_353,

        // 2025
        "2025-01-01": 2_966_161,
        "2025-02-01": 3_010_703,
        "2025-03-01": 3_051_042,
        "2025-04-01": 3_095_283,
        "2025-05-01": 3_138_566,
        "2025-06-01": 3_183_222,
        "2025-07-01": 3_226_424,
        "2025-08-01": 3_270_981,
        "2025-09-01": 3_315_720,
        "2025-10-01": 3_358_971,
        "2025-11-01": 3_403_521,
        "2025-12-01": 3_446_760,

        // 2026
        "2026-01-01": 3_491_296,
        "2026-02-01": 3_536_021,
        "2026-03-01": 3_576_257,
        "2026-04-01": 3_620_877,
    ]

    public static func getHeight(date: Date) -> Int64 {
        (try? getHeightOrEstimate(date: date)) ?? 0
    }

    /// Converts a Unix timestamp to an estimated block height
    public static func getHeight(timestamp: UInt64) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return getHeight(date: date)
    }

    public static func getDate(height: Int64) -> Date {
        let utcTimeZone = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone

        let formatter = DateFormatter()
        formatter.timeZone = utcTimeZone
        formatter.dateFormat = "yyyy-MM-dd"

        // Zano genesis: May 9, 2019
        let genesisDate = formatter.date(from: "2019-05-09")!

        // If height is 0 or negative, return genesis date
        guard height > 0 else {
            return genesisDate
        }

        // Sort entries by height to find the bracketing pair
        let sortedEntries = blockHeights.sorted { $0.value < $1.value }

        // Find the two entries that bracket this height
        var prevEntry: (key: String, value: Int64)?
        var nextEntry: (key: String, value: Int64)?

        for (index, entry) in sortedEntries.enumerated() {
            if entry.value <= height {
                prevEntry = entry
                if index + 1 < sortedEntries.count {
                    nextEntry = sortedEntries[index + 1]
                } else {
                    nextEntry = nil
                }
            } else {
                break
            }
        }

        guard let prev = prevEntry, let prevDate = formatter.date(from: prev.key) else {
            return genesisDate
        }

        let estimatedDate: Date
        if let next = nextEntry, let nextDate = formatter.date(from: next.key) {
            // Interpolate between the two dates
            let heightDiff = next.value - prev.value
            let heightOffset = height - prev.value
            let timeDiff = nextDate.timeIntervalSince(prevDate)
            // Guard against division by zero
            if heightDiff > 0 {
                let timeOffset = timeDiff * Double(heightOffset) / Double(heightDiff)
                estimatedDate = prevDate.addingTimeInterval(timeOffset)
            } else {
                estimatedDate = prevDate
            }
        } else {
            // Height is beyond our last entry, estimate using block time
            let heightOffset = height - prev.value
            let dailyBlocks = Double(24 * 60 * 60) / Double(DIFFICULTY_TARGET)
            let daysOffset = Double(heightOffset) / dailyBlocks
            estimatedDate = prevDate.addingTimeInterval(daysOffset * 24 * 60 * 60)
        }

        // Cap at current date to avoid returning future dates
        return min(estimatedDate, Date())
    }

    public static func maximumEstimatedHeight() -> Int64 {
        // getHeight estimates for now - 2 days, so we assume estimation for now + 2 days is accurate enough
        getHeight(date: Date() + TimeInterval(86400 * 4))
    }

    private static func getHeightOrEstimate(date: Date) throws -> Int64 {
        let utcTimeZone = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone

        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)

        // Check if before May 2019 (Zano genesis)
        if year < 2019 {
            return 0
        }
        if year == 2019, month < 5 {
            return 0
        }

        let query = date

        // Date formatter for UTC
        let formatter = DateFormatter()
        formatter.timeZone = utcTimeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let queryDate = formatter.string(from: date)

        // Get first day of the month
        let firstOfMonth = calendar.dateInterval(of: .month, for: date)!.start
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

                if currentYear < 2019 {
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

        if let nextBc {
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

            // ~1 block per minute = 1440 blocks per day
            let dailyBlocks = Double(24 * 60 * 60) / Double(DIFFICULTY_TARGET)
            height = Int64(round(Double(height) + Double(days) * dailyBlocks))
        }

        return height
    }
}

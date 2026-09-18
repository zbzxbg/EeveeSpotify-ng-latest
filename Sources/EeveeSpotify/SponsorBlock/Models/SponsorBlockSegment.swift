import Foundation

struct SponsorBlockSegment: Equatable {
    let start: Double
    let end: Double
    let category: String
    let actionType: String
    let uuid: String
    let videoDuration: Double

    var duration: Double { end - start }
    var isSkip: Bool { actionType == "skip" }
}

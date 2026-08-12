import Foundation
import Testing
@testable import PhotoAIMac

struct SimilarityCandidatePlannerTests {
    @Test
    func largeTimedLibraryUsesBoundedCandidateBucketsInsteadOfAllPairs() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let candidates = (0..<600).map { index in
            SimilarityCandidate(
                assetID: UUID(),
                captureDate: date,
                visualHash: UInt64(index) << 10
            )
        }

        let plan = SimilarityCandidatePlanner.plan(for: candidates)

        #expect(plan.statistics.allLibraryPairCount == 179_700)
        #expect(plan.statistics.oversizedBucketCount > 0)
        #expect(Int64(plan.candidatePairs.count) < plan.statistics.allLibraryPairCount)
        #expect(plan.statistics.candidatePairCount < 60_000)
    }

    @Test
    func undatedAssetsNeverBecomeAnAllLibraryComparison() {
        let candidates = (0..<600).map { index in
            SimilarityCandidate(
                assetID: UUID(),
                captureDate: nil,
                visualHash: UInt64(index)
            )
        }

        let plan = SimilarityCandidatePlanner.plan(for: candidates)

        #expect(plan.statistics.undatedAssetCount == 600)
        #expect(plan.statistics.allLibraryPairCount == 179_700)
        #expect(plan.candidatePairs.isEmpty)
        #expect(plan.directLinks.isEmpty)
    }

    @Test
    func undatedExactVisualHashesUseLinearLinks() {
        let ids = (0..<4).map { _ in UUID() }
        let plan = SimilarityCandidatePlanner.plan(for: ids.map {
            SimilarityCandidate(assetID: $0, captureDate: nil, visualHash: 0xAABBCCDD)
        })

        #expect(plan.candidatePairs.isEmpty)
        #expect(plan.directLinks.count == 3)
    }
}

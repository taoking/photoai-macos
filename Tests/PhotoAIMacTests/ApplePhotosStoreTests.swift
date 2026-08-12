import Photos
import Testing
@testable import PhotoAIMac

struct ApplePhotosStoreTests {
    @Test
    func authorizationStatesDistinguishReadableAndUnavailableLibraries() {
        #expect(ApplePhotosAuthorization(.authorized).canRead)
        #expect(ApplePhotosAuthorization(.limited).canRead)
        #expect(!ApplePhotosAuthorization(.denied).canRead)
        #expect(!ApplePhotosAuthorization(.restricted).canRead)
        #expect(!ApplePhotosAuthorization(.notDetermined).canRead)
    }

    @Test
    @MainActor
    func storeReadsAuthorizationStatusWithoutRequestingPermissionOrLoadingAssets() {
        let store = ApplePhotosStore()

        #expect(store.state == .idle)
        #expect(store.assets.isEmpty)
        #expect(store.albums.isEmpty)
        #expect(!store.authorization.title.isEmpty)
        #expect(store.authorization.nextStep.contains("Apple Photos") || store.authorization.nextStep.contains("系统设置"))
    }

    @Test
    func applePhotosAssetKeepsIdentifierAndAvailabilitySeparateFromFileCatalog() {
        let cloudAsset = ApplePhotosAsset(
            id: "photos-local-identifier",
            filename: "cloud-only.heic",
            createdAt: nil,
            mediaType: .image,
            isFavorite: true,
            availability: .iCloudOnly
        )

        #expect(cloudAsset.availability.title.contains("iCloud"))
        #expect(cloudAsset.id != UUID().uuidString)
        #expect(cloudAsset.mediaKind == "照片")
    }

    @Test
    func filtersCoverFavoritesVideosRAWAndDates() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let rawFavorite = ApplePhotosAsset(
            id: "raw", filename: "RAW.DNG", createdAt: now, mediaType: .image,
            isFavorite: true, isRAW: true
        )
        let video = ApplePhotosAsset(
            id: "video", filename: "movie.mov", createdAt: now.addingTimeInterval(-60 * 60 * 24 * 5),
            mediaType: .video, duration: 71, isFavorite: false
        )
        let oldPhoto = ApplePhotosAsset(
            id: "old", filename: "old.jpg", createdAt: now.addingTimeInterval(-60 * 60 * 24 * 31),
            mediaType: .image, isFavorite: false
        )
        let calendar = Calendar(identifier: .gregorian)

        #expect(ApplePhotosBrowseFilter.favorites.matches(rawFavorite))
        #expect(!ApplePhotosBrowseFilter.favorites.matches(video))
        #expect(ApplePhotosBrowseFilter.raw.matches(rawFavorite))
        #expect(!ApplePhotosBrowseFilter.raw.matches(video))
        #expect(ApplePhotosBrowseFilter.videos.matches(video))
        #expect(!ApplePhotosBrowseFilter.videos.matches(oldPhoto))
        #expect(ApplePhotosBrowseFilter.recent.matches(video, now: now, calendar: calendar))
        #expect(!ApplePhotosBrowseFilter.recent.matches(oldPhoto, now: now, calendar: calendar))
        #expect(ApplePhotosDateFilter.last30Days.matches(video, now: now, calendar: calendar))
        #expect(!ApplePhotosDateFilter.last30Days.matches(oldPhoto, now: now, calendar: calendar))
        #expect(video.durationText == "1:11")
    }

    @Test
    func selectionSupportsSingleCommandAndShiftRange() {
        var selection = ApplePhotosSelection()
        let identifiers = ["a", "b", "c", "d", "e"]

        selection.select(assetID: "b", in: identifiers, command: false, shift: false)
        #expect(selection.selectedAssetIDs == ["b"])

        selection.select(assetID: "d", in: identifiers, command: true, shift: false)
        #expect(selection.selectedAssetIDs == ["b", "d"])

        selection.select(assetID: "e", in: identifiers, command: false, shift: true)
        #expect(selection.selectedAssetIDs == ["b", "d", "e"])

        selection.select(assetID: "b", in: identifiers, command: true, shift: false)
        #expect(selection.selectedAssetIDs == ["d", "e"])

        selection.retain(["e"])
        #expect(selection.selectedAssetIDs == ["e"])
    }

    @Test
    func filenameResolverNeverOverwritesExistingOrReservedNames() {
        var occupied: Set<String> = ["img_1234.jpg", "IMG_1234-2.JPG".lowercased()]

        let first = ApplePhotosImportPlanner.conflictSafeFilename(preferredFilename: "IMG_1234.JPG", occupiedFilenames: &occupied)
        let second = ApplePhotosImportPlanner.conflictSafeFilename(preferredFilename: "IMG_1234.JPG", occupiedFilenames: &occupied)
        let noExtension = ApplePhotosImportPlanner.conflictSafeFilename(preferredFilename: "original", occupiedFilenames: &occupied)

        #expect(first == "IMG_1234-3.JPG")
        #expect(second == "IMG_1234-4.JPG")
        #expect(noExtension == "original")
        #expect(occupied.contains("img_1234-4.jpg"))
    }

    @Test
    func resourcePlanningRetainsRAWAndJPEGOriginals() {
        let plan = ApplePhotosImportPlanner.plan(
            assetID: "raw-jpeg",
            resources: [
                .init(sourceIndex: 0, filename: "IMG_001.ARW", role: .originalPhoto),
                .init(sourceIndex: 1, filename: "IMG_001.JPG", role: .originalPhoto),
                .init(sourceIndex: 2, filename: "adjustment.plist", role: .unsupported)
            ]
        )

        #expect(plan.map(\.filename) == ["IMG_001.ARW", "IMG_001.JPG"])
        #expect(plan.allSatisfy { $0.role.isOriginal })
    }

    @Test
    func resourcePlanningRetainsLivePhotoStaticAndPairedVideo() {
        let plan = ApplePhotosImportPlanner.plan(
            assetID: "live",
            resources: [
                .init(sourceIndex: 0, filename: "IMG_002.HEIC", role: .originalPhoto),
                .init(sourceIndex: 1, filename: "IMG_002.MOV", role: .livePhotoPairedVideo)
            ]
        )

        #expect(plan.map(\.role) == [.originalPhoto, .livePhotoPairedVideo])
    }

    @Test
    func resourcePlanningPreservesOriginalVideoAndLabelsFallbackWhenNeeded() {
        let video = ApplePhotosImportPlanner.plan(
            assetID: "video",
            resources: [
                .init(sourceIndex: 0, filename: "clip.mov", role: .originalVideo),
                .init(sourceIndex: 1, filename: "clip-rendered.mov", role: .fallbackVideo)
            ]
        )
        let fallback = ApplePhotosImportPlanner.plan(
            assetID: "fallback",
            resources: [
                .init(sourceIndex: 0, filename: "only-rendered.jpg", role: .fallbackPhoto)
            ]
        )

        #expect(video.map(\.filename) == ["clip.mov"])
        #expect(fallback.first?.role == .fallbackPhoto)
        #expect(!fallback.first!.role.isOriginal)
    }

    @Test
    @MainActor
    func importStateMachineMakesCancellationDistinctFromCompletion() {
        #expect(ApplePhotosImportState.importing.isActive)
        #expect(ApplePhotosImportState.cancelling.isActive)
        #expect(!ApplePhotosImportState.cancelled.isActive)
        #expect(ApplePhotosImportState.cancelled.title.contains("取消"))
        #expect(ApplePhotosImportCoordinator.maximumConcurrentResourceImports == 2)
    }

    @Test
    func importResultTracksPartialSuccessAndFailure() {
        let result = ApplePhotosImportResult(
            writtenFileURLs: [URL(fileURLWithPath: "/tmp/one.arw")],
            importedAssetIDs: ["asset-1"],
            failures: [.init(assetID: "asset-2", filename: "two.mov", message: "网络不可用")],
            usedFallbackResources: 0,
            wasCancelled: false
        )

        #expect(result.writtenFileURLs.count == 1)
        #expect(result.importedAssetIDs == ["asset-1"])
        #expect(result.failures.first?.message == "网络不可用")
    }
}

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
    }

    @Test
    func photoSourceValueKeepsICloudAvailabilitySeparateFromFileSystemCatalog() {
        let cloudAsset = ApplePhotosAsset(
            id: "photos-local-identifier",
            filename: "cloud-only.heic",
            createdAt: nil,
            isFavorite: true,
            mediaKind: "照片",
            availability: .iCloudOnly
        )

        #expect(cloudAsset.availability.title.contains("iCloud"))
        #expect(cloudAsset.id != UUID().uuidString)
    }
}

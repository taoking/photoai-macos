import Foundation

/// 将 Scanner 的瞬时结果与本地历史状态合并。该逻辑不访问文件系统，便于在大图库下测试。
enum CatalogMerge {
    static func merging(
        existingAssets: [PhotoAsset],
        scannedAssets: [PhotoAsset],
        sourceID: UUID
    ) -> [PhotoAsset] {
        let existingForSource = existingAssets.filter { $0.sourceID == sourceID }
        let existingByKey = Dictionary(uniqueKeysWithValues: existingForSource.map { ($0.identityKey, $0) })
        // 必须在过滤历史记录前预建集合。对 50k 扫描结果逐项 nested contains 会退化为 O(n²)。
        let scannedIdentityKeys = Set(scannedAssets.map(\.identityKey))

        let mergedScannedAssets = scannedAssets.map { scanned -> PhotoAsset in
            guard let existing = existingByKey[scanned.identityKey] else { return scanned }
            var preserved = scanned
            preserved.id = existing.id
            preserved.rating = existing.rating
            preserved.flag = existing.flag
            preserved.isFavorite = existing.isFavorite
            preserved.editRecipe = existing.editRecipe
            preserved.ocrText = existing.ocrText
            return preserved
        }

        // 缺席本次扫描的文件仍然是历史资产；SQLite 会将其位置标为不可用。
        let historicalAssets = existingForSource.filter { !scannedIdentityKeys.contains($0.identityKey) }
        let assetsFromOtherSources = existingAssets.filter { $0.sourceID != sourceID }
        return (assetsFromOtherSources + historicalAssets + mergedScannedAssets)
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }
}

import AppKit
import SwiftUI

struct PhotoCullingView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var session: PhotoCullingSessionStore
    @EnvironmentObject private var exporter: OriginalPhotoExportStore
    @FocusState private var hasKeyboardFocus: Bool
    @GestureState private var gestureMagnification: CGFloat = 1
    @GestureState private var gestureTranslation: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            cullingToolbar
                .fixedSize(horizontal: false, vertical: true)
            Divider()

            if let compareState = session.compareState {
                compareContent(compareState)
                    .layoutPriority(1)
            } else {
                singlePhotoContent
                    .layoutPriority(1)
            }

            Divider()
            cullingFooter
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focused($hasKeyboardFocus)
        .onAppear { hasKeyboardFocus = true }
        .onKeyPress(.escape) {
            exitCurrentMode()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            navigate(.previous)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigate(.next)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "12345pPxXuU")) { keyPress in
            guard keyPress.modifiers.isEmpty,
                  let shortcut = PhotoCullingShortcut.metadataShortcut(for: keyPress.characters) else {
                return .ignored
            }
            _ = session.perform(shortcut, catalog: catalog)
            return .handled
        }
    }

    private var cullingToolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    session.dismiss()
                    shell.announce("已退出快速筛选并返回图库。")
                } label: {
                    Label("返回图库", systemImage: "chevron.backward")
                }

                Divider().frame(height: 24)

                Button { navigate(.previous) } label: {
                    Label("上一张", systemImage: "chevron.left")
                }
                .disabled(!session.canMove(offset: -1))

                Button { navigate(.next) } label: {
                    Label("下一张", systemImage: "chevron.right")
                }
                .disabled(!session.canMove(offset: 1))

                Text(session.positionDescription)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                if session.compareState == nil {
                    Button {
                        _ = session.beginCompare()
                    } label: {
                        Label("A/B 比较", systemImage: "rectangle.split.2x1")
                    }
                    .disabled(session.contextAssetIDs.count < 2)
                } else {
                    Button {
                        session.finishCompare()
                        synchronizeCurrentSelection()
                    } label: {
                        Label("完成比较", systemImage: "checkmark")
                    }

                    Button { session.setCompareZoom((session.compareState?.zoomScale ?? 1) / 1.25) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("同步缩小 A/B")

                    Button { session.setCompareZoom((session.compareState?.zoomScale ?? 1) * 1.25) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("同步放大 A/B")

                    Button { session.resetCompareTransform() } label: {
                        Label("重置缩放", systemImage: "arrow.counterclockwise")
                    }
                }

                Spacer()

                Button {
                    _ = session.undoLastOperation(catalog: catalog)
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .disabled(!catalog.canUndoMetadataOperation)
                .help("撤销上一次评分或标记 (⌘Z)")

                Menu {
                    exportButton("导出 Pick…", selection: .picks)
                    exportButton("导出五星…", selection: .fiveStars)
                    exportButton("导出当前筛选结果…", selection: .currentResult)
                } label: {
                    Label("导出精选", systemImage: "square.and.arrow.up")
                }
                .disabled(exporter.state.isActive)
            }

            HStack(spacing: 14) {
                statistic("总数", session.statistics.totalCount)
                statistic("Pick", session.statistics.pickCount, color: .green)
                statistic("五星", session.statistics.fiveStarCount, color: .yellow)
                statistic("Reject", session.statistics.rejectCount, color: .red)
                statistic("未处理", session.statistics.unprocessedCount)

                Spacer()

                if session.compareState == nil, let asset = currentAsset {
                    ratingButtons(for: asset)
                    flagButtons(for: asset)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var singlePhotoContent: some View {
        if let asset = currentAsset {
            CullingPreviewPane(asset: asset, zoomScale: 1, offset: .zero)
                .id(asset.id)
        } else {
            missingPhoto
        }
    }

    private func compareContent(_ state: PhotoCompareState) -> some View {
        let displayedScale = CGFloat(state.zoomScale) * gestureMagnification
        let displayedOffset = CGSize(
            width: state.offsetX + gestureTranslation.width,
            height: state.offsetY + gestureTranslation.height
        )

        return HStack(spacing: 1) {
            comparePane(
                side: .a,
                assetID: state.assetAID,
                isPreferred: state.preferredSide == .a,
                zoomScale: displayedScale,
                offset: displayedOffset
            )
            comparePane(
                side: .b,
                assetID: state.assetBID,
                isPreferred: state.preferredSide == .b,
                zoomScale: displayedScale,
                offset: displayedOffset
            )
        }
        .background(.black)
        .contentShape(Rectangle())
        .simultaneousGesture(
            MagnifyGesture()
                .updating($gestureMagnification) { value, state, _ in
                    state = value.magnification
                }
                .onEnded { value in
                    session.setCompareZoom(state.zoomScale * Double(value.magnification))
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .updating($gestureTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    session.setCompareOffset(
                        x: state.offsetX + value.translation.width,
                        y: state.offsetY + value.translation.height
                    )
                }
        )
    }

    @ViewBuilder
    private func comparePane(
        side: PhotoCompareSide,
        assetID: UUID,
        isPreferred: Bool,
        zoomScale: CGFloat,
        offset: CGSize
    ) -> some View {
        if let asset = catalog.asset(withID: assetID) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    CullingPreviewPane(asset: asset, zoomScale: zoomScale, offset: offset)

                    Text(side.rawValue.uppercased())
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(isPreferred ? Color.green : Color.black.opacity(0.65), in: Capsule())
                        .padding(14)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(asset.filename).font(.headline)
                        Spacer()
                        Text(asset.rating == 0 ? "未评分" : String(repeating: "★", count: asset.rating))
                            .foregroundStyle(asset.rating == 0 ? Color.secondary : Color.yellow)
                        Text(asset.flag.title)
                            .foregroundStyle(asset.flag == .pick ? .green : asset.flag == .reject ? .red : .secondary)
                    }
                    Text(compareMetadata(for: asset))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Button {
                        _ = session.chooseCompareSide(side, catalog: catalog)
                    } label: {
                        Label(
                            "选择 \(side.rawValue.uppercased())（Pick；另一张 Reject）",
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            missingPhoto
        }
    }

    private var cullingFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(session.currentGroupDescription, systemImage: "square.stack.3d.up")
                Text("共 \(session.groups.count) 个连续照片组")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Preview Cache · RAW 后台解码 · 原文件不变")
                    .foregroundStyle(.secondary)
            }

            if let asset = currentAsset {
                Text(compareMetadata(for: asset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let progress = exporter.progressDescription {
                HStack {
                    ProgressView(value: Double(exporter.completedCount), total: Double(max(exporter.totalCount, 1)))
                        .frame(maxWidth: 220)
                    Text(progress).font(.caption)
                    if exporter.state == .running {
                        Button("取消") { exporter.cancel() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var currentAsset: PhotoAsset? {
        session.currentAssetID.flatMap(catalog.asset(withID:))
    }

    private var missingPhoto: some View {
        ContentUnavailableView(
            "照片不可用",
            systemImage: "photo.badge.exclamationmark",
            description: Text("项目可能已从当前 Catalog 移除；按 Esc 返回图库。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func navigate(_ shortcut: PhotoCullingShortcut) {
        guard session.compareState == nil else { return }
        _ = session.perform(shortcut, catalog: catalog)
    }

    private func exitCurrentMode() {
        if session.compareState != nil {
            session.finishCompare(focusPreferred: false)
            synchronizeCurrentSelection()
        } else {
            session.dismiss()
            shell.announce("已退出快速筛选并返回图库。")
        }
    }

    private func synchronizeCurrentSelection() {
        if let currentAssetID = session.currentAssetID {
            catalog.selectSingle(assetID: currentAssetID)
        }
    }

    private func statistic(_ label: String, _ value: Int, color: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value.formatted()).fontWeight(.semibold).foregroundStyle(color)
        }
        .monospacedDigit()
    }

    private func ratingButtons(for asset: PhotoAsset) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { rating in
                Button {
                    _ = session.perform(.rating(rating), catalog: catalog)
                } label: {
                    Image(systemName: rating <= asset.rating ? "star.fill" : "star")
                        .foregroundStyle(rating <= asset.rating ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("\(rating) 星（快捷键 \(rating)）")
            }
        }
    }

    private func flagButtons(for asset: PhotoAsset) -> some View {
        HStack(spacing: 6) {
            Button("P") { _ = session.perform(.pick, catalog: catalog) }
                .tint(asset.flag == .pick ? .green : nil)
                .help("Pick (P)")
            Button("X") { _ = session.perform(.reject, catalog: catalog) }
                .tint(asset.flag == .reject ? .red : nil)
                .help("Reject (X)")
            Button("U") { _ = session.perform(.clearFlag, catalog: catalog) }
                .help("清除标记 (U)")
        }
    }

    private func exportButton(
        _ title: String,
        selection: PhotoCullingExportSelection
    ) -> some View {
        Button(title) {
            let assets = PhotoCullingExportSelector.assets(
                from: session.synchronizedAssets(catalog: catalog),
                selection: selection
            )
            exporter.chooseDestinationAndStart(
                assets: assets,
                catalog: catalog,
                preserveDirectoryStructure: true
            )
        }
    }

    private func compareMetadata(for asset: PhotoAsset) -> String {
        let path = catalog.fileURL(for: asset)?.path ?? "路径不可访问"
        let camera = [asset.cameraMake, asset.cameraModel].compactMap { $0 }.joined(separator: " ")
        let date = asset.captureDate?.formatted(date: .abbreviated, time: .standard) ?? "时间未知"
        let size = ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file)
        return [path, camera, asset.lens, date, asset.displayDimensions, size]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }
}

private struct CullingPreviewPane: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var previews: PhotoPreviewStore
    let asset: PhotoAsset
    let zoomScale: CGFloat
    let offset: CGSize
    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        let request = catalog.previewRequest(for: asset)
        ZStack {
            Color.black.opacity(0.94)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoomScale)
                    .offset(offset)
                    .padding(18)
            } else if isLoading {
                ProgressView(asset.isRAW ? "正在后台生成 RAW 预览…" : "正在加载 Preview Cache…")
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(.white)
            } else {
                ContentUnavailableView(
                    "筛选预览不可用",
                    systemImage: asset.systemImage,
                    description: Text("不会在 UI 线程读取 RAW；可继续切换其他照片。")
                )
                .foregroundStyle(.white)
            }
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: request?.cacheKey) {
            image = nil
            guard let request else {
                isLoading = false
                return
            }
            if let cached = previews.cachedImage(for: request) {
                image = cached
                isLoading = false
                return
            }
            isLoading = true
            let loadedImage = await previews.image(for: request)
            guard !Task.isCancelled else { return }
            image = loadedImage
            isLoading = false
        }
    }
}

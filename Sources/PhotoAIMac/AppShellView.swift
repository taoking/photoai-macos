import AppKit
import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var luts: LUTStore
    @EnvironmentObject private var batch: BatchWorkflowStore
    @EnvironmentObject private var cleanup: CleanupWorkflowStore
    @EnvironmentObject private var applePhotos: ApplePhotosStore
    @EnvironmentObject private var thumbnails: ThumbnailStore
    @EnvironmentObject private var originalExporter: OriginalPhotoExportStore
    @EnvironmentObject private var photoCulling: PhotoCullingSessionStore

    var body: some View {
        NavigationSplitView {
            // 侧边栏的 Binding 必须经过 AppShellModel.select(_:)。SidebarView 还会
            // 显式处理已选中行的再次点击，因为 SwiftUI List 此时不会调用 Binding
            // setter；编辑器必须把这次点击理解为明确的“返回该页面”。
            SidebarView(
                selection: Binding(
                    get: { shell.selection },
                    set: {
                        photoCulling.dismiss()
                        shell.select($0)
                    }
                )
            )
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            ZStack {
                HSplitView {
                    LibraryPlaceholderView()

                    if shell.isInspectorVisible {
                        Group {
                            if shell.selection == .applePhotos {
                                ApplePhotosInspectorView()
                            } else {
                                InspectorView()
                            }
                        }
                            .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
                    }
                }
                .allowsHitTesting(!shell.isEditorPresented && !shell.isPhotoViewerPresented && !photoCulling.isPresented)
                .accessibilityHidden(shell.isEditorPresented || shell.isPhotoViewerPresented || photoCulling.isPresented)

                // 让图库在编辑期间留在同一视图树中。此前用条件分支替换整个 detail，
                // 返回时会一次性销毁并重建所有可见 LazyVGrid Cell；在快速切换或调色
                // 后这会让缩略图订阅错过更新，看起来像“所有照片空白”。编辑器覆盖在
                // 保留的图库之上，完成后可立即显示已有缩略图状态与内存缓存。
                if photoCulling.isPresented {
                    PhotoCullingView()
                        .background(.background)
                        .accessibilityAddTraits(.isModal)
                } else if shell.isPhotoViewerPresented {
                    PhotoViewerView()
                        .background(.background)
                        .accessibilityAddTraits(.isModal)
                } else if shell.isEditorPresented {
                    EditorView()
                        .background(.background)
                        .accessibilityAddTraits(.isModal)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: shell.selection) { _, _ in
            // 侧边栏在编辑时仍然可见；把它当成返回图库的明确导航操作，不能留下
            // 一个盖住新目标页的编辑器。工具栏/快捷键通过 AppShellModel.select(_:) 时
            // 也保持相同语义。
            if shell.isEditorPresented {
                shell.dismissEditor()
            }
            photoCulling.dismiss()
            catalog.clearSelection()
            if shell.selection != .applePhotos { applePhotos.clearSelection() }
        }
        .onChange(of: shell.isEditorPresented) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            // 不依赖 onAppear：在 macOS beta 上，覆盖层退出时 LazyVGrid 的既有 Cell
            // 有时不会再收到生命周期事件。一次性唤醒可见订阅方即可从内存缓存或
            // 正在进行的请求恢复缩略图，不会为每张完成的缩略图重算整张网格。
            thumbnails.refreshVisibleSubscribers()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("添加照片文件夹…") {
                        catalog.chooseAndAddFolder()
                    }
                    Button("重新扫描当前来源") {
                        catalog.startRescanAll()
                        shell.announce("正在重新扫描本地来源。")
                    }
                } label: {
                    Label("添加来源", systemImage: "plus")
                }
                .disabled(photoCulling.isPresented)

                Picker("缩略图大小", selection: $shell.gridDensity) {
                    ForEach(GridDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                .pickerStyle(.menu)
                .disabled(photoCulling.isPresented)

                Picker("筛选", selection: $catalog.filter) {
                    ForEach(LibraryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .disabled(photoCulling.isPresented)

                Button {
                    presentSelectedPhotoViewer()
                } label: {
                    Label("大图预览", systemImage: "rectangle.inset.filled.and.person.filled")
                }
                .disabled(photoCulling.isPresented || !canPresentSelectedPhotoViewer)
                .help("大图预览选中照片 (Space)")

                Button {
                    presentPhotoCulling()
                } label: {
                    Label("快速筛选", systemImage: "rectangle.stack.badge.play")
                }
                .disabled(photoCulling.isPresented || shell.selection == .applePhotos || visibleCatalogAssets.isEmpty)
                .help("进入快速筛选模式 (⇧⌘K)")

                Button {
                    shell.toggleInspector()
                } label: {
                    Label("显示检查器", systemImage: "sidebar.right")
                }
                .disabled(photoCulling.isPresented)
                .help("显示或隐藏检查器 (⌥⌘I)")

                Button {
                    shell.presentEditor()
                } label: {
                    Label("编辑", systemImage: "slider.horizontal.3")
                }
                .disabled(photoCulling.isPresented || catalog.selectedAsset?.supportsEditing != true)
                .help("编辑选中的 JPEG、HEIF 或 RAW 照片 (E)")

                Menu {
                    Menu("批量评分") {
                        Button("未评分") { catalog.setRating(0) }
                        ForEach(1...5, id: \.self) { rating in
                            Button("\(rating) 星") { catalog.setRating(rating) }
                        }
                    }
                    .disabled(catalog.selectedAssetIDs.isEmpty)

                    Button("标记为 Pick") { catalog.setFlag(.pick) }
                        .disabled(catalog.selectedAssetIDs.isEmpty)
                    Button("标记为 Reject") { catalog.setFlag(.reject) }
                        .disabled(catalog.selectedAssetIDs.isEmpty)
                    Button("取消标记") { catalog.setFlag(.none) }
                        .disabled(catalog.selectedAssetIDs.isEmpty)

                    Divider()

                    Button("导出所选原文件…") {
                        originalExporter.chooseDestinationAndStart(
                            assets: catalog.selectedAssets(orderedBy: visibleCatalogAssets.map(\.id)),
                            catalog: catalog
                        )
                    }
                    .disabled(originalExporter.state.isActive || catalog.selectedAssetIDs.isEmpty)

                    Button("导出当前筛选结果…") {
                        originalExporter.chooseDestinationAndStart(
                            assets: visibleCatalogAssets,
                            catalog: catalog
                        )
                    }
                    .disabled(originalExporter.state.isActive || visibleCatalogAssets.isEmpty)

                    Button("导出 Pick（保持目录结构）…") {
                        exportOriginals(matching: .picks)
                    }
                    .disabled(
                        originalExporter.state.isActive
                            || catalog.assets(for: shell.selection, filter: .picks).isEmpty
                    )

                    Button("导出五星（保持目录结构）…") {
                        exportOriginals(matching: .fiveStars)
                    }
                    .disabled(
                        originalExporter.state.isActive
                            || catalog.assets(for: shell.selection, filter: .fiveStars).isEmpty
                    )

                    Button("导出当前筛选并保持目录结构…") {
                        originalExporter.chooseDestinationAndStart(
                            assets: visibleCatalogAssets,
                            catalog: catalog,
                            preserveDirectoryStructure: true
                        )
                    }
                    .disabled(originalExporter.state.isActive || visibleCatalogAssets.isEmpty)

                    Divider()

                    Button("复制调整") {
                        if let asset = catalog.selectionAnchorAsset ?? catalog.selectedAsset {
                            batch.copyAdjustments(from: asset, catalog: catalog)
                            shell.announce("已复制调整配方。")
                        }
                    }
                    .disabled(catalog.selectedAssetIDs.isEmpty)

                    Button("粘贴调整") {
                        if batch.pasteAdjustments(to: catalog.selectedAssetIDs, catalog: catalog) {
                            shell.announce("已将调整应用到 \(catalog.selectedAssetIDs.count) 张照片。")
                        }
                    }
                    .disabled(batch.copiedRecipe == nil || catalog.selectedAssetIDs.isEmpty)

                    Button("同步调整") {
                        if let anchor = catalog.selectionAnchorAsset,
                           batch.syncAdjustments(from: anchor, to: catalog.selectedAssetIDs, catalog: catalog) {
                            shell.announce("已从选中主照片同步调整。")
                        }
                    }
                    .disabled(catalog.selectionAnchorAsset == nil || catalog.selectedAssetIDs.count < 2)

                    Divider()

                    Menu("批量导出") {
                        ForEach(batch.presets) { preset in
                            Button(preset.name) {
                                startBatchExport(using: preset)
                            }
                        }
                    }
                    .disabled(catalog.selectedAssetIDs.isEmpty || batch.state == .running || batch.state == .cancelling)

                    if batch.state == .running || batch.state == .cancelling {
                        Button("取消批量导出") {
                            batch.cancel()
                            shell.announce("正在取消批量导出。")
                        }
                    }
                } label: {
                    Label("批处理", systemImage: "square.on.square")
                }
                .disabled(
                    photoCulling.isPresented
                        || shell.selection == .applePhotos
                        || (catalog.selectedAssetIDs.isEmpty && visibleCatalogAssets.isEmpty)
                )
            }
        }
    }

    private func startBatchExport(using preset: ExportPreset) {
        let assets = catalog.selectedAssets.filter(\.supportsEditing)
        batch.chooseDestinationAndStart(assets: assets, preset: preset) { asset in
            catalog.renderRequest(for: asset, lut: luts.renderRecipe(for: catalog.recipe(for: asset)))
        }
    }

    private var visibleCatalogAssets: [PhotoAsset] {
        catalog.assets(for: shell.selection)
    }

    private var canPresentSelectedPhotoViewer: Bool {
        shell.selection == .applePhotos
            ? applePhotos.selectedAsset != nil
            : (catalog.selectionAnchorAsset ?? catalog.selectedAsset) != nil
    }

    private func presentSelectedPhotoViewer() {
        if shell.selection == .applePhotos, let asset = applePhotos.selectedAsset {
            shell.presentPhotoViewer(
                item: .applePhotos(asset.id),
                in: applePhotos.displayedAssets.map { .applePhotos($0.id) }
            )
        } else if let asset = catalog.selectionAnchorAsset ?? catalog.selectedAsset {
            shell.presentPhotoViewer(
                item: .catalog(asset.id),
                in: visibleCatalogAssets.map { .catalog($0.id) }
            )
        }
    }

    private func presentPhotoCulling() {
        guard shell.selection != .applePhotos, !visibleCatalogAssets.isEmpty else { return }
        let focusedID = (catalog.selectionAnchorAsset ?? catalog.selectedAsset)?.id ?? visibleCatalogAssets[0].id
        shell.dismissPhotoViewer(announce: false)
        photoCulling.start(assets: visibleCatalogAssets, focusedAssetID: focusedID)
        catalog.selectSingle(assetID: focusedID)
        shell.announce(KeyboardShortcutReference.cullingAnnouncement)
    }

    private func exportOriginals(matching filter: LibraryFilter) {
        originalExporter.chooseDestinationAndStart(
            assets: catalog.assets(for: shell.selection, filter: filter),
            catalog: catalog,
            preserveDirectoryStructure: true
        )
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarDestination

    var body: some View {
        List(selection: $selection) {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("PhotoAI Mac")
                            .font(.headline)
                        Text("本地照片工作台")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    PhotoAIBrandMark()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("PhotoAI Mac，本地照片工作台")
                .listRowSeparator(.hidden)
                .allowsHitTesting(false)
            }

            ForEach(SidebarGroup.allCases) { group in
                Section(group.title) {
                    ForEach(SidebarDestination.allCases.filter { $0.group == group }) { destination in
                        Button {
                            selection = destination
                        } label: {
                            Label(destination.title, systemImage: destination.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .tag(destination)
                        .accessibilityAddTraits(selection == destination ? .isSelected : [])
                    }
                }
            }
        }
        .navigationTitle("PhotoAI Mac")
        .listStyle(.sidebar)
    }
}

private struct PhotoAIBrandMark: View {
    var body: some View {
        Group {
            if let logoImage = PhotoAIBrandAssets.logoImage {
                Image(nsImage: logoImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "camera.aperture")
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct LibraryPlaceholderView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var batch: BatchWorkflowStore
    @EnvironmentObject private var applePhotos: ApplePhotosStore
    @EnvironmentObject private var originalExporter: OriginalPhotoExportStore

    var body: some View {
        // 保持同一次 render 中的本地 Catalog 结果一致，避免标题、空态判断和网格各自
        // 重新筛选/排序整套资产。
        let catalogAssets = catalog.assets(for: shell.selection)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shell.selection.title)
                        .font(.title2.bold())
                    Text(description)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(countLabel(catalogAssets: catalogAssets))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            if shell.selection == .applePhotos {
                ApplePhotosLibraryView()
            } else if shell.selection == .people {
                PeopleLibraryView()
            } else if shell.selection == .search {
                SearchLibraryView()
            } else if shell.selection == .cleanup {
                CleanupLibraryView()
            } else if shell.selection == .folders {
                FolderSourceList()
            } else if catalogAssets.isEmpty {
                EmptyLibraryView()
            } else {
                CatalogAssetGrid(assets: catalogAssets)
            }

            Divider()

            if let progress = batch.progressDescription {
                HStack(spacing: 8) {
                    if batch.state == .running || batch.state == .cancelling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: batch.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(batch.failures.isEmpty ? .green : .orange)
                    }
                    Text(progress)
                        .font(.footnote)
                    Spacer()
                    if batch.state == .running || batch.state == .cancelling {
                        Button("取消") { batch.cancel() }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                Divider()
            }

            if let progress = originalExporter.progressDescription {
                HStack(spacing: 8) {
                    if originalExporter.state.isActive {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: originalExporter.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(originalExporter.failures.isEmpty ? .green : .orange)
                    }
                    Text(progress)
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                    if originalExporter.state.isActive {
                        Button("取消") { originalExporter.cancel() }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                Divider()
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.secondary)
                Text(shell.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private var description: String {
        if shell.selection == .applePhotos {
            return "独立于文件夹 Catalog；不会自动读取、下载或修改 Apple Photos 内容。"
        }
        return catalog.sources.isEmpty
            ? "添加本地文件夹后，照片会在这里以缩略图网格显示。"
            : "Catalog 已在本机建立索引，原始文件不会被复制或修改。"
    }

    private func countLabel(catalogAssets: [PhotoAsset]) -> String {
        if shell.selection == .applePhotos {
            return "\(applePhotos.visibleAssets.count) 个 Apple Photos 项目"
        }
        return "\(catalogAssets.count) 张已索引"
    }
}

private struct PeopleLibraryView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var people: PeopleStore
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("搜索人物名称", text: $people.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .onChange(of: isSearchFocused) { _, isFocused in
                        shell.setTextInput(AppShellModel.TextInputField.peopleSearch, active: isFocused)
                    }
                    .onDisappear {
                        shell.setTextInput(AppShellModel.TextInputField.peopleSearch, active: false)
                    }

                if isAnalyzing {
                    Button("取消分析") { people.cancelAnalysis() }
                } else {
                    Button(people.status == .unprobed ? "检查人物服务" : "分析本地照片") {
                        if case .unprobed = people.status {
                            people.probeAvailability()
                        } else if canAnalyze {
                            people.startAnalysis(catalog: catalog)
                        }
                    }
                    .disabled(isServiceUnavailable)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            HStack {
                Text(people.status.title)
                    .font(.footnote)
                    .foregroundStyle(statusColor)
                Spacer()
                Text("\(people.visiblePeople.count) 位人物")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if people.visiblePeople.isEmpty {
                ContentUnavailableView(
                    "本地人物分组",
                    systemImage: "person.2",
                    description: Text("先检查 Media Intelligence 服务；分析只在本机运行。人物名称、隐藏与合并均保存为应用自己的记录。")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                        ForEach(people.visiblePeople) { person in
                            PersonCard(person: person)
                        }
                    }
                    .padding(24)
                }
            }

            if let message = people.lastErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }
        }
        .task { people.probeAvailability() }
    }

    private var isServiceUnavailable: Bool {
        if case .unavailable = people.status { return true }
        return false
    }

    private var canAnalyze: Bool {
        switch people.status {
        case .ready, .complete: true
        case .unprobed, .unavailable, .analyzing: false
        }
    }

    private var isAnalyzing: Bool {
        if case .analyzing = people.status { return true }
        return false
    }

    private var statusColor: Color {
        switch people.status {
        case .ready, .complete: .green
        case .unavailable: .orange
        case .analyzing: .accentColor
        case .unprobed: .secondary
        }
    }
}

private struct PersonCard: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var thumbnails: ThumbnailStore
    let person: PersonRecord
    @FocusState private var isNameFieldFocused: Bool

    private var samples: [DetectedFace] { people.representativeFaces(for: person) }
    private var photoCount: Int { people.photoCount(for: person) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PersonFaceHero(faces: samples, remainingPhotoCount: max(0, photoCount - 1))
                .frame(maxWidth: .infinity)
                .frame(height: 156)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(person.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(photoCount) 张关联照片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let face = samples.first, let asset = catalog.assets.first(where: { $0.id == face.assetID }) {
                    Button("查看照片") {
                        shell.select(.allPhotos)
                        // 切换侧边栏时会清空旧选区；下一轮主线程再选中来源照片，确保用户能直接确认人物对应谁。
                        DispatchQueue.main.async {
                            catalog.select(assetID: asset.id, in: catalog.assets.map(\.id), modifiers: [])
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("在所有照片中定位此人物样本")
                }
            }

            TextField("人物名称", text: Binding(
                get: { person.displayName },
                set: { people.rename(personID: person.id, to: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .focused($isNameFieldFocused)
            .onChange(of: isNameFieldFocused) { _, isFocused in
                shell.setTextInput(AppShellModel.TextInputField.personName(person.id), active: isFocused)
            }
            .onDisappear {
                shell.setTextInput(AppShellModel.TextInputField.personName(person.id), active: false)
            }

            if person.displayName.isEmpty {
                Text("输入姓名以便后续搜索与合并。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Menu("合并到") {
                    ForEach(people.visiblePeople.filter { $0.id != person.id }) { destination in
                        Button(destination.title) {
                            people.merge(personID: person.id, into: destination.id)
                        }
                    }
                }
                .disabled(people.visiblePeople.count < 2)

                Spacer()

                Button("隐藏", role: .destructive) {
                    people.hide(personID: person.id)
                }
            }
            .font(.footnote)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 每个人物只显示一个稳定的主预览，其他候选样本以数量提示呈现。
/// 这样既能辨认人物，又不会在自适应网格中让多张图横向挤出卡片。
private struct PersonFaceHero: View {
    let faces: [DetectedFace]
    let remainingPhotoCount: Int

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let face = faces.first {
                PersonFacePreview(face: face)
            } else {
                ContentUnavailableView("暂无可用人脸预览", systemImage: "person.crop.circle.badge.questionmark")
            }

            if remainingPhotoCount > 0 {
                Label("另有 \(remainingPhotoCount) 张关联照片", systemImage: "person.2.fill")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PersonFacePreview: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var thumbnails: ThumbnailStore
    let face: DetectedFace
    @State private var thumbnailState: ThumbnailViewState = .idle
    @State private var thumbnailToken: ThumbnailLoadToken?

    var body: some View {
        let request = catalog.assets.first(where: { $0.id == face.assetID }).flatMap(catalog.thumbnailRequest)

        ZStack {
            if case let .loaded(thumbnail) = thumbnailState,
               let request,
               let preview = FacePreviewRenderer.preview(thumbnail: thumbnail, face: face, thumbnailCacheKey: request.cacheKey) {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFill()
            } else if thumbnailState.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear {
            loadThumbnail(request)
        }
        .onChange(of: request?.cacheKey) { _, _ in
            loadThumbnail(request)
        }
        .onDisappear {
            thumbnails.cancel(thumbnailToken)
            thumbnailToken = nil
        }
        .accessibilityLabel("人物关联照片预览")
    }

    private func loadThumbnail(_ request: ThumbnailRequest?) {
        thumbnails.cancel(thumbnailToken)
        thumbnailToken = nil
        guard let request else {
            thumbnailState = .idle
            return
        }
        if let cachedImage = thumbnails.image(for: request) {
            thumbnailState = .loaded(cachedImage)
            return
        }
        thumbnailState = .loading
        thumbnailToken = thumbnails.load(request) { image in
            thumbnailState = ThumbnailViewState.completed(with: image)
            thumbnailToken = nil
        }
    }
}

private struct SearchLibraryView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var ocr: OCRIndexStore
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let searchAssets = catalog.assets(for: .search)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(
                    "搜索文件名、相机、镜头、OCR 文字或结构化条件",
                    text: Binding(get: { catalog.searchQuery }, set: catalog.setSearchQuery)
                )
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onChange(of: isSearchFocused) { _, isFocused in
                    shell.setTextInput(AppShellModel.TextInputField.globalSearch, active: isFocused)
                }
                .onDisappear {
                    shell.setTextInput(AppShellModel.TextInputField.globalSearch, active: false)
                }

                Button(catalog.isInterpretingSearch ? "正在解释…" : "解释自然语言") {
                    Task { await catalog.interpretSearchWithFoundationModel() }
                }
                .disabled(catalog.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalog.isInterpretingSearch)

                Button(ocr.state == .running ? "暂停 OCR" : "开始 / 继续 OCR") {
                    if ocr.state == .running {
                        ocr.pause()
                    } else {
                        ocr.start(catalog: catalog)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(catalog.searchInterpretation.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(ocr.progressDescription)
                        .font(.footnote)
                        .foregroundStyle(ocr.state == .paused ? Color.orange : Color.secondary)
                }
                Spacer()
                Text("\(searchAssets.count) 个结果")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if catalog.searchInterpretation.query.isEmpty {
                ContentUnavailableView(
                    "搜索本地图库",
                    systemImage: "magnifyingglass",
                    description: Text("例如：rating>=4 format:raw、camera:Sony、text:invoice、after:2026-01-01。")
                )
            } else if searchAssets.isEmpty {
                ContentUnavailableView(
                    "没有匹配结果",
                    systemImage: "magnifyingglass",
                    description: Text("条件按“且”组合；可修改关键词或清空结构化条件。")
                )
            } else {
                CatalogAssetGrid(assets: searchAssets)
            }
        }
    }
}

private struct ApplePhotosLibraryView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var applePhotos: ApplePhotosStore
    @EnvironmentObject private var importer: ApplePhotosImportCoordinator
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            status

            if applePhotos.authorization.canRead, applePhotos.state == .loaded, !applePhotos.visibleAssets.isEmpty {
                ApplePhotosAssetGrid(assets: applePhotos.displayedAssets)
            } else if !applePhotos.authorization.canRead {
                ContentUnavailableView(
                    "Apple Photos 是可选数据源",
                    systemImage: "photo.stack",
                    description: Text("只有点击“授权并读取 Apple Photos”后才会请求权限。未授权、受限或拒绝时，本地 Catalog 不受影响。")
                )
            } else if applePhotos.state == .loading || applePhotos.state == .requestingAuthorization {
                ProgressView("正在读取 Apple Photos 索引…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case let .failed(message) = applePhotos.state {
                ContentUnavailableView(
                    "无法读取 Apple Photos",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            } else if applePhotos.state == .loaded {
                ContentUnavailableView(
                    "没有匹配的 Apple Photos 项目",
                    systemImage: "photo.stack",
                    description: Text("可调整相簿、媒体类型、日期或文件名。浏览不会下载 iCloud 原件。")
                )
            } else {
                ContentUnavailableView(
                    "尚未读取 Apple Photos",
                    systemImage: "photo.stack",
                    description: Text("点击“读取 Apple Photos”后才会枚举你授权范围内的项目；不会下载原件。")
                )
            }

            importStatus
        }
        .task { applePhotos.refreshAuthorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 从系统设置返回时只刷新状态；权限若被关闭会清空 Apple Photos 的内存数据，绝不影响本地 Catalog。
            applePhotos.refreshAuthorizationStatus()
        }
        .onChange(of: applePhotos.selectedAlbumID) { _, _ in reloadForExplicitBrowseChange() }
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Picker("浏览", selection: $applePhotos.browseFilter) {
                    ForEach(ApplePhotosBrowseFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .frame(width: 138)

                Picker("相簿", selection: $applePhotos.selectedAlbumID) {
                    Text("所有相簿").tag(String?.none)
                    ForEach(applePhotos.albums) { album in
                        Text("\(album.title)（\(album.estimatedAssetCount)）").tag(Optional(album.id))
                    }
                }
                .frame(maxWidth: 260)

                Picker("日期", selection: $applePhotos.dateFilter) {
                    ForEach(ApplePhotosDateFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .frame(width: 130)

                TextField("按文件名筛选", text: $applePhotos.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .onChange(of: isSearchFocused) { _, isFocused in
                        shell.setTextInput(AppShellModel.TextInputField.applePhotosFilter, active: isFocused)
                    }
                    .onDisappear {
                        shell.setTextInput(AppShellModel.TextInputField.applePhotosFilter, active: false)
                    }
                    .frame(minWidth: 140, maxWidth: 220)

                Spacer(minLength: 0)

                Button(primaryButtonTitle) { applePhotos.requestAuthorizationAndLoad() }
                    .disabled(!canRequestOrLoad)

                Button("导入到 PhotoAI…") {
                    importer.chooseDestinationAndImport(
                        assetIDs: applePhotos.selectedAssetIDs,
                        store: applePhotos,
                        catalog: catalog
                    )
                }
                .disabled(applePhotos.selectedAssetIDs.isEmpty || importer.state.isActive)
            }

            HStack {
                Text("当前筛选 \(applePhotos.visibleAssets.count) 项，已选择 \(applePhotos.selectedAssetIDs.count) 项")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("导入默认保留原始资源；Live Photo 会同时导入静态照片与配对视频。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    private var status: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(applePhotos.authorization.title)
                    .font(.footnote)
                    .foregroundStyle(authorizationColor)
                Text(applePhotos.authorization.nextStep)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(applePhotos.state.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var importStatus: some View {
        if importer.state != .idle {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if importer.state.isActive { ProgressView().controlSize(.small) }
                    Text(importer.state.title)
                    Spacer()
                    Text("\(importer.progress.completedResources)/\(importer.progress.totalResources) 个资源")
                        .foregroundStyle(.secondary)
                    if importer.state == .importing {
                        Button("取消导入") { importer.cancel() }
                            .controlSize(.small)
                    }
                }
                ProgressView(value: importer.progress.fractionCompleted)
                if let filename = importer.progress.currentFilename {
                    Text("正在处理：\(filename)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if importer.result.usedFallbackResources > 0 {
                    Text("\(importer.result.usedFallbackResources) 个资源没有公开原始版本，已明确作为全尺寸回退资源导入。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !importer.result.failures.isEmpty {
                    Text("\(importer.result.failures.count) 个资源未导入；已成功写入的文件仍会接入本地 Catalog。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .font(.footnote)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.quaternary)
        }
    }

    private var primaryButtonTitle: String {
        applePhotos.authorization.canRead ? "读取 Apple Photos" : "授权并读取 Apple Photos"
    }

    private var canRequestOrLoad: Bool {
        switch applePhotos.authorization {
        case .authorized, .limited, .notDetermined: true
        case .denied, .restricted, .unavailable: false
        }
    }

    private var authorizationColor: Color {
        switch applePhotos.authorization {
        case .authorized: .green
        case .limited: .orange
        case .notDetermined, .unavailable: .secondary
        case .denied, .restricted: .red
        }
    }

    private func reloadForExplicitBrowseChange() {
        guard applePhotos.authorization.canRead else { return }
        applePhotos.loadSelectedSource()
    }
}

private struct ApplePhotosAssetGrid: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var applePhotos: ApplePhotosStore
    let assets: [ApplePhotosAsset]

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: shell.gridDensity.minimumThumbnailWidth), spacing: 14)],
                spacing: 14
            ) {
                ForEach(assets) { asset in
                    ApplePhotosAssetCell(asset: asset)
                }
            }
            .padding(24)

            if applePhotos.hasMoreVisibleAssets {
                VStack(spacing: 8) {
                    Text("已显示 \(assets.count) / \(applePhotos.visibleAssets.count) 项")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("显示更多") { applePhotos.showMoreAssets() }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

private struct ApplePhotosAssetCell: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var applePhotos: ApplePhotosStore
    let asset: ApplePhotosAsset
    @State private var thumbnail: NSImage?
    @State private var availability: ApplePhotosAsset.Availability = .unknown

    private var targetSize: CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let edge = shell.gridDensity.minimumThumbnailWidth * scale
        return CGSize(width: edge, height: edge)
    }

    var body: some View {
        let isSelected = applePhotos.selectedAssetIDs.contains(asset.id)
        Button {
            let modifiers = NSEvent.modifierFlags
            applePhotos.select(assetID: asset.id, modifiers: modifiers)
            if !modifiers.contains(.command), !modifiers.contains(.shift) {
                shell.presentPhotoViewer(
                    item: .applePhotos(asset.id),
                    in: applePhotos.displayedAssets.map { .applePhotos($0.id) }
                )
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: asset.mediaType.systemImage)
                            .font(.title2)
                        Text(availability == .iCloudOnly ? "来自 iCloud" : "缩略图不可用")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) { topLeadingOverlay }
            .overlay(alignment: .topTrailing) { topTrailingOverlay }
            .overlay(alignment: .bottomTrailing) { bottomTrailingOverlay }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
        }
        .buttonStyle(.plain)
        .task(id: "\(asset.id)-\(Int(targetSize.width))") {
            applePhotos.preheatThumbnail(for: asset.id, targetSize: targetSize)
            async let loadedThumbnail = applePhotos.thumbnail(for: asset.id, targetSize: targetSize)
            async let loadedAvailability = applePhotos.resolveAvailability(for: asset.id)
            let resultThumbnail = await loadedThumbnail
            let resultAvailability = await loadedAvailability
            guard !Task.isCancelled else { return }
            thumbnail = resultThumbnail
            availability = resultAvailability
        }
        .accessibilityLabel(accessibilityLabel)
        // 使用等价的可访问性值，保留选中状态的朗读，同时避免在大型网格中
        // 对 Button trait 集合做动态变更。
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    @ViewBuilder
    private var topLeadingOverlay: some View {
        HStack(spacing: 4) {
            if asset.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.red) }
            if asset.isRAW { Text("RAW").fontWeight(.bold) }
            if asset.isLivePhoto { Image(systemName: "livephoto") }
        }
        .font(.caption2)
        .padding(5)
        .foregroundStyle(.white)
        .background(.black.opacity(0.58), in: Capsule())
        .padding(6)
    }

    @ViewBuilder
    private var topTrailingOverlay: some View {
        if availability == .iCloudOnly {
            Image(systemName: "icloud")
                .font(.caption)
                .padding(6)
                .foregroundStyle(.white)
                .background(.black.opacity(0.58), in: Circle())
                .padding(6)
        }
    }

    @ViewBuilder
    private var bottomTrailingOverlay: some View {
        if let duration = asset.durationText {
            Text(duration)
                .font(.caption2.monospacedDigit())
                .padding(5)
                .foregroundStyle(.white)
                .background(.black.opacity(0.58), in: Capsule())
                .padding(6)
        }
    }

    private var accessibilityLabel: String {
        [asset.filename, asset.mediaType.title, availability.title, asset.isRAW ? "RAW" : nil, asset.isLivePhoto ? "Live Photo" : nil]
            .compactMap { $0 }
            .joined(separator: "，")
    }
}

private struct PhotoViewerView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var applePhotos: ApplePhotosStore
    @EnvironmentObject private var originalExporter: OriginalPhotoExportStore
    @EnvironmentObject private var applePhotosImporter: ApplePhotosImportCoordinator
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            viewerToolbar
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            viewerContent
                .layoutPriority(1)
            Divider()
            metadataContent
                .fixedSize(horizontal: false, vertical: true)
        }
        .id(shell.photoViewerItem)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focused($hasKeyboardFocus)
        .onAppear { hasKeyboardFocus = true }
        .onExitCommand {
            shell.dismissPhotoViewer()
        }
        .onKeyPress(.escape) {
            shell.dismissPhotoViewer()
            return .handled
        }
        .onKeyPress(.space) {
            shell.dismissPhotoViewer()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            navigate(offset: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigate(offset: 1)
            return .handled
        }
    }

    private var viewerToolbar: some View {
        HStack(spacing: 10) {
            Button {
                shell.dismissPhotoViewer()
            } label: {
                Label("返回", systemImage: "chevron.backward")
            }

            Divider().frame(height: 24)

            Button { navigate(offset: -1) } label: {
                Label("上一张", systemImage: "chevron.left")
            }
            .disabled(!shell.canMovePhotoViewer(offset: -1))

            Button { navigate(offset: 1) } label: {
                Label("下一张", systemImage: "chevron.right")
            }
            .disabled(!shell.canMovePhotoViewer(offset: 1))

            Spacer()

            switch shell.photoViewerItem {
            case let .catalog(assetID):
                if let asset = catalog.asset(withID: assetID) {
                    PhotoViewerRatingControl(asset: asset)

                    Button {
                        catalog.setFlag(.pick, for: [asset.id])
                    } label: {
                        Label("Pick", systemImage: "flag.fill")
                    }
                    .tint(asset.flag == .pick ? .green : nil)

                    Button {
                        catalog.setFlag(.reject, for: [asset.id])
                    } label: {
                        Label("Reject", systemImage: "xmark.circle.fill")
                    }
                    .tint(asset.flag == .reject ? .red : nil)

                    Button {
                        catalog.setFlag(.none, for: [asset.id])
                    } label: {
                        Label("取消标记", systemImage: "flag.slash")
                    }

                    Divider().frame(height: 24)

                    Button {
                        originalExporter.chooseDestinationAndStart(assets: [asset], catalog: catalog)
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .disabled(originalExporter.state.isActive)
                }
            case let .applePhotos(assetID):
                if applePhotos.assets.contains(where: { $0.id == assetID }) {
                    Text("导入 Catalog 后可评分与标记")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        applePhotosImporter.chooseDestinationAndImport(
                            assetIDs: [assetID],
                            store: applePhotos,
                            catalog: catalog
                        )
                    } label: {
                        Label("导出原始资源…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(applePhotosImporter.state.isActive)
                }
            case nil:
                EmptyView()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(minHeight: 50)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var viewerContent: some View {
        switch shell.photoViewerItem {
        case let .catalog(assetID):
            if let asset = catalog.asset(withID: assetID) {
                LocalPhotoViewerMedia(asset: asset)
            } else {
                missingItem
            }
        case let .applePhotos(assetID):
            if let asset = applePhotos.assets.first(where: { $0.id == assetID }) {
                ApplePhotosViewerMedia(asset: asset)
            } else {
                missingItem
            }
        case nil:
            missingItem
        }
    }

    @ViewBuilder
    private var metadataContent: some View {
        switch shell.photoViewerItem {
        case let .catalog(assetID):
            if let asset = catalog.asset(withID: assetID) {
                PhotoViewerMetadataPanel(
                    filename: asset.filename,
                    path: catalog.fileURL(for: asset)?.path ?? "文件路径当前不可访问",
                    camera: [asset.cameraMake, asset.cameraModel]
                        .compactMap { $0 }
                        .joined(separator: " ")
                        .nilIfEmpty ?? "—",
                    lens: asset.lens ?? "—",
                    date: asset.captureDate?.formatted(date: .abbreviated, time: .standard) ?? "—",
                    dimensions: asset.displayDimensions,
                    fileSize: ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file)
                )
            }
        case let .applePhotos(assetID):
            if let asset = applePhotos.assets.first(where: { $0.id == assetID }) {
                PhotoViewerMetadataPanel(
                    filename: asset.filename,
                    path: "Apple Photos 不提供公开的真实文件路径",
                    camera: "—",
                    lens: "—",
                    date: asset.createdAt?.formatted(date: .abbreviated, time: .standard) ?? "—",
                    dimensions: asset.displayDimensions,
                    fileSize: "系统未公开"
                )
            }
        case nil:
            EmptyView()
        }
    }

    private var missingItem: some View {
        ContentUnavailableView(
            "照片不可用",
            systemImage: "photo.badge.exclamationmark",
            description: Text("项目可能已从当前图库上下文移除。按 Esc 返回图库。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func navigate(offset: Int) {
        guard let item = shell.movePhotoViewer(offset: offset) else { return }
        switch item {
        case let .catalog(assetID):
            catalog.selectSingle(assetID: assetID)
        case let .applePhotos(assetID):
            applePhotos.select(assetID: assetID, modifiers: [])
        }
    }
}

private struct PhotoViewerRatingControl: View {
    @EnvironmentObject private var catalog: CatalogStore
    let asset: PhotoAsset

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { rating in
                Button {
                    catalog.setRating(rating, for: [asset.id])
                } label: {
                    Image(systemName: rating <= asset.rating ? "star.fill" : "star")
                        .foregroundStyle(rating <= asset.rating ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("设为 \(rating) 星")
                .accessibilityLabel("设为 \(rating) 星")
            }
            Button {
                catalog.setRating(0, for: [asset.id])
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("清除评分")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("星级评分")
    }
}

private struct LocalPhotoViewerMedia: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var previews: PhotoPreviewStore
    let asset: PhotoAsset
    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        let request = catalog.previewRequest(for: asset)
        ZStack {
            Color.black.opacity(0.92)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(18)
            } else if isLoading {
                ProgressView(asset.isRAW ? "正在后台生成 RAW 预览…" : "正在加载离线预览…")
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(.white)
            } else {
                ContentUnavailableView(
                    asset.mediaType == .video ? "视频缩略图不可用" : "大图预览不可用",
                    systemImage: asset.systemImage,
                    description: Text("原文件不会在主线程直接读取；可返回图库继续管理。")
                )
                .foregroundStyle(.white)
            }

            if asset.mediaType == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 5)
            }
        }
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

private struct ApplePhotosViewerMedia: View {
    @EnvironmentObject private var applePhotos: ApplePhotosStore
    let asset: ApplePhotosAsset

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            if let image = applePhotos.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(18)
            } else if applePhotos.availability(for: asset) == .iCloudOnly {
                ContentUnavailableView(
                    "预览仅存在于 iCloud",
                    systemImage: "icloud",
                    description: Text("大图浏览不会自动下载 iCloud 原件。")
                )
                .foregroundStyle(.white)
            } else {
                ProgressView("正在请求屏幕预览…")
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.id) {
            await applePhotos.loadPreview(for: asset.id, targetSize: CGSize(width: 2_400, height: 1_800))
        }
    }
}

private struct PhotoViewerMetadataPanel: View {
    let filename: String
    let path: String
    let camera: String
    let lens: String
    let date: String
    let dimensions: String
    let fileSize: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                metadata("文件名", filename)
                metadata("相机", camera)
                metadata("时间", date)
                metadata("文件大小", fileSize)
            }
            GridRow {
                metadata("路径", path)
                    .gridCellColumns(2)
                metadata("镜头", lens)
                metadata("尺寸", dimensions)
            }
        }
        .font(.caption)
        .frame(minHeight: 72)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .textSelection(.enabled)
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum CleanupToolMode: String, CaseIterable, Identifiable {
    case cleanup
    case culling

    var id: String { rawValue }
    var title: String { self == .cleanup ? "清理建议" : "智能选片" }
}

private struct CleanupLibraryView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var cleanup: CleanupWorkflowStore
    @EnvironmentObject private var culling: CullingWorkflowStore
    @State private var isTrashConfirmationPresented = false
    @State private var mode: CleanupToolMode = .cleanup

    var body: some View {
        VStack(spacing: 0) {
            Picker("工具", selection: $mode) {
                ForEach(CleanupToolMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if mode == .cleanup {
                cleanupPane
            } else {
                CullingLibraryPane()
            }
        }
        .confirmationDialog(
            "将 \(cleanup.selectedCandidateAssetIDs.count) 个已选文件移到系统废纸篓？",
            isPresented: $isTrashConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                cleanup.moveSelectedToTrash(catalog: catalog)
            }
        } message: {
            Text("此操作会移动你明确选中的原始文件；建议本身不会删除任何内容。失败项目会保留在图库并显示原因。")
        }
    }

    private var cleanupPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if cleanup.state == .analyzing {
                    Button("取消分析") { cleanup.cancelAnalysis() }
                } else {
                    Button("分析本地图库") { cleanup.startAnalysis(catalog: catalog) }
                        .disabled(catalog.assets.isEmpty)
                }

                Spacer()

                Button(cleanup.isMovingToTrash ? "正在移到废纸篓…" : "移到废纸篓…", role: .destructive) {
                    isTrashConfirmationPresented = true
                }
                .disabled(cleanup.selectedCandidateAssetIDs.isEmpty || cleanup.isMovingToTrash)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            HStack(alignment: .firstTextBaseline) {
                Text(cleanup.state.title)
                    .font(.footnote)
                    .foregroundStyle(stateColor)
                Spacer()
                Text("\(cleanup.recommendations.count) 条建议，已选择 \(cleanup.selectedCandidateAssetIDs.count) 项")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Group {
                if cleanup.state == .idle && cleanup.recommendations.isEmpty {
                    ContentUnavailableView(
                        "清理建议",
                        systemImage: "sparkles",
                        description: Text("分析仅在本机读取缩略版本和文件指纹，生成重复、相似、RAW/JPEG、截图与导出关联建议；不会自动删除文件。")
                    )
                } else if cleanup.state == .analyzing {
                    ProgressView("正在生成本地清理建议…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if cleanup.recommendations.isEmpty {
                    ContentUnavailableView(
                        "没有可显示的建议",
                        systemImage: "checkmark.circle",
                        description: Text("分析完成后没有发现符合当前规则的项目；读取失败的文件会单独列出。")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(cleanup.recommendations) { recommendation in
                                CleanupRecommendationCard(recommendation: recommendation)
                            }
                        }
                        .padding(24)
                    }
                }
            }

            if !cleanup.analysisFailures.isEmpty || !cleanup.trashFailures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cleanup.analysisFailures) { failure in
                        Text("分析未完成：\(failure.message)")
                    }
                    ForEach(cleanup.trashFailures) { failure in
                        Text("未移入废纸篓：\(failure.message)")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
        }
    }

    private var stateColor: Color {
        switch cleanup.state {
        case .complete: .green
        case .failed: .red
        case .analyzing: .accentColor
        case .idle: .secondary
        }
    }
}

private struct CullingLibraryPane: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var culling: CullingWorkflowStore
    @State private var isPickConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if culling.state == .analyzing {
                    Button("取消分析") { culling.cancelAnalysis() }
                } else {
                    Button("开始本地选片") { culling.startAnalysis(catalog: catalog) }
                        .disabled(catalog.assets.isEmpty)
                }
                Spacer()
                Button("确认标记为 Pick…") {
                    isPickConfirmationPresented = true
                }
                .disabled(culling.selectedRecommendationIDs.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            HStack(alignment: .firstTextBaseline) {
                Text(culling.state.title)
                    .font(.footnote)
                    .foregroundStyle(stateColor)
                Spacer()
                Text("\(culling.recommendations.count) 个相似组，已选择 \(culling.selectedRecommendationIDs.count) 组")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Group {
                if culling.state == .idle && culling.recommendations.isEmpty {
                    ContentUnavailableView(
                        "智能选片建议",
                        systemImage: "wand.and.stars",
                        description: Text("仅在本机计算相似分组、缩略图清晰度和 Vision 人脸采集质量。它不会自动修改 Pick、Reject 或星级。")
                    )
                } else if culling.state == .analyzing {
                    ProgressView("正在计算本地视觉信号…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if culling.recommendations.isEmpty {
                    ContentUnavailableView(
                        "没有相似组选片建议",
                        systemImage: "checkmark.circle",
                        description: Text("没有发现符合本地视觉相似阈值的图片；每一项分析失败都会单独提示。")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(culling.recommendations) { recommendation in
                                CullingRecommendationCard(recommendation: recommendation)
                            }
                        }
                        .padding(24)
                    }
                }
            }

            if !culling.failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(culling.failures) { failure in
                        Text("未完成分析：\(failure.message)")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
        }
        .confirmationDialog(
            "将每个所选相似组的推荐照片标记为 Pick？",
            isPresented: $isPickConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("标记为 Pick") { culling.applyApprovedPicks(catalog: catalog) }
        } message: {
            Text("此操作只会把你确认的推荐照片标记为 Pick，不会自动修改星级或 Reject，也不会删除文件。")
        }
    }

    private var stateColor: Color {
        switch culling.state {
        case .complete: .green
        case .failed: .red
        case .analyzing: .accentColor
        case .idle: .secondary
        }
    }
}

private struct CullingRecommendationCard: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var culling: CullingWorkflowStore
    let recommendation: CullingRecommendation

    var body: some View {
        let assetsByID = Dictionary(uniqueKeysWithValues: catalog.assets.map { ($0.id, $0) })
        let recommendedName = assetsByID[recommendation.recommendedAssetID]?.filename ?? "推荐照片"
        let selected = culling.selectedRecommendationIDs.contains(recommendation.id)

        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text("建议 Pick：\(recommendedName)")
                    .font(.headline)
                Text(recommendation.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(recommendation.assetIDs.compactMap { assetsByID[$0]?.filename }.joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button(selected ? "取消选择" : "选择建议") {
                culling.toggleSelection(recommendation.id)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CleanupRecommendationCard: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var cleanup: CleanupWorkflowStore
    let recommendation: CleanupRecommendation

    var body: some View {
        let relatedAssets = catalog.assets.filter { recommendation.assetIDs.contains($0.id) }
        let candidates = Set(recommendation.candidateAssetIDs)
        let allCandidatesSelected = !candidates.isEmpty && candidates.isSubset(of: cleanup.selectedCandidateAssetIDs)

        HStack(alignment: .top, spacing: 14) {
            Image(systemName: recommendation.kind.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                Text(recommendation.kind.title)
                    .font(.headline)
                Text(recommendation.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(relatedAssets.map(\.filename).joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if !candidates.isEmpty {
                Button(allCandidatesSelected ? "取消选择" : "选择建议项") {
                    cleanup.toggleCandidates(for: recommendation)
                }
                .buttonStyle(.bordered)
            } else {
                Text("仅关联")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EmptyLibraryView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore

    var body: some View {
        ContentUnavailableView {
            Label(shell.selection.title, systemImage: shell.selection.systemImage)
        } description: {
            if catalog.sources.isEmpty {
                Text("添加本地文件夹以建立只读索引。")
            } else {
                Text("当前筛选条件下没有匹配的照片。")
            }
        } actions: {
            if catalog.sources.isEmpty {
                Button("添加照片文件夹…") {
                    catalog.chooseAndAddFolder()
                }
            }
        }
    }
}

private struct CatalogAssetGrid: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var thumbnails: ThumbnailStore

    let assets: [PhotoAsset]

    var body: some View {
        // 范围选择只需一份稳定顺序，不能为每个 Cell 重复建立 N 元素数组。
        let orderedAssetIDs = assets.map(\.id)
        // 仅编辑器返回时递增；读取它会把这次受控刷新传给已实例化的 Cell。
        let thumbnailRefreshGeneration = thumbnails.visibleSubscriberGeneration
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: shell.gridDensity.minimumThumbnailWidth), spacing: 14)],
                spacing: 14
            ) {
                ForEach(assets) { asset in
                    CatalogAssetCell(
                        asset: asset,
                        orderedAssetIDs: orderedAssetIDs,
                        thumbnailRefreshGeneration: thumbnailRefreshGeneration
                    )
                }
            }
            .padding(24)
        }
    }
}

private struct CatalogAssetCell: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var thumbnails: ThumbnailStore

    let asset: PhotoAsset
    let orderedAssetIDs: [UUID]
    let thumbnailRefreshGeneration: Int
    @State private var thumbnailState: ThumbnailViewState = .idle
    @State private var thumbnailToken: ThumbnailLoadToken?

    var body: some View {
        let request = catalog.thumbnailRequest(for: asset)
        let isSelected = catalog.selectedAssetIDs.contains(asset.id)
        // 编辑器覆盖层关闭时，macOS 有机会保留 Cell 却丢失它的局部 State。
        // 缓存是缩略图的权威来源；在展示层直接兜底可避免这类 Cell 把已解码的
        // 图像误画成空白占位符。`thumbnailRefreshGeneration` 仍负责为缓存未命中
        // 的可见 Cell 重新接入已有加载任务。
        let displayedThumbnail = thumbnailState.loadedImage ?? request.flatMap(thumbnails.image(for:))

        Button {
            let modifiers = NSEvent.modifierFlags
            catalog.select(assetID: asset.id, in: orderedAssetIDs, modifiers: modifiers)
            if !modifiers.contains(.command), !modifiers.contains(.shift) {
                shell.presentPhotoViewer(
                    item: .catalog(asset.id),
                    in: orderedAssetIDs.map { .catalog($0) }
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)

                    if let displayedThumbnail {
                        Image(nsImage: displayedThumbnail)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                    } else if asset.mediaType == .video {
                        Image(systemName: asset.systemImage)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    } else if thumbnailState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if asset.rating > 0 {
                        Text(String(repeating: "★", count: asset.rating))
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .padding(5)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if asset.flag != .none {
                        Image(systemName: asset.flag == .pick ? "flag.fill" : "xmark.circle.fill")
                            .foregroundStyle(asset.flag == .pick ? .green : .red)
                            .padding(7)
                    }
                }

                Text(asset.filename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(asset.metadataSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(5)
            .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            loadThumbnail(request)
        }
        .onChange(of: request?.cacheKey) { _, _ in
            loadThumbnail(request)
        }
        .onChange(of: thumbnailRefreshGeneration) { _, _ in
            loadThumbnail(request)
        }
        .onDisappear {
            thumbnails.cancel(thumbnailToken)
            thumbnailToken = nil
        }
        .accessibilityLabel("\(asset.filename)，\(asset.metadataSummary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func loadThumbnail(_ request: ThumbnailRequest?) {
        thumbnails.cancel(thumbnailToken)
        thumbnailToken = nil
        guard let request else {
            thumbnailState = .idle
            return
        }
        if let cachedImage = thumbnails.image(for: request) {
            thumbnailState = .loaded(cachedImage)
            return
        }
        thumbnailState = .loading
        thumbnailToken = thumbnails.load(request) { image in
            thumbnailState = ThumbnailViewState.completed(with: image)
            thumbnailToken = nil
        }
    }
}

private struct FolderSourceList: View {
    @EnvironmentObject private var catalog: CatalogStore

    var body: some View {
        Group {
            if catalog.sources.isEmpty {
                ContentUnavailableView {
                    Label("没有文件夹来源", systemImage: "folder.badge.plus")
                } description: {
                    Text("添加本地文件夹后，PhotoAI Mac 会保存安全书签并建立只读索引。")
                } actions: {
                    Button("添加照片文件夹…") {
                        catalog.chooseAndAddFolder()
                    }
                }
            } else {
                List(catalog.sources) { source in
                    HStack(spacing: 12) {
                        Image(systemName: source.status.systemImage)
                            .foregroundStyle(source.status.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.displayName)
                                .fontWeight(.medium)
                            Text(source.lastKnownPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(source.status.title)
                            if source.status == .scanning {
                                Text("正在后台扫描…")
                            } else {
                                Text("\(source.assetCount) 张")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Button("重新扫描") {
                            catalog.startRescan(source.id)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct InspectorView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    private enum Field: Hashable { case colorLabel, comment }
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            Section("检查器") {
                LabeledContent("当前视图", value: shell.selection.title)
                LabeledContent("选中项目", value: selectionSummary)
                LabeledContent("来源", value: "\(catalog.sources.count) 个")
            }

            if let asset = catalog.selectedAsset {
                Section("元数据") {
                    LabeledContent("文件名", value: asset.filename)
                    LabeledContent("尺寸", value: asset.displayDimensions)
                    LabeledContent("格式", value: asset.rawType ?? asset.fileExtension.uppercased())
                    LabeledContent("相机", value: asset.cameraModel ?? "—")
                    LabeledContent("镜头", value: asset.lens ?? "—")
                    LabeledContent("ISO", value: asset.iso.map(String.init) ?? "—")
                    LabeledContent("光圈", value: asset.aperture ?? "—")
                    LabeledContent("焦距", value: asset.focalLength ?? "—")
                }

                Section("筛选") {
                    HStack {
                        Text("评分")
                        Spacer()
                        Text(asset.rating == 0 ? "未评分" : String(repeating: "★", count: asset.rating))
                            .foregroundStyle(asset.rating == 0 ? Color.secondary : Color.yellow)
                    }
                    LabeledContent("标记", value: asset.flag.title)
                    LabeledContent("收藏", value: asset.isFavorite ? "是" : "否")
                    TextField("颜色标签", text: Binding(
                        get: { asset.colorLabel },
                        set: { catalog.setColorLabel($0, for: [asset.id]) }
                    ))
                    .focused($focusedField, equals: .colorLabel)
                    TextField("备注", text: Binding(
                        get: { asset.comment },
                        set: { catalog.setComment($0, for: [asset.id]) }
                    ), axis: .vertical)
                    .lineLimit(2...4)
                    .focused($focusedField, equals: .comment)
                }
            } else if !catalog.selectedAssetIDs.isEmpty {
                Section("筛选") {
                    Text("已选择 \(catalog.selectedAssetIDs.count) 张照片，可使用快捷键批量评分或标记。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("元数据") {
                    Text("选择一张照片以查看 EXIF、评分与筛选状态。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: focusedField) { _, newValue in
            shell.setTextInput(AppShellModel.TextInputField.inspectorMetadata, active: newValue != nil)
        }
        .onDisappear {
            shell.setTextInput(AppShellModel.TextInputField.inspectorMetadata, active: false)
        }
    }

    private var selectionSummary: String {
        switch catalog.selectedAssetIDs.count {
        case 0: "无"
        case 1: "1 张"
        default: "\(catalog.selectedAssetIDs.count) 张"
        }
    }
}

private struct ApplePhotosInspectorView: View {
    @EnvironmentObject private var applePhotos: ApplePhotosStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let asset = applePhotos.selectedAsset {
                    ApplePhotosPreview(asset: asset)
                        .frame(maxWidth: .infinity)
                        .frame(height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    GroupBox("Apple Photos 检查器") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            metadataRow("文件名", asset.filename)
                            metadataRow("创建日期", asset.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                            metadataRow("修改日期", asset.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                            metadataRow("尺寸", asset.displayDimensions)
                            metadataRow("媒体类型", asset.mediaType.title)
                            if let duration = asset.durationText { metadataRow("时长", duration) }
                            metadataRow("收藏", asset.isFavorite ? "是" : "否")
                            metadataRow("RAW", asset.isRAW ? "是" : "否")
                            metadataRow("Live Photo", asset.isLivePhoto ? "是" : "否")
                            metadataRow("资源状态", applePhotos.availability(for: asset).title)
                        }
                        .font(.footnote)
                    }

                    Text("Apple Photos 不提供公开的真实文件路径；需要使用时请“导入到 PhotoAI…”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !applePhotos.selectedAssetIDs.isEmpty {
                    ContentUnavailableView(
                        "已选择 \(applePhotos.selectedAssetIDs.count) 个项目",
                        systemImage: "checkmark.circle",
                        description: Text("可使用“导入到 PhotoAI…”把所选原始资源复制到你选择的本地文件夹。")
                    )
                } else {
                    ContentUnavailableView(
                        "选择一个 Apple Photos 项目",
                        systemImage: "photo",
                        description: Text("预览只请求适合屏幕的无网络图像，不会自动下载 iCloud 原件。")
                    )
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func metadataRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

private struct ApplePhotosPreview: View {
    @EnvironmentObject private var applePhotos: ApplePhotosStore
    let asset: ApplePhotosAsset

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            if let image = applePhotos.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else if applePhotos.availability(for: asset) == .iCloudOnly {
                VStack(spacing: 8) {
                    Image(systemName: "icloud")
                    Text("来自 iCloud")
                    Text("浏览不会自动下载原件。")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView("正在请求屏幕预览…")
                    .controlSize(.small)
            }
        }
        .task(id: asset.id) {
            await applePhotos.loadPreview(for: asset.id, targetSize: CGSize(width: 1_600, height: 1_200))
        }
    }
}

extension PhotoAsset {
    var systemImage: String {
        mediaType == .video ? "video" : (isRAW ? "camera.aperture" : "photo")
    }

    var metadataSummary: String {
        let type = isRAW ? rawType ?? "RAW" : fileExtension.uppercased()
        return [type, displayDimensions].joined(separator: " · ")
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension PhotoSourceStatus {
    var systemImage: String {
        switch self {
        case .ready: "folder.fill"
        case .scanning: "arrow.triangle.2.circlepath"
        case .missing: "folder.badge.questionmark"
        case .inaccessible: "folder.badge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .accentColor
        case .scanning: .orange
        case .missing, .inaccessible: .red
        }
    }
}

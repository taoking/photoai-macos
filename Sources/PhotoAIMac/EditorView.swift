import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var thumbnails: ThumbnailStore
    @EnvironmentObject private var preview: EditorPreviewStore
    @EnvironmentObject private var luts: LUTStore
    @EnvironmentObject private var exporter: ExportCoordinator

    var body: some View {
        Group {
            if let asset = catalog.selectedAsset {
                if asset.supportsEditing {
                    editor(for: asset)
                } else {
                    ContentUnavailableView(
                        "暂不支持编辑此文件",
                        systemImage: asset.isRAW ? "camera.aperture" : "video",
                        description: Text("仅支持 JPEG、HEIF 与已识别的 RAW 照片。")
                    )
                }
            } else {
                ContentUnavailableView(
                    "选择要编辑的照片",
                    systemImage: "slider.horizontal.3",
                    description: Text("返回图库，选择一张照片后按 E。")
                )
            }
        }
    }

    @ViewBuilder
    private func editor(for asset: PhotoAsset) -> some View {
        let request = catalog.renderRequest(for: asset, lut: luts.renderRecipe(for: catalog.recipe(for: asset)))

        VStack(spacing: 0) {
            HSplitView {
                previewPane(for: asset, request: request)
                    .frame(minWidth: 560, idealWidth: 860)

                AdjustmentPanel(asset: asset)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            }

            Divider()
            Filmstrip(asset: asset)
                .frame(height: 124)
        }
        .task(id: request) {
            if let request {
                preview.render(request)
            }
        }
    }

    private func previewPane(for asset: PhotoAsset, request: ImageRenderRequest?) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.filename)
                        .font(.headline)
                    Text("预览使用与导出相同的 EditRecipe 语义")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(exporter.isExporting ? "正在导出…" : "导出 JPEG…") {
                    if let request {
                        exporter.chooseAndExport(request, suggestedFilename: exportedFilename(for: asset))
                    }
                }
                .disabled(request == nil || exporter.isExporting)
                Button("完成") {
                    shell.dismissEditor()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black.opacity(0.88))

                if let image = preview.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                } else if preview.isRendering {
                    ProgressView("正在渲染预览…")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else {
                    ContentUnavailableView(
                        "无法生成预览",
                        systemImage: "exclamationmark.triangle",
                        description: Text("请确认原始文件仍可访问。")
                    )
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            if let statusMessage = exporter.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }

    private func exportedFilename(for asset: PhotoAsset) -> String {
        "\((asset.filename as NSString).deletingPathExtension)-Edited.jpg"
    }
}

private struct AdjustmentPanel: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var luts: LUTStore

    let asset: PhotoAsset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("调整")
                        .font(.title3.bold())
                    Spacer()
                    Button("还原") {
                        catalog.resetRecipe(for: asset.id)
                    }
                    .disabled(catalog.recipe(for: asset).isIdentity)
                }

                AdjustmentSection("光线") {
                    AdjustmentSlider("曝光", value: valueBinding(\.exposure), range: -4...4, format: .number.precision(.fractionLength(2)))
                    AdjustmentSlider("对比度", value: valueBinding(\.contrast), range: -1...1, format: .number.precision(.fractionLength(2)))
                    AdjustmentSlider("高光", value: valueBinding(\.highlights), range: -1...1, format: .number.precision(.fractionLength(2)))
                    AdjustmentSlider("阴影", value: valueBinding(\.shadows), range: -1...1, format: .number.precision(.fractionLength(2)))
                }

                AdjustmentSection("色彩") {
                    AdjustmentSlider("色温", value: valueBinding(\.temperature), range: -100...100, format: .number.precision(.fractionLength(0)))
                    AdjustmentSlider("色调", value: valueBinding(\.tint), range: -100...100, format: .number.precision(.fractionLength(0)))
                    AdjustmentSlider("饱和度", value: valueBinding(\.saturation), range: -1...1, format: .number.precision(.fractionLength(2)))
                }

                AdjustmentSection("构图") {
                    Picker("裁剪", selection: cropBinding) {
                        ForEach(CropPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)

                    AdjustmentSlider("旋转", value: valueBinding(\.rotation), range: -45...45, format: .number.precision(.fractionLength(1)))
                }

                AdjustmentSection("LUT") {
                    if luts.presets.isEmpty {
                        Text("尚未导入 LUT。可在“照片”菜单导入 .cube 文件。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("预设", selection: lutBinding) {
                            Text("无").tag(Optional<UUID>.none)
                            ForEach(luts.presets) { preset in
                                Text(preset.name).tag(Optional(preset.id))
                            }
                        }
                        .pickerStyle(.menu)

                        if catalog.recipe(for: asset).lut != nil {
                            AdjustmentSlider(
                                "强度",
                                value: lutIntensityBinding,
                                range: 0...1,
                                format: .number.precision(.fractionLength(2))
                            )
                        }
                    }
                }

                Text("调整只写入本地 EditRecipe；原文件不会被修改。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    private func valueBinding(_ keyPath: WritableKeyPath<EditRecipe, Double>) -> Binding<Double> {
        Binding(
            get: { catalog.recipe(for: asset)[keyPath: keyPath] },
            set: { value in
                catalog.updateRecipe(for: asset.id) { recipe in
                    recipe[keyPath: keyPath] = value
                }
            }
        )
    }

    private var cropBinding: Binding<CropPreset> {
        Binding(
            get: { CropPreset(recipe: catalog.recipe(for: asset)) },
            set: { preset in
                catalog.updateRecipe(for: asset.id) { recipe in
                    recipe.crop = preset.crop
                }
            }
        )
    }

    private var lutBinding: Binding<UUID?> {
        Binding(
            get: { catalog.recipe(for: asset).lut?.presetID },
            set: { presetID in
                catalog.updateRecipe(for: asset.id) { recipe in
                    recipe.lut = presetID.map { LUTRecipe(presetID: $0) }
                }
            }
        )
    }

    private var lutIntensityBinding: Binding<Double> {
        Binding(
            get: { catalog.recipe(for: asset).lut?.intensity ?? 1 },
            set: { intensity in
                catalog.updateRecipe(for: asset.id) { recipe in
                    guard let presetID = recipe.lut?.presetID else { return }
                    recipe.lut = LUTRecipe(presetID: presetID, intensity: intensity)
                }
            }
        )
    }
}

private struct AdjustmentSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: FloatingPointFormatStyle<Double>

    init(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: FloatingPointFormatStyle<Double>
    ) {
        self.title = title
        _value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: format)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct Filmstrip: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var thumbnails: ThumbnailStore

    let asset: PhotoAsset

    private var assets: [PhotoAsset] {
        Array(catalog.assets(for: .allPhotos).prefix(80))
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(assets) { candidate in
                    FilmstripCell(asset: candidate, isSelected: candidate.id == asset.id)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

private struct FilmstripCell: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var thumbnails: ThumbnailStore

    let asset: PhotoAsset
    let isSelected: Bool
    @State private var thumbnail: NSImage?
    @State private var thumbnailToken: ThumbnailLoadToken?

    var body: some View {
        let request = catalog.derivedImageRequest(for: asset)

        Button {
            catalog.select(assetID: asset.id, in: catalog.assets(for: .allPhotos).map(\.id), modifiers: [])
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: asset.systemImage)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.filename)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .onAppear {
            loadThumbnail(request)
        }
        .onDisappear {
            thumbnails.cancel(thumbnailToken)
            thumbnailToken = nil
        }
    }

    private func loadThumbnail(_ request: DerivedImageRequest?) {
        thumbnails.cancel(thumbnailToken)
        thumbnailToken = nil
        thumbnail = request.flatMap(thumbnails.image(for:))
        guard thumbnail == nil, let request else { return }
        thumbnailToken = thumbnails.load(request) { image in
            thumbnail = image
            thumbnailToken = nil
        }
    }
}

private enum CropPreset: String, CaseIterable, Identifiable {
    case original
    case square
    case fourByThree
    case sixteenByNine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "原始比例"
        case .square: "1 : 1"
        case .fourByThree: "4 : 3"
        case .sixteenByNine: "16 : 9"
        }
    }

    var crop: CropRecipe? {
        switch self {
        case .original: nil
        case .square: CropRecipe(aspectRatio: 1)
        case .fourByThree: CropRecipe(aspectRatio: 4 / 3)
        case .sixteenByNine: CropRecipe(aspectRatio: 16 / 9)
        }
    }

    init(recipe: EditRecipe) {
        guard let aspectRatio = recipe.crop?.aspectRatio else {
            self = .original
            return
        }

        switch aspectRatio {
        case 1: self = .square
        case 4 / 3: self = .fourByThree
        case 16 / 9: self = .sixteenByNine
        default: self = .original
        }
    }
}

extension PhotoAsset {
    var supportsEditing: Bool {
        isRAW || ["heic", "heif", "jpeg", "jpg"].contains(fileExtension.lowercased())
    }
}

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var shell: AppShellModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var luts: LUTStore
    @EnvironmentObject private var batch: BatchWorkflowStore
    @EnvironmentObject private var archive: ArchiveCoordinator

    var body: some View {
        Form {
            Section("界面") {
                Picker("默认缩略图大小", selection: $shell.gridDensity) {
                    ForEach(GridDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }

                Toggle("显示检查器", isOn: $shell.isInspectorVisible)
            }

            Section("隐私") {
                Label("默认本地优先；不会上传或修改原始照片。", systemImage: "lock")
            }

            Section("Catalog") {
                LabeledContent("已添加来源", value: "\(catalog.sources.count) 个")
                LabeledContent("已索引照片", value: "\(catalog.assets.count) 张")
            }

            Section("离线预览归档") {
                let cache = catalog.archivePreviewCacheStatistics()
                LabeledContent("持久预览", value: "\(cache.assetCount) 张")
                LabeledContent("当前占用", value: ByteCountFormatter.string(fromByteCount: cache.byteSize, countStyle: .file))
                Text("离线预览保存在本机 Application Support，用于原始来源离线时识别照片；它不是原图备份。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(archive.progress.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("LUT") {
                HStack {
                    Text("已导入预设")
                    Spacer()
                    Button("导入 .cube…") {
                        luts.chooseAndImport()
                    }
                }

                if luts.presets.isEmpty {
                    Text("尚未导入 LUT。导入的文件不会被复制或修改。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(luts.presets) { preset in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(preset.name)
                                Text("3D \(preset.dimension) × \(preset.dimension) × \(preset.dimension)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("移除", role: .destructive) {
                                luts.remove(preset.id)
                            }
                        }
                    }
                }

                if let message = luts.lastErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("批量导出") {
                Picker("默认导出预设", selection: $batch.selectedPresetID) {
                    ForEach(batch.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                Text("当前预设：JPEG 品质 \(Int(batch.selectedPreset.quality * 100))%，文件名后缀 \(batch.selectedPreset.filenameSuffix)。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let progress = batch.progressDescription {
                    Text(progress)
                        .font(.footnote)
                        .foregroundStyle(batch.failures.isEmpty ? Color.secondary : Color.orange)
                }

                if let message = batch.lastErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("SDK 状态") {
                ForEach(SDKCapabilityProbe.capabilities) { capability in
                    LabeledContent(capability.name) {
                        Image(systemName: capability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(capability.isAvailable ? .green : .orange)
                    }
                    .help(capability.detail)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}

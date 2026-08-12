import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var shell: AppShellModel
    @ObservedObject var catalog: CatalogStore
    @ObservedObject var luts: LUTStore
    @ObservedObject var batch: BatchWorkflowStore

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("添加照片文件夹…") {
                catalog.chooseAndAddFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("重新扫描当前来源") {
                catalog.startRescanAll()
                shell.announce("正在重新扫描本地来源。")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu("图库") {
            Button("所有照片") { shell.select(.allPhotos) }
                .keyboardShortcut("1", modifiers: .command)
            Button("最近导入") { shell.select(.recentImports) }
                .keyboardShortcut("2", modifiers: .command)
            Button("收藏") { shell.select(.favorites) }
                .keyboardShortcut("3", modifiers: .command)
            Button("RAW") { shell.select(.raw) }
                .keyboardShortcut("4", modifiers: .command)
            Button("图库归档") { shell.select(.archive) }
                .keyboardShortcut("5", modifiers: .command)
        }

        CommandMenu("显示") {
            Button(shell.isInspectorVisible ? "隐藏检查器" : "显示检查器") {
                shell.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Menu("缩略图大小") {
                ForEach(GridDensity.allCases) { density in
                    Button(density.title) {
                        shell.gridDensity = density
                        shell.announce("缩略图已切换为\(density.title)密度。")
                    }
                }
            }
        }

        CommandMenu("照片") {
            Button("在编辑器中打开") {
                shell.presentEditor()
            }
            .keyboardShortcut("e", modifiers: [])
            .disabled(catalog.selectedAsset.map(catalog.canEdit) != true)

            Button("导入 .cube LUT…") {
                luts.chooseAndImport()
            }

            Divider()

            Button("复制调整") {
                if let asset = catalog.selectionAnchorAsset ?? catalog.selectedAsset {
                    batch.copyAdjustments(from: asset, catalog: catalog)
                    shell.announce("已复制调整配方。")
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(catalog.selectedAssetIDs.isEmpty)

            Button("粘贴调整") {
                if batch.pasteAdjustments(to: catalog.selectedAssetIDs, catalog: catalog) {
                    shell.announce("已将调整应用到 \(catalog.selectedAssetIDs.count) 张照片。")
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(batch.copiedRecipe == nil || catalog.selectedAssetIDs.isEmpty)

            Button("同步调整") {
                if let anchor = catalog.selectionAnchorAsset,
                   batch.syncAdjustments(from: anchor, to: catalog.selectedAssetIDs, catalog: catalog) {
                    shell.announce("已从选中主照片同步调整。")
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(catalog.selectionAnchorAsset == nil || catalog.selectedAssetIDs.count < 2)

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

            Divider()

            Button("上一张") {
                catalog.selectAdjacent(offset: -1, in: visibleAssetIDs)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("下一张") {
                catalog.selectAdjacent(offset: 1, in: visibleAssetIDs)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Divider()

            ForEach(1...5, id: \.self) { rating in
                Button("评为 \(rating) 星") {
                    catalog.setRating(rating)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(rating)")), modifiers: [])
            }

            Button("清除评分") {
                catalog.setRating(0)
            }
            .keyboardShortcut("0", modifiers: [])

            Divider()

            Button("Pick") {
                catalog.setFlag(.pick)
            }
            .keyboardShortcut("p", modifiers: [])

            Button("Reject") {
                catalog.setFlag(.reject)
            }
            .keyboardShortcut("x", modifiers: [])

            Button("取消标记") {
                catalog.setFlag(.none)
            }
            .keyboardShortcut("u", modifiers: [])

            Button("切换收藏") {
                catalog.toggleFavorite()
            }
            .keyboardShortcut("f", modifiers: [])
        }
    }

    private var visibleAssetIDs: [UUID] {
        catalog.assets(for: shell.selection).map(\.id)
    }

    private func startBatchExport(using preset: ExportPreset) {
        let assets = catalog.selectedAssets.filter(catalog.canEdit)
        batch.chooseDestinationAndStart(assets: assets, preset: preset) { asset in
            catalog.renderRequest(for: asset, lut: luts.renderRecipe(for: catalog.recipe(for: asset)))
        }
    }
}

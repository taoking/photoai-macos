import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var shell: AppShellModel
    @ObservedObject var catalog: CatalogStore
    @ObservedObject var luts: LUTStore
    @ObservedObject var batch: BatchWorkflowStore
    @ObservedObject var originalExporter: OriginalPhotoExportStore
    @ObservedObject var applePhotos: ApplePhotosStore
    @ObservedObject var photoCulling: PhotoCullingSessionStore

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(catalog.metadataUndoActionTitle.map { "撤销\($0)" } ?? "撤销") {
                if photoCulling.isPresented {
                    _ = photoCulling.undoLastOperation(catalog: catalog)
                } else {
                    _ = catalog.undoLastMetadataOperation()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!catalog.canUndoMetadataOperation)
        }

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
        }

        CommandMenu("显示") {
            Button(shell.isPhotoViewerPresented ? "返回图库" : "大图预览") {
                togglePhotoViewer()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(shell.isTextInputActive)

            Button(photoCulling.isPresented ? "退出快速筛选" : "快速筛选模式") {
                toggleCullingMode()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(shell.selection == .applePhotos || (!photoCulling.isPresented && visibleAssetIDs.isEmpty))

            Button("关闭大图预览") {
                shell.dismissPhotoViewer()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!shell.isPhotoViewerPresented)

            Divider()

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
            Button("全选当前结果") {
                catalog.selectAll(in: visibleAssetIDs)
                shell.announce("已选择当前筛选的 \(visibleAssetIDs.count) 个项目。")
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(photoCulling.isPresented || shell.selection == .applePhotos || visibleAssetIDs.isEmpty)

            Menu("导出原始照片") {
                Button("导出所选原文件…") {
                    exportSelectedOriginals()
                }
                .disabled(catalog.selectedAssetIDs.isEmpty)

                Button("导出当前筛选结果…") {
                    originalExporter.chooseDestinationAndStart(
                        assets: catalog.assets(for: shell.selection),
                        catalog: catalog
                    )
                }
                .disabled(visibleAssetIDs.isEmpty)

                Divider()

                Button("导出 Pick（保持目录结构）…") {
                    exportOriginals(matching: .picks)
                }
                .disabled(catalog.assets(for: shell.selection, filter: .picks).isEmpty)

                Button("导出五星（保持目录结构）…") {
                    exportOriginals(matching: .fiveStars)
                }
                .disabled(catalog.assets(for: shell.selection, filter: .fiveStars).isEmpty)

                Button("导出当前筛选并保持目录结构…") {
                    originalExporter.chooseDestinationAndStart(
                        assets: catalog.assets(for: shell.selection),
                        catalog: catalog,
                        preserveDirectoryStructure: true
                    )
                }
                .disabled(visibleAssetIDs.isEmpty)
            }
            .disabled(originalExporter.state.isActive || shell.selection == .applePhotos)

            Divider()

            Button("在编辑器中打开") {
                shell.presentEditor()
            }
            .keyboardShortcut("e", modifiers: [])
            .disabled(shell.isTextInputActive || photoCulling.isPresented || catalog.selectedAsset?.supportsEditing != true)

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
            .disabled(photoCulling.isPresented || catalog.selectedAssetIDs.isEmpty)

            Button("粘贴调整") {
                if batch.pasteAdjustments(to: catalog.selectedAssetIDs, catalog: catalog) {
                    shell.announce("已将调整应用到 \(catalog.selectedAssetIDs.count) 张照片。")
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(photoCulling.isPresented || batch.copiedRecipe == nil || catalog.selectedAssetIDs.isEmpty)

            Button("同步调整") {
                if let anchor = catalog.selectionAnchorAsset,
                   batch.syncAdjustments(from: anchor, to: catalog.selectedAssetIDs, catalog: catalog) {
                    shell.announce("已从选中主照片同步调整。")
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(photoCulling.isPresented || catalog.selectionAnchorAsset == nil || catalog.selectedAssetIDs.count < 2)

            Menu("批量导出") {
                ForEach(batch.presets) { preset in
                    Button(preset.name) {
                        startBatchExport(using: preset)
                    }
                }
            }
            .disabled(
                photoCulling.isPresented
                    || catalog.selectedAssetIDs.isEmpty
                    || batch.state == .running
                    || batch.state == .cancelling
            )

            if batch.state == .running || batch.state == .cancelling {
                Button("取消批量导出") {
                    batch.cancel()
                    shell.announce("正在取消批量导出。")
                }
            }

            Divider()

            Button("上一张") {
                navigate(offset: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(shell.isTextInputActive)

            Button("下一张") {
                navigate(offset: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(shell.isTextInputActive)

            Divider()

            ForEach(1...5, id: \.self) { rating in
                Button("评为 \(rating) 星") {
                    applyCullingShortcut(.rating(rating))
                }
                .keyboardShortcut(KeyEquivalent(Character("\(rating)")), modifiers: [])
                .disabled(shell.isTextInputActive)
            }

            Button("清除评分") {
                applyCullingShortcut(.rating(0))
            }
            .keyboardShortcut("0", modifiers: [])
            .disabled(shell.isTextInputActive)

            Divider()

            Button("Pick") {
                applyCullingShortcut(.pick)
            }
            .keyboardShortcut("p", modifiers: [])
            .disabled(shell.isTextInputActive)

            Button("Reject") {
                applyCullingShortcut(.reject)
            }
            .keyboardShortcut("x", modifiers: [])
            .disabled(shell.isTextInputActive)

            Button("取消标记") {
                applyCullingShortcut(.clearFlag)
            }
            .keyboardShortcut("u", modifiers: [])
            .disabled(shell.isTextInputActive)

            Button("切换收藏") {
                catalog.toggleFavorite()
            }
            .keyboardShortcut("f", modifiers: [])
            .disabled(shell.isTextInputActive)
        }
    }

    private var visibleAssetIDs: [UUID] {
        catalog.assets(for: shell.selection).map(\.id)
    }

    private func startBatchExport(using preset: ExportPreset) {
        let assets = catalog.selectedAssets.filter(\.supportsEditing)
        batch.chooseDestinationAndStart(assets: assets, preset: preset) { asset in
            catalog.renderRequest(for: asset, lut: luts.renderRecipe(for: catalog.recipe(for: asset)))
        }
    }

    private func togglePhotoViewer() {
        if photoCulling.isPresented {
            photoCulling.dismiss()
            shell.announce("已返回图库。")
            return
        }
        if shell.isPhotoViewerPresented {
            shell.dismissPhotoViewer()
            return
        }
        if shell.selection == .applePhotos,
           let asset = applePhotos.selectedAsset {
            shell.presentPhotoViewer(
                item: .applePhotos(asset.id),
                in: applePhotos.displayedAssets.map { .applePhotos($0.id) }
            )
        } else if let asset = catalog.selectionAnchorAsset ?? catalog.selectedAsset {
            shell.presentPhotoViewer(
                item: .catalog(asset.id),
                in: visibleAssetIDs.map { .catalog($0) }
            )
        }
    }

    private func navigate(offset: Int) {
        if photoCulling.isPresented {
            _ = photoCulling.perform(offset < 0 ? .previous : .next, catalog: catalog)
            return
        }
        if shell.isPhotoViewerPresented, let item = shell.movePhotoViewer(offset: offset) {
            synchronizeSelection(with: item)
            return
        }
        catalog.selectAdjacent(offset: offset, in: visibleAssetIDs)
    }

    private func synchronizeSelection(with item: PhotoViewerItem) {
        switch item {
        case let .catalog(assetID):
            catalog.select(assetID: assetID, in: visibleAssetIDs, modifiers: [])
        case let .applePhotos(assetID):
            applePhotos.select(assetID: assetID, modifiers: [])
        }
    }

    private func exportSelectedOriginals() {
        let assets = catalog.selectedAssets(orderedBy: visibleAssetIDs)
        originalExporter.chooseDestinationAndStart(assets: assets, catalog: catalog)
    }

    private func toggleCullingMode() {
        if photoCulling.isPresented {
            photoCulling.dismiss()
            shell.announce("已退出快速筛选并返回图库。")
            return
        }
        let assets = catalog.assets(for: shell.selection)
        guard let focusedID = (catalog.selectionAnchorAsset ?? catalog.selectedAsset)?.id ?? assets.first?.id else {
            return
        }
        shell.dismissPhotoViewer(announce: false)
        photoCulling.start(assets: assets, focusedAssetID: focusedID)
        catalog.selectSingle(assetID: focusedID)
        shell.announce("快速筛选模式：方向键切换，1–5 评分，P/X/U 标记，Esc 退出。")
    }

    private func applyCullingShortcut(_ shortcut: PhotoCullingShortcut) {
        if photoCulling.isPresented {
            _ = photoCulling.perform(shortcut, catalog: catalog)
            return
        }
        switch shortcut {
        case let .rating(rating): catalog.setRating(rating)
        case .pick: catalog.setFlag(.pick)
        case .reject: catalog.setFlag(.reject)
        case .clearFlag: catalog.setFlag(.none)
        default: break
        }
    }

    private func exportOriginals(matching filter: LibraryFilter) {
        originalExporter.chooseDestinationAndStart(
            assets: catalog.assets(for: shell.selection, filter: filter),
            catalog: catalog,
            preserveDirectoryStructure: true
        )
    }
}

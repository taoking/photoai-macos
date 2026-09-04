import Foundation

/// 一个来源的预热进度。
struct PrewarmProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
    let isPaused: Bool

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    var isFinished: Bool { total > 0 && completed >= total }

    var description: String {
        guard total > 0 else { return "准备中…" }
        if isFinished { return "离线预览已就绪" }
        if isPaused { return "已暂停 \(completed) / \(total)" }
        return "正在生成离线预览 \(completed) / \(total)"
    }
}

/// 为整个来源预生成派生图。
///
/// 没有它，"扫描 5 万张后退出卷"实际上什么都看不到——缩略图原本只为滚动到的
/// 可见 Cell 生成。预热把这件事补齐：扫描完成后在后台把整卷过一遍。
///
/// 三条设计约束：
///
/// 1. **一次解码产出两级。** 昂贵的是读文件加解码，不是编码，所以缩略图和离线
///    预览在同一次解码里一起写出，不会为了两级读两遍原文件。
/// 2. **已有缓存直接跳过。** 因此天然可续跑：中断、退出、重启都不丢进度，
///    重扫也不会重做已经有的部分。
/// 3. **让路给交互。** 用户正在看的照片和正在滚动的网格必须抢在预热前面，
///    否则慢速卷上点开一张照片要等整卷预热完。
@MainActor
final class DerivedImagePrewarmStore: ObservableObject {
    @Published private(set) var progressBySourceID: [UUID: PrewarmProgress] = [:]
    @Published private(set) var lastErrorMessage: String?

    private let cache: DerivedImageCache
    /// 要预热哪些级别。默认跟随用户设置；显式注入是为了让测试不必去改
    /// `UserDefaults.standard`——那会污染真实偏好。
    private let tiersProvider: @Sendable () -> Set<DerivedImageTier>
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var pausedSourceIDs: Set<UUID> = []
    /// 正在进行的交互请求数。大于零时预热让路。
    private var interactiveDemand = 0

    init(
        cache: DerivedImageCache = DerivedImageCache(),
        tiers: (@Sendable () -> Set<DerivedImageTier>)? = nil
    ) {
        self.cache = cache
        // 用户关掉离线预览时只预热缩略图：那一级才是网格浏览的最低要求。
        self.tiersProvider = tiers ?? {
            OfflinePreviewSetting.isOfflinePreviewEnabled ? Set(DerivedImageTier.allCases) : [.thumbnail]
        }
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    var isPrewarming: Bool {
        progressBySourceID.contains { !$0.value.isFinished && !$0.value.isPaused }
    }

    func progress(for sourceID: UUID) -> PrewarmProgress? {
        progressBySourceID[sourceID]
    }

    /// 界面在发起交互式解码前后调用，让预热短暂让路。
    func beginInteractiveWork() {
        interactiveDemand += 1
    }

    func endInteractiveWork() {
        interactiveDemand = max(0, interactiveDemand - 1)
    }

    func start(sourceID: UUID, requests: [DerivedImageRequest]) {
        guard !requests.isEmpty else { return }
        tasks[sourceID]?.cancel()
        pausedSourceIDs.remove(sourceID)
        progressBySourceID[sourceID] = PrewarmProgress(completed: 0, total: requests.count, isPaused: false)

        tasks[sourceID] = Task { [weak self] in
            await self?.run(sourceID: sourceID, requests: requests)
        }
    }

    func pause(sourceID: UUID) {
        pausedSourceIDs.insert(sourceID)
        tasks[sourceID]?.cancel()
        tasks[sourceID] = nil
        if let current = progressBySourceID[sourceID] {
            progressBySourceID[sourceID] = PrewarmProgress(
                completed: current.completed,
                total: current.total,
                isPaused: true
            )
        }
    }

    func cancel(sourceID: UUID) {
        tasks[sourceID]?.cancel()
        tasks[sourceID] = nil
        pausedSourceIDs.remove(sourceID)
        progressBySourceID[sourceID] = nil
    }

    private func run(sourceID: UUID, requests: [DerivedImageRequest]) async {
        defer { tasks[sourceID] = nil }

        let cache = self.cache
        let tiers = tiersProvider()
        // 已经齐全的直接算作完成，不必进队列——这就是续跑能力的来源。
        let pending = await Task.detached(priority: .utility) {
            requests.filter { request in
                tiers.contains { !cache.hasFreshEntry(for: request, tier: $0) }
            }
        }.value

        var completed = requests.count - pending.count
        publish(sourceID: sourceID, completed: completed, total: requests.count)

        for request in pending {
            if Task.isCancelled { return }

            // 让路：有交互解码在飞时先退让，避免占住慢速卷的 I/O。
            while interactiveDemand > 0, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
            }
            if Task.isCancelled { return }

            await Task.detached(priority: .background) {
                let missing = tiers.filter { !cache.hasFreshEntry(for: request, tier: $0) }
                guard !missing.isEmpty else { return }
                let rendered = DerivedImageRenderer.render(request, tiers: missing)
                for (tier, image) in rendered {
                    cache.store(image, for: request, tier: tier)
                }
            }.value

            completed += 1
            publish(sourceID: sourceID, completed: completed, total: requests.count)
        }
    }

    private func publish(sourceID: UUID, completed: Int, total: Int) {
        progressBySourceID[sourceID] = PrewarmProgress(
            completed: completed,
            total: total,
            isPaused: pausedSourceIDs.contains(sourceID)
        )
    }
}

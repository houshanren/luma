import SwiftUI
import AppKit

/// 本地图库的端侧人物聚类页面。
struct LocalPeopleView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var renameTarget: LocalPerson?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var pinchBase: Double?
    @State private var pairs: [PeoplePair] = []
    @State private var activePair: PeoplePair?

    /// 只展示还有可见照片的人物：照片全部删除 / 隐藏后人物自动消失，恢复后回来。
    private var people: [LocalPerson] { store.visibleLocalPeople }

    /// 人物集合或照片数变化时重新计算同框关系。
    private var pairSignature: Int {
        var hasher = Hasher()
        for person in people {
            hasher.combine(person.id)
            hasher.combine(person.assetIDs.count)
        }
        return hasher.finalize()
    }

    /// 人物卡片尺寸跟随工具栏缩放（56…360 → 72…300）。
    private var cardSize: CGFloat {
        min(300, max(72, CGFloat(store.thumbSize)))
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchBase == nil { pinchBase = store.thumbSize }
                guard let base = pinchBase else { return }
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                        max(LibraryStore.thumbSizeRange.lowerBound, base * value.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }

    var body: some View {
        Group {
            if let pair = activePair,
               people.contains(where: { $0.id == pair.a }),
               people.contains(where: { $0.id == pair.b }) {
                pairDetail(pair)
            } else if let id = store.selectedLocalPersonID,
               let person = people.first(where: { $0.id == id }) {
                personDetail(person)
            } else {
                overview
            }
        }
        .onAppear {
            store.loadFaceDataIfNeeded()
        }
        .task(id: pairSignature) {
            pairs = store.peoplePairs()
            if let pair = activePair,
               !people.contains(where: { $0.id == pair.a || $0.id == pair.b }) {
                activePair = nil
            }
        }
        .alert("重命名人物", isPresented: $showRename) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let target = renameTarget {
                    store.renameLocalPerson(target.id, to: renameText)
                }
            }
        }
    }

    // MARK: - 总览

    private var overview: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("人物")
                        .font(.system(size: 28, weight: .bold))
                    Text("端侧识别与聚类 · \(people.count) 位 · 所有分析均在本机完成")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if store.isClusteringFaces {
                        store.cancelFaceClustering()
                    } else {
                        store.startFaceClustering()
                    }
                } label: {
                    Label(store.isClusteringFaces ? "停止分析" : (people.isEmpty ? "开始分析" : "继续分析"),
                          systemImage: store.isClusteringFaces ? "stop.circle" : "wand.and.stars")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(store.isClusteringFaces ? "停止人物分析" : "分析尚未处理过的照片")
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if let progress = store.faceClusterProgress, store.isClusteringFaces {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("正在分析 \(progress.processed.formatted()) / \(progress.total.formatted()) 张")
                        Text("· 已识别 \(progress.faces.formatted()) 张脸 · \(progress.people) 位人物")
                        Spacer()
                        Button("停止") { store.cancelFaceClustering() }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 14)
            }

            if people.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !pairs.isEmpty {
                            pairsSection
                                .padding(.horizontal, 26)
                                .padding(.top, 4)
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.35),
                                                     spacing: cardSize * 0.16, alignment: .top)],
                                  alignment: .leading,
                                  spacing: cardSize * 0.2) {
                            ForEach(people) { person in
                                personCard(person)
                            }
                        }
                        .padding(.horizontal, 26)
                        .padding(.top, pairs.isEmpty ? 4 : 0)
                        .padding(.bottom, 56)
                    }
                }
                .simultaneousGesture(pinchGesture)
            }
        }
    }

    // MARK: - 常一起出现

    private var pairsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("常一起出现")
                    .font(.system(size: 15, weight: .semibold))
                Text("按同框次数排序")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(pairs) { pair in
                        if let first = person(pair.a), let second = person(pair.b) {
                            pairCard(first, second, pair: pair)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func pairCard(_ first: LocalPerson, _ second: LocalPerson, pair: PeoplePair) -> some View {
        Button {
            activePair = pair
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    avatar(first, size: 34)
                    avatar(second, size: 34)
                        .offset(x: 22)
                        .overlay {
                            Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                        }
                }
                .frame(width: 58, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(first.name) 与 \(second.name)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("同框 \(pair.count) 次")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("查看两人同框的照片")
    }

    private func pairDetail(_ pair: PeoplePair) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        activePair = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.07), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("返回人物")

                    if let first = person(pair.a), let second = person(pair.b) {
                        ZStack(alignment: .leading) {
                            avatar(first, size: 40)
                            avatar(second, size: 40)
                                .offset(x: 26)
                                .overlay {
                                    Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                                }
                        }
                        .frame(width: 70, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(first.name) 与 \(second.name)")
                                .font(.system(size: 21, weight: .bold))
                            Text("同框 \(pair.count) 次 · \(store.photos(for: pair).count.formatted()) 张照片")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)

                ScrollView {
                    SquarePhotoGrid(photos: store.photos(for: pair),
                                    availableWidth: proxy.size.width)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 50)
                }
            }
        }
    }

    private func person(_ id: UUID) -> LocalPerson? {
        people.first { $0.id == id }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text("端侧人物聚类")
                .font(.system(size: 22, weight: .semibold))
            Text("使用本机 Vision 检测照片中的人脸并聚类为人物。\n分析结果只保存在当前图库，不会上传任何照片。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                store.startFaceClustering()
            } label: {
                Label("开始分析", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            .disabled(store.isClusteringFaces)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private func personCard(_ person: LocalPerson) -> some View {
        Button {
            store.selectedLocalPersonID = person.id
        } label: {
            VStack(spacing: 9) {
                avatar(person, size: cardSize * 0.94)
                Text(person.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text("\(person.assetIDs.count) 张")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("重命名…") {
                renameTarget = person
                renameText = person.name
                showRename = true
            }
            Button("从人物中移除", role: .destructive) {
                store.deleteLocalPerson(person.id)
            }
        }
        .help(person.name)
    }

    private func avatar(_ person: LocalPerson, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.22)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image = avatarImage(person) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
        }
    }

    private func avatarImage(_ person: LocalPerson) -> NSImage? {
        if let data = person.coverImageData, let image = NSImage(data: data) {
            return image
        }
        guard let id = person.assetIDs.first, let photo = store.anyPhoto(id: id) else { return nil }
        return ImageLoader.gridThumbnail(for: photo, maxPixel: 256)
    }

    // MARK: - 人物详情

    private func personDetail(_ person: LocalPerson) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        store.closeLocalPerson()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.07), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("返回人物")

                    avatar(person, size: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name)
                            .font(.system(size: 21, weight: .bold))
                        Text("\(store.photos(for: person).count.formatted()) 张照片")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("重命名…") {
                        renameTarget = person
                        renameText = person.name
                        showRename = true
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)

                ScrollView {
                    SquarePhotoGrid(photos: store.photos(for: person),
                                    availableWidth: proxy.size.width)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 50)
                }
            }
        }
    }
}

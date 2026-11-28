import AppKit
import SceneKit
import SwiftUI
import simd

/// 人物详情里的 3D 身材模型。
///
/// 身体与头发来自随包的 CC0 MakeHuman 基础网格（无衣服、无贴图），
/// 胸部按罩杯塑形；资源缺失时退回程序化身形。
/// 舞台、灯光与数据环随深浅色切换。
struct AtlasBodyViewer: NSViewRepresentable {
    let person: AtlasPerson
    var scheme: ColorScheme

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.scene = AtlasBodyScene.make(person: person,
                                         scheme: scheme,
                                         figure: AtlasHumanModel.shared.resolvedFigure(for: person))
        context.coordinator.personID = person.id
        context.coordinator.scheme = scheme
        context.coordinator.loadFigure(into: view, person: person, scheme: scheme)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.personID != person.id || coordinator.scheme != scheme else { return }
        coordinator.personID = person.id
        coordinator.scheme = scheme
        view.scene = AtlasBodyScene.make(person: person,
                                         scheme: scheme,
                                         figure: AtlasHumanModel.shared.resolvedFigure(for: person))
        coordinator.loadFigure(into: view, person: person, scheme: scheme)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var personID: Int64?
        var scheme: ColorScheme?
        private var token = 0

        /// 人体网格与脸部贴图都在后台准备，回来后换场景。
        func loadFigure(into view: SCNView, person: AtlasPerson, scheme: ColorScheme) {
            token += 1
            let current = token
            AtlasHumanModel.shared.loadFigure(for: person) { [weak view] node in
                guard let view, current == self.token else { return }
                let figure: AtlasBodyFigure = node.map { .human($0) } ?? .procedural
                view.scene = AtlasBodyScene.make(person: person, scheme: scheme, figure: figure)
            }
        }
    }
}

// MARK: - 人体网格

/// 随包的 CC0 人体基础网格（MakeHuman base，无衣服）。
/// 网格只解析一次；每个详情页按人物头像生成脸部贴图后再复制一份。
final class AtlasHumanModel {
    static let shared = AtlasHumanModel()

    private var template: SCNNode?
    private var didAttempt = false
    private var waiters: [(SCNNode?) -> Void] = []

    /// 加载中先别摆程序化替身，避免「灰泥人一闪」；真缺资源才退回身形。
    func resolvedFigure(for person: AtlasPerson) -> AtlasBodyFigure {
        guard didAttempt else { return .pending }
        return template == nil ? .procedural : .pending
    }

    /// 进人物页就先把网格读进来。
    func prefetch() {
        loadTemplate { _ in }
    }

    func loadFigure(for person: AtlasPerson, completion: @escaping (SCNNode?) -> Void) {
        loadTemplate { template in
            guard let template else { completion(nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let node = Self.makeFigure(template: template, person: person)
                DispatchQueue.main.async { completion(node) }
            }
        }
    }

    private func loadTemplate(_ completion: @escaping (SCNNode?) -> Void) {
        if didAttempt {
            completion(template)
            return
        }
        waiters.append(completion)
        guard waiters.count == 1 else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let node = Self.buildTemplate()
            DispatchQueue.main.async {
                self.template = node
                self.didAttempt = true
                let pending = self.waiters
                self.waiters.removeAll()
                for handler in pending { handler(node) }
            }
        }
    }

    private static func assetURL(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("Atlas/\(name)"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Atlas/\(name)"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func buildTemplate() -> SCNNode? {
        guard let bodyURL = assetURL("female-base.obj"),
              let bodyScene = try? SCNScene(url: bodyURL, options: [.checkConsistency: false]) else {
            return nil
        }

        let figure = SCNNode()
        let body = SCNNode()
        body.name = "body"
        body.addChildNode(bodyScene.rootNode.clone())
        figure.addChildNode(body)
        body.enumerateChildNodes { node, _ in
            if node.geometry != nil { node.name = "body" }
        }

        if let hairURL = assetURL("female-hair.obj"),
           let hairScene = try? SCNScene(url: hairURL, options: [.checkConsistency: false]) {
            let hair = SCNNode()
            hair.name = "hair"
            hair.addChildNode(hairScene.rootNode.clone())
            figure.addChildNode(hair)
            hair.enumerateChildNodes { node, _ in
                if node.geometry != nil { node.name = "hair" }
            }
        }

        // 去掉文件自带的相机与灯，统一用我们自己的舞台。
        var removals: [SCNNode] = []
        figure.enumerateChildNodes { node, _ in
            if node.camera != nil || node.light != nil { removals.append(node) }
        }
        removals.forEach { $0.removeFromParentNode() }

        // 归一到「脚在 y = 0、身高 1.0、左右居中」。
        // 用一层 pivot 承担居中偏移，容器只负责缩放，旋转才会绕身体中轴而不是脚角。
        let container = SCNNode()
        container.addChildNode(figure)
        let (low, high) = bounds(of: container)
        let height = max(high.y - low.y, 0.0001)
        let scale = 0.98 / height
        let centerX = (low.x + high.x) / 2
        let centerZ = (low.z + high.z) / 2

        figure.removeFromParentNode()
        let pivot = SCNNode()
        pivot.position = SCNVector3(-centerX, -low.y, -centerZ)
        pivot.addChildNode(figure)
        container.addChildNode(pivot)
        container.scale = SCNVector3(scale, scale, scale)
        return container
    }

    /// 按人物复制一份：每个人一份几何与材质，胸部按罩杯塑形，缩放/旋转互不影响。
    private static func makeFigure(template: SCNNode, person: AtlasPerson) -> SCNNode {
        let clone = template.clone()
        clone.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            if node.name == "hair" {
                let copy = geometry.copy() as! SCNGeometry
                copy.materials = [hairMaterial()]
                node.geometry = copy
            } else {
                let sculpted = AtlasBodySculpt.apply(to: geometry, person: person)
                sculpted.materials = [bodyMaterial()]
                node.geometry = sculpted
            }
        }
        return clone
    }

    private static func bodyMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = AtlasPalette.skin
        material.specular.contents = NSColor(calibratedWhite: 0.30, alpha: 1)
        material.shininess = 0.16
        return material
    }

    private static func hairMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor(calibratedRed: 0.17, green: 0.12, blue: 0.11, alpha: 1)
        material.specular.contents = NSColor(calibratedWhite: 0.55, alpha: 1)
        material.shininess = 0.42
        material.isDoubleSided = true
        return material
    }

    private static func bounds(of root: SCNNode) -> (SCNVector3, SCNVector3) {
        var low = SCNVector3(Float.greatestFiniteMagnitude,
                             Float.greatestFiniteMagnitude,
                             Float.greatestFiniteMagnitude)
        var high = SCNVector3(-Float.greatestFiniteMagnitude,
                              -Float.greatestFiniteMagnitude,
                              -Float.greatestFiniteMagnitude)
        var found = false
        root.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let (boxLow, boxHigh) = geometry.boundingBox
            let corners = [
                SCNVector3(boxLow.x, boxLow.y, boxLow.z),
                SCNVector3(boxLow.x, boxLow.y, boxHigh.z),
                SCNVector3(boxLow.x, boxHigh.y, boxLow.z),
                SCNVector3(boxLow.x, boxHigh.y, boxHigh.z),
                SCNVector3(boxHigh.x, boxLow.y, boxLow.z),
                SCNVector3(boxHigh.x, boxLow.y, boxHigh.z),
                SCNVector3(boxHigh.x, boxHigh.y, boxLow.z),
                SCNVector3(boxHigh.x, boxHigh.y, boxHigh.z)
            ]
            for corner in corners {
                let point = node.convertPosition(corner, to: root)
                low.x = min(low.x, point.x); low.y = min(low.y, point.y); low.z = min(low.z, point.z)
                high.x = max(high.x, point.x); high.y = max(high.y, point.y); high.z = max(high.z, point.z)
                found = true
            }
        }
        return found ? (low, high) : (SCNVector3(0, 0, 0), SCNVector3(1, 1, 1))
    }
}

// MARK: - 身材塑形

/// 偏白的黄皮肤（亚洲人），比 MakeHuman 自带的粉白更接近资料里的真人。
enum AtlasPalette {
    static let skin = NSColor(calibratedRed: 0.95, green: 0.84, blue: 0.74, alpha: 1)
}

/// 随包的网格是标准身材（B 罩杯）；这里按人物资料做顶点级塑形：
/// 罩杯决定胸部凸起，腰围/臀围决定对应一段的粗细，身高由整体缩放负责。
/// 网格局部坐标里脚在 y≈-8.17、头在 y≈8.49，腰在 2.5、臀在 0.9 附近。
enum AtlasBodySculpt {
    private static let bustY: Float = 3.85

    /// 每档罩杯相对网格基础胸型（B）的额外凸出量（网格单位，头顶到脚共 16.66）：
    /// A/B 是常见的小胸，C 已经明显丰满，D 起进入巨乳，F 往上到「超大」。
    private static let cupProtrusion: [Float] = [-0.05, 0.10, 0.45, 0.75, 0.95, 1.08, 1.17, 1.24, 1.30, 1.35]

    /// 相对 B 罩杯的额外凸出量（网格单位）。
    static func protrusion(cup: String?, bust: Int?) -> Float {
        // A=0、B=1…，缺数据按 B 处理。
        let letter = cup?.uppercased().first
        let index = letter.flatMap { $0.asciiValue.map { Int($0) - 65 } } ?? 1
        var amount = cupProtrusion[min(max(index, 0), cupProtrusion.count - 1)]
        if let bust {
            amount += Float(bust - 87) * 0.012
        }
        return min(max(amount, -0.12), 2.20)
    }

    /// 腰、臀相对基准的横向缩放。范围放得比较宽，数据一变就能看出来。
    static func waistScale(_ waist: Int?) -> Float {
        min(max(Float(waist ?? 64) / 64, 0.82), 1.22)
    }

    static func hipScale(_ hips: Int?) -> Float {
        min(max(Float(hips ?? 90) / 90, 0.84), 1.20)
    }

    static func apply(to geometry: SCNGeometry, person: AtlasPerson) -> SCNGeometry {
        let bust = protrusion(cup: person.cup, bust: person.bust)
        let waist = waistScale(person.waist)
        let hips = hipScale(person.hips)
        guard abs(bust) > 0.02 || abs(waist - 1) > 0.02 || abs(hips - 1) > 0.02,
              let vertexSource = geometry.sources(for: .vertex).first,
              let normalSource = geometry.sources(for: .normal).first,
              let element = geometry.elements.first,
              element.primitiveType == .triangles,
              var points = vectors(from: vertexSource),
              var normals = vectors(from: normalSource),
              points.count == normals.count else { return geometry }

        for index in points.indices {
            var point = points[index]

            // 腰、臀：只缩横向，且不碰手臂（|x| 超过 1.1 就是手臂/手）。
            if abs(point.x) < 1.1 {
                let waistWeight = band(point.y, 2.20...2.90, feather: 0.45)
                if waistWeight > 0 {
                    let k = 1 + (waist - 1) * waistWeight
                    point.x *= k
                    point.z *= k
                }
                let hipWeight = band(point.y, 0.45...1.45, feather: 0.50)
                if hipWeight > 0 {
                    let k = 1 + (hips - 1) * hipWeight
                    point.x *= k
                    point.z *= k
                }
            }

            // 胸：以两侧乳心为球心把前胸往外鼓，罩杯越大鼓得越远。
            // A/B 收敛，C 起明显丰满，D 往上巨乳，F 往上超大。
            if point.y > 2.5, point.y < 5.3, abs(point.x) < 1.2, point.z > 0.2 {
                let lobeX: Float = point.x < 0 ? -0.48 : 0.48
                let center = bustY - min(max(bust, 0) * 0.10, 0.22)   // 越大越往下坠
                let dx = abs(point.x) - abs(lobeX)
                let radius = 0.42 + max(bust, 0) * 0.30   // 越大底盘越宽，不只往前顶
                // 往下多带一点（乳体连着上腹），往上收得快些，免得锁骨处出现横向台阶。
                let dy = (point.y - center) * (point.y < center ? 0.80 : 1.30)
                let distance = sqrt(dx * dx + dy * dy)
                var weight = Float(exp(-Double((distance / radius) * (distance / radius))))
                weight *= smoothstep(0.04, 0.24, abs(point.x))   // 中间留乳沟
                weight *= smoothstep(0.10, 0.75, point.z)       // 只鼓前胸
                if weight > 0.01 {
                    let push = bust * weight
                    // 顺着法线像充气一样往外顶，胸型才会圆；带一点向前的偏置。
                    var direction = normals[index]
                    direction.y = max(direction.y, -0.35)
                    direction = simd_normalize(direction + SIMD3<Float>(0, 0, 0.15))
                    point += direction * push
                    point.y -= abs(push) * 0.04   // 大胸略下垂
                }
            }

            points[index] = point
        }

        // 顶点变了，法线整体重算：只补改动过的点会在过渡处留下折痕。
        // 网格有些面的绕向是反的，用原法线做参考把面法线翻正，免得相互抵消出暗斑。
        let reference = normals
        if let indices = indices(of: element) {
            var accumulated = [SIMD3<Float>](repeating: .zero, count: points.count)
            var cursor = 0
            while cursor + 2 < indices.count {
                let a = indices[cursor], b = indices[cursor + 1], c = indices[cursor + 2]
                cursor += 3
                guard a < points.count, b < points.count, c < points.count else { continue }
                var normal = simd_cross(points[b] - points[a], points[c] - points[a])
                let hint = reference[a] + reference[b] + reference[c]
                if simd_dot(normal, hint) < 0 { normal = -normal }
                accumulated[a] += normal
                accumulated[b] += normal
                accumulated[c] += normal
            }
            for index in points.indices {
                let length = simd_length(accumulated[index])
                if length > 1e-5 { normals[index] = accumulated[index] / length }
            }
        }

        var sources = geometry.sources.filter { $0.semantic != .vertex && $0.semantic != .normal }
        sources.append(SCNGeometrySource(vertices: points.map { SCNVector3($0.x, $0.y, $0.z) }))
        sources.append(SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }))
        let sculpted = SCNGeometry(sources: sources, elements: geometry.elements)
        sculpted.materials = geometry.materials
        return sculpted
    }

    /// 平滑的「带状」权重：区间内为 1，向两侧 feather 内降到 0。
    private static func band(_ value: Float, _ range: ClosedRange<Float>, feather: Float) -> Float {
        if value < range.lowerBound - feather || value > range.upperBound + feather { return 0 }
        if range.contains(value) { return 1 }
        if value < range.lowerBound {
            return smoothstep(range.lowerBound - feather, range.lowerBound, value)
        }
        return 1 - smoothstep(range.upperBound, range.upperBound + feather, value)
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 读 SCNGeometrySource 里的 float3（可能与其他属性交错存放）。
    private static func vectors(from source: SCNGeometrySource) -> [SIMD3<Float>]? {
        guard source.componentsPerVector >= 3, source.vectorCount > 0 else { return nil }
        let step = max(source.dataStride / MemoryLayout<Float>.size, 3)
        let offset = source.dataOffset / MemoryLayout<Float>.size
        let raw = source.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var result = [SIMD3<Float>](repeating: .zero, count: source.vectorCount)
        for index in 0..<source.vectorCount {
            let base = offset + index * step
            guard base + 2 < raw.count else { break }
            result[index] = SIMD3<Float>(raw[base], raw[base + 1], raw[base + 2])
        }
        return result
    }

    private static func indices(of element: SCNGeometryElement) -> [Int]? {
        guard !element.data.isEmpty else { return nil }
        return element.data.withUnsafeBytes { raw in
            if element.bytesPerIndex == 2 {
                return raw.bindMemory(to: UInt16.self).map(Int.init)
            }
            return raw.bindMemory(to: UInt32.self).map(Int.init)
        }
    }
}

// MARK: - 场景

enum AtlasBodyFigure {
    case human(SCNNode)
    case procedural
    case pending
}

enum AtlasBodyScene {
    static func make(person: AtlasPerson, scheme: ColorScheme, figure: AtlasBodyFigure) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        scene.rootNode.addChildNode(stage(scheme: scheme))

        // 身高按整体缩放；腰、臀、胸的差异在 AtlasBodySculpt 里改顶点。
        let heightScale = CGFloat(min(max(Double(person.heightCM ?? 163) / 163.0, 0.93), 1.07))

        let node: SCNNode
        switch figure {
        case .human(let human):
            node = human
            let base = human.scale
            node.scale = SCNVector3(base.x * heightScale,
                                    base.y * heightScale,
                                    base.z * heightScale)

            // 数据环用分米做坐标（MakeHuman 网格的局部单位），再套用同一份缩放。
            // 胸围环前后拉成椭圆，跟着罩杯长大，不然巨乳会把它顶进身体里。
            let cupAmount = CGFloat(max(AtlasBodySculpt.protrusion(cup: person.cup,
                                                                  bust: person.bust), 0))
            let rings = SCNNode()
            rings.scale = node.scale
            let bustRing = measureRing(y: 12.15, radius: 1.42,
                                       color: ringColor(0, scheme: scheme), pipe: 0.030)
            bustRing.scale = SCNVector3(1, 1, Float(1 + cupAmount * 1.25))
            rings.addChildNode(bustRing)
            rings.addChildNode(measureRing(y: 10.72, radius: 1.16 * CGFloat(AtlasBodySculpt.waistScale(person.waist)),
                                           color: ringColor(1, scheme: scheme), pipe: 0.030))
            rings.addChildNode(measureRing(y: 9.10, radius: 1.52 * CGFloat(AtlasBodySculpt.hipScale(person.hips)),
                                           color: ringColor(2, scheme: scheme), pipe: 0.030))
            scene.rootNode.addChildNode(rings)
        case .procedural:
            node = proceduralFigure(person: person, scheme: scheme)
        case .pending:
            node = SCNNode()
        }

        node.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 48)))
        scene.rootNode.addChildNode(node)

        let focus = SCNNode()
        focus.position = SCNVector3(0, 0.52, 0)
        scene.rootNode.addChildNode(focus)

        let camera = SCNCamera()
        camera.fieldOfView = 30
        camera.wantsHDR = false
        camera.wantsExposureAdaptation = false
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0.24, 0.60, 2.02)
        let lookAt = SCNLookAtConstraint(target: focus)
        lookAt.isGimbalLockEnabled = true
        cameraNode.constraints = [lookAt]
        scene.rootNode.addChildNode(cameraNode)

        let lights = lightRig(scheme: scheme)
        lights.forEach { scene.rootNode.addChildNode($0) }

        return scene
    }

    // MARK: 舞台

    private static func stage(scheme: ColorScheme) -> SCNNode {
        let root = SCNNode()
        let floor = SCNCylinder(radius: 0.46, height: 0.004)
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = scheme == .dark
            ? NSColor(calibratedWhite: 0.10, alpha: 1)
            : NSColor(calibratedRed: 0.93, green: 0.91, blue: 0.89, alpha: 1)
        material.specular.contents = NSColor(calibratedWhite: scheme == .dark ? 0.45 : 0.20, alpha: 1)
        material.shininess = 0.4
        floor.materials = [material]
        let node = SCNNode(geometry: floor)
        node.position = SCNVector3(0, -0.004, 0)
        node.castsShadow = false
        root.addChildNode(node)
        return root
    }

    private static func lightRig(scheme: ColorScheme) -> [SCNNode] {
        if scheme == .dark {
            return [
                light(type: .ambient, intensity: 170,
                      color: NSColor(calibratedRed: 0.72, green: 0.74, blue: 0.86, alpha: 1),
                      position: SCNVector3(0, 1, 0), castsShadow: false),
                light(type: .directional, intensity: 700, color: .white,
                      position: SCNVector3(1.4, 2.0, 1.6), castsShadow: true),
                light(type: .directional, intensity: 320,
                      color: NSColor(calibratedRed: 0.45, green: 0.60, blue: 1.0, alpha: 1),
                      position: SCNVector3(-1.4, 1.1, -1.2), castsShadow: false),
                light(type: .omni, intensity: 210,
                      color: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.72, alpha: 1),
                      position: SCNVector3(1.0, 0.70, 1.0), castsShadow: false)
            ]
        }
        return [
            light(type: .ambient, intensity: 300,
                  color: NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.95, alpha: 1),
                  position: SCNVector3(0, 1, 0), castsShadow: false),
            light(type: .directional, intensity: 500, color: .white,
                  position: SCNVector3(1.2, 2.0, 1.6), castsShadow: true),
            light(type: .directional, intensity: 140,
                  color: NSColor(calibratedRed: 0.72, green: 0.80, blue: 1.0, alpha: 1),
                  position: SCNVector3(-1.4, 1.1, -1.2), castsShadow: false),
            light(type: .omni, intensity: 120,
                  color: NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.70, alpha: 1),
                  position: SCNVector3(1.0, 0.70, 1.0), castsShadow: false)
        ]
    }

    private static func ringColor(_ index: Int, scheme: ColorScheme) -> NSColor {
        switch (index, scheme) {
        case (0, .dark): return NSColor(calibratedRed: 0.99, green: 0.47, blue: 0.42, alpha: 1)
        case (1, .dark): return NSColor(calibratedRed: 0.99, green: 0.68, blue: 0.32, alpha: 1)
        case (2, .dark): return NSColor(calibratedRed: 0.40, green: 0.84, blue: 0.64, alpha: 1)
        case (0, _):    return NSColor(calibratedRed: 0.90, green: 0.30, blue: 0.26, alpha: 1)
        case (1, _):    return NSColor(calibratedRed: 0.88, green: 0.55, blue: 0.14, alpha: 1)
        default:        return NSColor(calibratedRed: 0.16, green: 0.66, blue: 0.46, alpha: 1)
        }
    }

    // MARK: 程序化身形（人体网格缺失时的兜底）

    private static func proceduralFigure(person: AtlasPerson, scheme: ColorScheme) -> SCNNode {
        // 三围缺失时按罩杯推一个合理的近似值：只用于造型，不写成真实数据。
        let cupOrder = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P"]
        let cupIndex = person.cup.flatMap { cupOrder.firstIndex(of: $0.uppercased()) } ?? 2
        let estimatedBust = Double(78 + cupIndex * 3)
        let bust = CGFloat(person.bust ?? Int(estimatedBust.rounded()))
        let waist = CGFloat(person.waist ?? Int((estimatedBust - 23).rounded()))
        let hips = CGFloat(person.hips ?? Int((estimatedBust + 2).rounded()))
        let bustK = clamp(bust / 85, 0.72, 1.50)
        let waistK = clamp(waist / 62, 0.72, 1.32)
        let hipK = clamp(hips / 88, 0.74, 1.42)

        let model = SCNNode()
        let skin = skinMaterial()
        let hair = hairMaterial()

        let bodyRings: [(y: CGFloat, rx: CGFloat, rz: CGFloat, zc: CGFloat)] = [
            (0.428, 0.046, 0.046, 0),
            (0.452, 0.080, 0.058, -0.002),
            (0.472, 0.106 * hipK, 0.064 * hipK, -0.004),
            (0.500, 0.126 * hipK, 0.086 * hipK, -0.010),
            (0.522, 0.130 * hipK, 0.104 * hipK, -0.014),
            (0.548, 0.126 * hipK, 0.096 * hipK, -0.006),
            (0.578, 0.110 * hipK, 0.084 * hipK, 0),
            (0.612, 0.078 * waistK, 0.060 * waistK, 0),
            (0.642, 0.084 * waistK, 0.064 * waistK, 0),
            (0.672, 0.094, 0.074, 0),
            (0.700, 0.104 * bustK, 0.088 * bustK, 0),
            (0.726, 0.104 * bustK, 0.088 * bustK, 0),
            (0.752, 0.100, 0.082, 0),
            (0.776, 0.102, 0.062, 0),
            (0.792, 0.090, 0.056, 0),
            (0.804, 0.050, 0.042, 0)
        ]
        model.addChildNode(SCNNode(geometry: mesh(rings: bodyRings, material: skin, segments: 64)))

        let breastRadius = 0.028 + 0.024 * ((bustK - 0.72) / 0.78)
        for sign in [-1.0, 1.0] {
            let s = Float(sign)
            let breast = SCNSphere(radius: breastRadius)
            breast.materials = [skin]
            let node = SCNNode(geometry: breast)
            node.scale = SCNVector3(1.0, 0.95, 0.86)
            node.position = SCNVector3(s * 0.042, 0.712, 0.060)
            model.addChildNode(node)
        }

        model.addChildNode(capsule(radius: 0.026, height: 0.056,
                                   position: SCNVector3(0, 0.826, 0.002), material: skin))
        model.addChildNode(sphere(radius: 0.053, scaleY: 1.12,
                                  position: SCNVector3(0, 0.886, 0.006), material: skin))
        let backHead = sphere(radius: 0.058, scaleY: 1.06,
                              position: SCNVector3(0, 0.896, -0.014), material: hair)
        backHead.scale = SCNVector3(1.06, 1.08, 1.04)
        model.addChildNode(backHead)
        for sign in [-1.0, 1.0] {
            let s = Float(sign)
            let side = sphere(radius: 0.026, scaleY: 1.0,
                              position: SCNVector3(s * 0.046, 0.868, 0.002), material: hair)
            side.scale = SCNVector3(1.0, 1.55, 0.95)
            model.addChildNode(side)
        }
        let longHair = sphere(radius: 0.052, scaleY: 2.10,
                              position: SCNVector3(0, 0.800, -0.046), material: hair)
        longHair.scale = SCNVector3(0.92, 2.10, 0.48)
        model.addChildNode(longHair)

        for sign in [-1.0, 1.0] {
            let s = Float(sign)
            model.addChildNode(sphere(radius: 0.027, scaleY: 1.0,
                                      position: SCNVector3(s * 0.097, 0.772, 0), material: skin))
            let arm: [(y: CGFloat, x: CGFloat, r: CGFloat)] = [
                (0.776, 0.098, 0.030),
                (0.742, 0.110, 0.027),
                (0.694, 0.116, 0.024),
                (0.640, 0.120, 0.022),
                (0.588, 0.123, 0.020),
                (0.540, 0.125, 0.017)
            ]
            model.addChildNode(limb(rings: arm, sign: s, material: skin))
            let hand = sphere(radius: 0.021, scaleY: 1.30,
                              position: SCNVector3(s * 0.127, 0.512, 0.004), material: skin)
            hand.scale = SCNVector3(0.85, 1.40, 0.62)
            model.addChildNode(hand)
        }

        for sign in [-1.0, 1.0] {
            let s = Float(sign)
            let leg: [(y: CGFloat, x: CGFloat, r: CGFloat)] = [
                (0.505, 0.050, 0.070),
                (0.462, 0.052, 0.064),
                (0.410, 0.054, 0.054),
                (0.350, 0.054, 0.044),
                (0.290, 0.052, 0.038),
                (0.232, 0.050, 0.034),
                (0.180, 0.050, 0.028),
                (0.120, 0.050, 0.021),
                (0.060, 0.050, 0.017)
            ]
            model.addChildNode(limb(rings: leg, sign: s, material: skin))
            let foot = sphere(radius: 0.024, scaleY: 1.0,
                              position: SCNVector3(s * 0.058, 0.030, 0.026), material: skin)
            foot.scale = SCNVector3(0.85, 0.55, 1.75)
            model.addChildNode(foot)
        }

        model.addChildNode(measureRing(y: 0.706, radius: 0.104 * bustK + 0.008,
                                       color: ringColor(0, scheme: scheme)))
        model.addChildNode(measureRing(y: 0.612, radius: 0.078 * waistK + 0.008,
                                       color: ringColor(1, scheme: scheme)))
        model.addChildNode(measureRing(y: 0.538, radius: 0.130 * hipK + 0.008,
                                       color: ringColor(2, scheme: scheme)))

        let scale = Float(clamp(CGFloat(person.heightCM ?? 160) / 162, 0.94, 1.10))
        model.scale = SCNVector3(scale, scale, scale)
        return model
    }

    // MARK: 形体

    /// 环形截面车削出的躯干，两端封口。
    private static func mesh(rings: [(y: CGFloat, rx: CGFloat, rz: CGFloat, zc: CGFloat)],
                             material: SCNMaterial,
                             segments: Int = 56) -> SCNGeometry {
        var vertices: [SCNVector3] = []

        for ring in rings {
            for s in 0..<segments {
                let angle = CGFloat(s) / CGFloat(segments) * .pi * 2
                let x = cos(angle) * ring.rx
                let z = sin(angle) * ring.rz + ring.zc
                vertices.append(SCNVector3(Float(x), Float(ring.y), Float(z)))
            }
        }

        var indices: [Int32] = []
        for r in 0..<(rings.count - 1) {
            for s in 0..<segments {
                let a = Int32(r * segments + s)
                let b = Int32(r * segments + (s + 1) % segments)
                let c = Int32((r + 1) * segments + s)
                let d = Int32((r + 1) * segments + (s + 1) % segments)
                indices += [a, c, b, b, c, d]
            }
        }

        let bottomCenter = Int32(vertices.count)
        vertices.append(SCNVector3(0, Float(rings[0].y), Float(rings[0].zc)))
        for s in 0..<segments {
            indices += [bottomCenter, Int32((s + 1) % segments), Int32(s)]
        }

        let topCenter = Int32(vertices.count)
        let topRing = rings[rings.count - 1]
        vertices.append(SCNVector3(0, Float(topRing.y), Float(topRing.zc)))
        let topBase = Int32((rings.count - 1) * segments)
        for s in 0..<segments {
            indices += [topCenter, topBase + Int32(s), topBase + Int32((s + 1) % segments)]
        }

        var normals = [SCNVector3](repeating: SCNVector3(0, 0, 0), count: vertices.count)
        var i = 0
        while i < indices.count {
            let ia = Int(indices[i])
            let ib = Int(indices[i + 1])
            let ic = Int(indices[i + 2])
            let normal = faceNormal(vertices[ia], vertices[ib], vertices[ic])
            for index in [ia, ib, ic] {
                normals[index].x += normal.x
                normals[index].y += normal.y
                normals[index].z += normal.z
            }
            i += 3
        }
        normals = normals.map(normalized)

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [material]
        return geometry
    }

    /// 四肢：一组 (高度, 侧向偏移, 半径) 截面，左右镜像，自动收细。
    private static func limb(rings: [(y: CGFloat, x: CGFloat, r: CGFloat)],
                             sign: Float,
                             material: SCNMaterial,
                             segments: Int = 32) -> SCNNode {
        var vertices: [SCNVector3] = []
        for ring in rings {
            for s in 0..<segments {
                let angle = CGFloat(s) / CGFloat(segments) * .pi * 2
                let x = ring.x * CGFloat(sign) + cos(angle) * ring.r
                let z = sin(angle) * ring.r * 0.92
                vertices.append(SCNVector3(Float(x), Float(ring.y), Float(z)))
            }
        }

        var indices: [Int32] = []
        for r in 0..<(rings.count - 1) {
            for s in 0..<segments {
                let a = Int32(r * segments + s)
                let b = Int32(r * segments + (s + 1) % segments)
                let c = Int32((r + 1) * segments + s)
                let d = Int32((r + 1) * segments + (s + 1) % segments)
                indices += [a, c, b, b, c, d]
            }
        }

        let bottomCenter = Int32(vertices.count)
        vertices.append(SCNVector3(Float(rings[0].x * CGFloat(sign)), Float(rings[0].y), 0))
        for s in 0..<segments {
            indices += [bottomCenter, Int32((s + 1) % segments), Int32(s)]
        }
        let topCenter = Int32(vertices.count)
        let last = rings[rings.count - 1]
        vertices.append(SCNVector3(Float(last.x * CGFloat(sign)), Float(last.y), 0))
        let topBase = Int32((rings.count - 1) * segments)
        for s in 0..<segments {
            indices += [topCenter, topBase + Int32(s), topBase + Int32((s + 1) % segments)]
        }

        var normals = [SCNVector3](repeating: SCNVector3(0, 0, 0), count: vertices.count)
        var i = 0
        while i < indices.count {
            let ia = Int(indices[i])
            let ib = Int(indices[i + 1])
            let ic = Int(indices[i + 2])
            let normal = faceNormal(vertices[ia], vertices[ib], vertices[ic])
            for index in [ia, ib, ic] {
                normals[index].x += normal.x
                normals[index].y += normal.y
                normals[index].z += normal.z
            }
            i += 3
        }
        normals = normals.map(normalized)

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func faceNormal(_ a: SCNVector3, _ b: SCNVector3, _ c: SCNVector3) -> SCNVector3 {
        let ab = SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z)
        let ac = SCNVector3(c.x - a.x, c.y - a.y, c.z - a.z)
        return SCNVector3(ab.y * ac.z - ab.z * ac.y,
                          ab.z * ac.x - ab.x * ac.z,
                          ab.x * ac.y - ab.y * ac.x)
    }

    private static func hairMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor(calibratedRed: 0.26, green: 0.17, blue: 0.20, alpha: 1)
        material.specular.contents = NSColor(calibratedWhite: 0.60, alpha: 1)
        material.shininess = 0.38
        return material
    }

    private static func skinMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = AtlasPalette.skin
        material.specular.contents = NSColor(calibratedRed: 1.0, green: 0.94, blue: 0.90, alpha: 1)
        material.shininess = 0.30
        material.isDoubleSided = true
        return material
    }

    private static func measureRing(y: CGFloat, radius: CGFloat,
                                    color: NSColor, pipe: CGFloat = 0.0024) -> SCNNode {
        let torus = SCNTorus(ringRadius: radius, pipeRadius: pipe)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        torus.materials = [material]
        let node = SCNNode(geometry: torus)
        node.position = SCNVector3(0, Float(y), 0)
        return node
    }

    private static func sphere(radius: CGFloat, scaleY: CGFloat,
                               position: SCNVector3, material: SCNMaterial) -> SCNNode {
        let geometry = SCNSphere(radius: radius)
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.scale = SCNVector3(1, Float(scaleY), 1)
        node.position = position
        return node
    }

    private static func capsule(radius: CGFloat, height: CGFloat,
                                position: SCNVector3, material: SCNMaterial) -> SCNNode {
        let geometry = SCNCapsule(capRadius: radius, height: height)
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.position = position
        return node
    }

    private static func light(type: SCNLight.LightType, intensity: CGFloat, color: NSColor,
                              position: SCNVector3, castsShadow: Bool) -> SCNNode {
        let light = SCNLight()
        light.type = type
        light.intensity = intensity
        light.color = color
        light.castsShadow = castsShadow
        if castsShadow {
            light.shadowRadius = 10
            light.shadowSampleCount = 12
            light.shadowColor = NSColor.black.withAlphaComponent(0.45)
        }
        let node = SCNNode()
        node.light = light
        node.position = position
        node.look(at: SCNVector3(0, 0.55, 0))
        return node
    }

    // MARK: 工具

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }

    private static func normalized(_ vector: SCNVector3) -> SCNVector3 {
        let length = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
        guard length > 0 else { return SCNVector3(0, 1, 0) }
        return SCNVector3(vector.x / length, vector.y / length, vector.z / length)
    }
}

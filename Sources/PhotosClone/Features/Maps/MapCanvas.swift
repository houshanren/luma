import SwiftUI
import MapKit
import AppKit

// MARK: - 底图与样式

enum MapProvider: String, CaseIterable, Identifiable {
    case apple
    case amap
    case baidu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "苹果地图"
        case .amap: return "高德地图"
        case .baidu: return "百度地图"
        }
    }

    var shortTitle: String {
        switch self {
        case .apple: return "苹果"
        case .amap: return "高德"
        case .baidu: return "百度"
        }
    }

    var needsKey: Bool { self == .baidu }
}

enum MapStyleMode: String, CaseIterable, Identifiable {
    case map
    case satellite
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: return "地图"
        case .satellite: return "卫星"
        case .grid: return "网格"
        }
    }

    var icon: String {
        switch self {
        case .map: return "map"
        case .satellite: return "globe.asia.australia"
        case .grid: return "square.grid.3x3"
        }
    }
}

// MARK: - 相机控制

final class MapCameraController: ObservableObject {
    weak var mapView: MKMapView?

    func zoom(factor: Double) {
        guard let mapView else { return }
        var region = mapView.region
        region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.0008), 120)
        region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.0008), 160)
        mapView.setRegion(region, animated: true)
    }

    func fit(_ clusters: [PlaceCluster]) {
        guard let mapView, !clusters.isEmpty else { return }
        let points = clusters.map {
            MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
        guard let first = points.first else { return }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 1, height: 1))
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 1, height: 1)))
        }
        if rect.size.width < 1, rect.size.height < 1 {
            let region = MKCoordinateRegion(center: first.coordinate,
                                            span: MKCoordinateSpan(latitudeDelta: 0.25,
                                                                   longitudeDelta: 0.25))
            mapView.setRegion(region, animated: true)
        } else {
            mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 90, left: 90, bottom: 110, right: 90),
                                      animated: true)
        }
    }
}

// MARK: - 瓦片底图

/// 高德栅格瓦片（免密钥），卫星图与街道图都可用。
final class AmapTileOverlay: MKTileOverlay {
    private let satellite: Bool

    init(satellite: Bool) {
        self.satellite = satellite
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 3
        maximumZ = 18
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let server = abs(path.x + path.y) % 4 + 1
        let urlString: String
        if satellite {
            urlString = "https://webst0\(server).is.autonavi.com/appmaptile?style=6&x=\(path.x)&y=\(path.y)&z=\(path.z)"
        } else {
            urlString = "https://webrd0\(server).is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x=\(path.x)&y=\(path.y)&z=\(path.z)"
        }
        return URL(string: urlString)!
    }
}

/// 百度瓦片使用自家的墨卡托编号，需要把地图瓦片中心点转换成百度瓦片序号。
/// 需要用户在「位置」里填写百度地图开放平台的 AK。
final class BaiduTileOverlay: MKTileOverlay {
    private let accessKey: String

    init(accessKey: String) {
        self.accessKey = accessKey
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 3
        maximumZ = 18
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let worldSize = MKMapSize.world.width
        let tileSpan = worldSize / pow(2.0, Double(path.z))
        let point = MKMapPoint(x: (Double(path.x) + 0.5) * tileSpan,
                               y: (Double(path.y) + 0.5) * tileSpan)
        let coordinate = point.coordinate
        let tile = CoordinateShift.baiduTile(latitude: coordinate.latitude,
                                             longitude: coordinate.longitude,
                                             zoom: path.z)
        let server = abs(tile.x + tile.y) % 4
        let urlString = "https://maponline\(server).bdimg.com/tile/?qt=vtile&x=\(tile.x)&y=\(tile.y)"
            + "&z=\(path.z)&styles=pl&scaler=1&udt=20220601&ak=\(accessKey)"
        guard let url = URL(string: urlString) else {
            result(nil, nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let data, !data.isEmpty {
                result(data, nil)
            } else {
                result(nil, error)
            }
        }.resume()
    }
}

// MARK: - 标注

final class PlaceAnnotation: NSObject, MKAnnotation {
    let cluster: PlaceCluster
    dynamic var coordinate: CLLocationCoordinate2D

    init(cluster: PlaceCluster, coordinate: CLLocationCoordinate2D) {
        self.cluster = cluster
        self.coordinate = coordinate
        super.init()
    }

    var title: String? { cluster.title }
    var subtitle: String? { "\(cluster.count) 张照片" }
}

/// 照片卡片标记：白色相框 + 投影 + 多张照片的层叠效果。
final class PhotoPinView: MKAnnotationView {
    private let backCard = NSView()
    private let backCard2 = NSView()
    private let card = NSView()
    private let thumb = ThumbLayerView()
    private let badge = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = NSRect(x: 0, y: 0, width: 78, height: 84)
        centerOffset = CGPoint(x: 0, y: -32)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        for view in [backCard2, backCard] {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
            view.layer?.cornerRadius = 9
            view.layer?.borderWidth = 0.5
            view.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
            addSubview(view)
        }

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 9
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.35
        card.layer?.shadowRadius = 7
        card.layer?.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(card)

        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.layer?.contentsGravity = .resizeAspectFill
        thumb.layer?.backgroundColor = NSColor.darkGray.withAlphaComponent(0.35).cgColor
        addSubview(thumb)

        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = 9
        addSubview(badge)

        badgeLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.isBordered = false
        badgeLabel.isEditable = false
        badgeLabel.drawsBackground = false
        addSubview(badgeLabel)

        canShowCallout = false
        collisionMode = .circle
    }

    func apply(cluster: PlaceCluster, style: MapStyleMode) {
        let size: CGFloat = style == .grid ? 62 : 52
        let cardWidth = size + 10
        let cardHeight = size + 10
        let cardY = bounds.height - cardHeight - 4
        card.frame = NSRect(x: (bounds.width - cardWidth) / 2, y: cardY, width: cardWidth, height: cardHeight)
        thumb.frame = card.frame.insetBy(dx: 5, dy: 5)

        backCard.frame = card.frame.offsetBy(dx: -1, dy: -3)
        backCard.layer?.setAffineTransform(CGAffineTransform(rotationAngle: -0.09))
        backCard2.frame = card.frame.offsetBy(dx: 2, dy: -5)
        backCard2.layer?.setAffineTransform(CGAffineTransform(rotationAngle: 0.10))

        let isCluster = cluster.count > 1
        backCard.isHidden = !isCluster
        backCard2.isHidden = cluster.count < 3

        if let photo = cluster.cover, let image = ImageLoader.gridThumbnail(for: photo, maxPixel: 128),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            thumb.layer?.contents = cgImage
        } else {
            thumb.layer?.contents = nil
        }

        badge.isHidden = cluster.count < 2
        badgeLabel.isHidden = cluster.count < 2
        badgeLabel.stringValue = "\(cluster.count)"
        let badgeY = bounds.height - 20
        badge.frame = NSRect(x: bounds.width - 30, y: badgeY, width: 26, height: 18)
        badgeLabel.frame = NSRect(x: bounds.width - 30, y: badgeY + 2, width: 26, height: 14)

        layer?.shadowColor = NSColor.systemTeal.cgColor
        layer?.shadowOpacity = style == .grid ? 0.45 : 0
        layer?.shadowRadius = style == .grid ? 12 : 0
        layer?.shadowOffset = .zero
    }
}

private final class ThumbLayerView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 地图画布

struct MapCanvasView: NSViewRepresentable {
    let clusters: [PlaceCluster]
    let provider: MapProvider
    let style: MapStyleMode
    let baiduKey: String
    let controller: MapCameraController
    let onOpen: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.mapType = .standard
        controller.mapView = mapView
        context.coordinator.applyIfNeeded(mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyIfNeeded(mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapCanvasView
        private var styleSignature = ""
        private var clusterSignature = ""
        private var didFit = false

        init(parent: MapCanvasView) {
            self.parent = parent
        }

        func applyIfNeeded(_ mapView: MKMapView) {
            let styleSignature = "\(parent.provider.rawValue)|\(parent.style.rawValue)|\(parent.baiduKey)"
            if styleSignature != self.styleSignature {
                self.styleSignature = styleSignature
                applyBaseStyle(mapView)
            }

            let clusterSignature = parent.clusters.map { "\($0.id)#\($0.count)" }.joined(separator: ",")
            if clusterSignature != self.clusterSignature {
                self.clusterSignature = clusterSignature
                reloadAnnotations(mapView)
            }

            if !didFit, !parent.clusters.isEmpty {
                didFit = true
                let clusters = parent.clusters
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.parent.controller.fit(clusters)
                }
            }
        }

        private func applyBaseStyle(_ mapView: MKMapView) {
            mapView.removeOverlays(mapView.overlays)
            switch parent.provider {
            case .apple:
                if parent.style == .satellite {
                    mapView.mapType = .hybrid
                } else if parent.style == .grid {
                    mapView.mapType = .mutedStandard
                } else {
                    mapView.mapType = .standard
                }
            case .amap:
                mapView.mapType = .standard
                mapView.addOverlay(AmapTileOverlay(satellite: parent.style == .satellite), level: .aboveLabels)
            case .baidu:
                if parent.baiduKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    mapView.mapType = parent.style == .satellite ? .hybrid : .standard
                } else {
                    mapView.mapType = .standard
                    mapView.addOverlay(BaiduTileOverlay(accessKey: parent.baiduKey), level: .aboveLabels)
                }
            }
            mapView.showsBuildings = parent.style != .grid
        }

        private func reloadAnnotations(_ mapView: MKMapView) {
            mapView.removeAnnotations(mapView.annotations)
            let baiduHasKey = parent.provider == .baidu
                && !parent.baiduKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            for cluster in parent.clusters {
                let coordinate: CLLocationCoordinate2D
                switch parent.provider {
                case .apple:
                    coordinate = cluster.coordinate
                case .amap:
                    let shifted = CoordinateShift.wgs84ToGcj02(latitude: cluster.latitude,
                                                               longitude: cluster.longitude)
                    coordinate = CLLocationCoordinate2D(latitude: shifted.latitude, longitude: shifted.longitude)
                case .baidu:
                    if baiduHasKey {
                        let shifted = CoordinateShift.wgs84ToBd09(latitude: cluster.latitude,
                                                                  longitude: cluster.longitude)
                        coordinate = CLLocationCoordinate2D(latitude: shifted.latitude, longitude: shifted.longitude)
                    } else {
                        coordinate = cluster.coordinate
                    }
                }
                mapView.addAnnotation(PlaceAnnotation(cluster: cluster, coordinate: coordinate))
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let place = annotation as? PlaceAnnotation else { return nil }
            let identifier = "photo-pin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? PhotoPinView
                ?? PhotoPinView(annotation: place, reuseIdentifier: identifier)
            view.annotation = place
            view.apply(cluster: place.cluster, style: parent.style)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let place = view.annotation as? PlaceAnnotation else { return }
            mapView.deselectAnnotation(view.annotation, animated: false)
            if let id = place.cluster.cover?.id {
                parent.onOpen(id)
            }
        }
    }
}

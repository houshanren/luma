import Foundation

/// 百度地图瓦片下载：MapKit 只负责坐标转换与回调，网络请求留在服务层。
enum BaiduTileService {
    static func tileData(server: Int,
                         x: Int,
                         y: Int,
                         zoom: Int,
                         accessKey: String) async -> (Data?, Error?) {
        let urlString = "https://maponline\(server).bdimg.com/tile/?qt=vtile&x=\(x)&y=\(y)"
            + "&z=\(zoom)&styles=pl&scaler=1&udt=20220601&ak=\(accessKey)"
        guard let url = URL(string: urlString) else { return (nil, nil) }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data.isEmpty ? (nil, nil) : (data, nil)
        } catch {
            return (nil, error)
        }
    }
}

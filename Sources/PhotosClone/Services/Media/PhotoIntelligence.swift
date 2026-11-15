import AppKit
import Foundation
import Vision

/// 端侧照片内容分析：场景分类标签 + OCR 文字 + 图像特征向量。
/// 全部在本机 Vision 框架内完成，不上传任何照片。
enum PhotoIntelligence {
    struct Result {
        /// 空格分隔的 Vision 分类标签（小写英文）。
        let labels: String
        /// OCR 识别出的文字，可能为空。
        let text: String
        /// 归一化后的图像特征向量（Float32），用于相似照片检索。
        let feature: Data?
    }

    static func analyze(_ photo: PhotoItem) -> Result? {
        guard !photo.isVideo,
              let image = ImageLoader.thumbnail(for: photo),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let classify = VNClassifyImageRequest()
        let recognize = VNRecognizeTextRequest()
        recognize.recognitionLevel = .accurate
        recognize.usesLanguageCorrection = true
        recognize.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([classify, recognize])
        } catch {
            return nil
        }

        let labels = (classify.results ?? [])
            .filter { $0.confidence >= 0.12 }
            .prefix(20)
            .map { $0.identifier.lowercased() }
            .joined(separator: " ")

        let text = (recognize.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        let trimmedText = String(text.prefix(2000))

        var feature: Data?
        let featureRequest = VNGenerateImageFeaturePrintRequest()
        if (try? handler.perform([featureRequest])) != nil,
           let observation = featureRequest.results?.first {
            feature = normalizedVectorData(observation)
        }

        return Result(labels: labels, text: trimmedText, feature: feature)
    }

    /// 把 Vision 特征向量转成归一化后的 Float32 数据，便于直接点积算余弦相似度。
    private static func normalizedVectorData(_ observation: VNFeaturePrintObservation) -> Data? {
        guard observation.elementType == .float else { return nil }
        let count = observation.elementCount
        guard count > 0 else { return nil }
        var values = [Float](repeating: 0, count: count)
        (observation.data as Data).withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Float.self)
            for index in 0..<min(count, source.count) {
                values[index] = source[index]
            }
        }
        var norm: Float = 0
        for value in values { norm += value * value }
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        for index in values.indices { values[index] /= norm }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

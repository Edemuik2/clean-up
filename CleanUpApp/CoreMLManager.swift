import Foundation
import CoreML
import UIKit

final class CoreMLManager: @unchecked Sendable {
    private var segmentationModel: MLModel?
    private var inpaintingModel: MLModel?
    private let imageProcessor = ImageProcessor()
    
    func loadModels() {
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                
                if let samURL = Bundle.main.url(forResource: "MobileSAM", withExtension: "mlmodelc") {
                    self.segmentationModel = try? MLModel(contentsOf: samURL, configuration: config)
                }
                
                if let lamaURL = Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc") {
                    self.inpaintingModel = try? MLModel(contentsOf: lamaURL, configuration: config)
                }
            }
        }
    }
    
    func segment(image: UIImage, point: CGPoint) async -> UIImage? {
        // Если модель сегментации не загрузилась, сразу возвращаем nil, чтобы сработал fallback (рисованная маска)
        guard let model = self.segmentationModel else { return nil }
        
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    do {
                        guard let resizedImage = self.imageProcessor.resizeForModel(image: image),
                              let cgImage = resizedImage.cgImage else {
                            continuation.resume(returning: nil)
                            return
                        }
                        
                        // CoreML сам подгонит формат пикселей
                        let imageFeature = try MLFeatureValue(cgImage: cgImage, pixelsWide: cgImage.width, pixelsHigh: cgImage.height, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil)
                        
                        let pointCoords = try MLMultiArray(shape: [1, 1, 2], dataType: .float32)
                        // Масштабируем координаты точки под размер сжатой картинки
                        let scaleX = resizedImage.size.width / image.size.width
                        let scaleY = resizedImage.size.height / image.size.height
                        pointCoords[0] = NSNumber(value: Float(point.x * scaleX))
                        pointCoords[1] = NSNumber(value: Float(point.y * scaleY))
                        
                        let pointLabels = try MLMultiArray(shape: [1, 1], dataType: .float32)
                        pointLabels[0] = NSNumber(value: 1.0)
                        
                        let inputs: [String: Any] = [
                            "image": imageFeature,
                            "point_coords": pointCoords,
                            "point_labels": pointLabels
                        ]
                        
                        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
                        let prediction = try model.prediction(from: provider)
                        
                        if let maskBuffer = prediction.featureValue(for: "masks")?.imageBufferValue,
                           let maskImage = self.imageProcessor.createUIImage(from: maskBuffer) {
                            // Возвращаем маску, растянутую обратно до оригинального размера
                            let finalMask = self.imageProcessor.resizeToOriginal(image: maskImage, originalSize: image.size)
                            continuation.resume(returning: finalMask)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    } catch {
                        print("Segmentation error: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
    
    func inpaint(image: UIImage, mask: UIImage) async -> UIImage? {
        guard let model = self.inpaintingModel else { return nil }
        
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    do {
                        // 1. Сжимаем фото и маску до безопасного размера (иначе вылет по памяти)
                        guard let resizedImage = self.imageProcessor.resizeForModel(image: image),
                              let resizedMask = self.imageProcessor.resizeForModel(image: mask),
                              let imageCG = resizedImage.cgImage,
                              let maskCG = resizedMask.cgImage else {
                            continuation.resume(returning: nil)
                            return
                        }
                        
                        // 2. Используем MLFeatureValue. CoreML автоматически конвертирует маску в Grayscale, если модель этого требует!
                        let imageFeature = try MLFeatureValue(cgImage: imageCG, pixelsWide: imageCG.width, pixelsHigh: imageCG.height, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil)
                        let maskFeature = try MLFeatureValue(cgImage: maskCG, pixelsWide: maskCG.width, pixelsHigh: maskCG.height, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil)
                        
                        let inputs: [String: Any] = [
                            "image": imageFeature,
                            "mask": maskFeature
                        ]
                        
                        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
                        let prediction = try model.prediction(from: provider)
                        
                        // 3. Получаем результат и растягиваем его обратно до оригинального разрешения
                        if let outputBuffer = prediction.featureValue(for: "output")?.imageBufferValue,
                           let outputImage = self.imageProcessor.createUIImage(from: outputBuffer) {
                            let finalImage = self.imageProcessor.resizeToOriginal(image: outputImage, originalSize: image.size)
                            continuation.resume(returning: finalImage)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    } catch {
                        print("Inpainting error: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

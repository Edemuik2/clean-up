import Foundation
import CoreML
import UIKit

class CoreMLManager {
    private var segmentationModel: MLModel?
    private var inpaintingModel: MLModel?
    private let imageProcessor = ImageProcessor()
    
    func loadModels() {
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                let config = MLModelConfiguration()
                config.computeUnits = .all // Максимальное использование ANE
                
                // Загрузка MobileSAM
                if let samURL = Bundle.main.url(forResource: "MobileSAM", withExtension: "mlmodelc") {
                    self.segmentationModel = try? MLModel(contentsOf: samURL, configuration: config)
                }
                
                // Загрузка LaMa
                if let lamaURL = Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc") {
                    self.inpaintingModel = try? MLModel(contentsOf: lamaURL, configuration: config)
                }
            }
        }
    }
    
    func segment(image: UIImage, point: CGPoint) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    guard let model = self.segmentationModel,
                          let pixelBuffer = self.imageProcessor.createPixelBuffer(from: image) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    do {
                        // Подготовка входных данных для MobileSAM (координаты точки)
                        let pointCoords = try MLMultiArray(shape: [1, 1, 2], dataType: .float32)
                        pointCoords[0] = NSNumber(value: Float(point.x))
                        pointCoords[1] = NSNumber(value: Float(point.y))
                        
                        let pointLabels = try MLMultiArray(shape: [1, 1], dataType: .float32)
                        pointLabels[0] = NSNumber(value: 1.0) // 1.0 означает foreground
                        
                        let inputs: [String: Any] = [
                            "image": pixelBuffer,
                            "point_coords": pointCoords,
                            "point_labels": pointLabels
                        ]
                        
                        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
                        let prediction = try model.prediction(from: provider)
                        
                        if let maskBuffer = prediction.featureValue(for: "masks")?.imageBufferValue {
                            let maskImage = self.imageProcessor.createUIImage(from: maskBuffer)
                            continuation.resume(returning: maskImage)
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
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    guard let model = self.inpaintingModel,
                          let imageBuffer = self.imageProcessor.createPixelBuffer(from: image),
                          let maskBuffer = self.imageProcessor.createPixelBuffer(from: mask) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    do {
                        let inputs: [String: Any] = [
                            "image": imageBuffer,
                            "mask": maskBuffer
                        ]
                        
                        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
                        let prediction = try model.prediction(from: provider)
                        
                        if let outputBuffer = prediction.featureValue(for: "output")?.imageBufferValue {
                            let outputImage = self.imageProcessor.createUIImage(from: outputBuffer)
                            continuation.resume(returning: outputImage)
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
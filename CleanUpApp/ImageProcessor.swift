import UIKit
import CoreImage
import Accelerate
import SwiftUI

final class ImageProcessor: @unchecked Sendable {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    
    // Безопасный ресайз для CoreML (макс 1024 по длинной стороне)
    func resizeForModel(image: UIImage, maxDimension: CGFloat = 1024) -> UIImage? {
        let size = image.size
        let ratio = size.width / size.height
        var newSize = size
        
        if size.width > maxDimension || size.height > maxDimension {
            if ratio > 1 {
                newSize = CGSize(width: maxDimension, height: maxDimension / ratio)
            } else {
                newSize = CGSize(width: maxDimension * ratio, height: maxDimension)
            }
        }
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    // Возврат к оригинальному разрешению
    func resizeToOriginal(image: UIImage, originalSize: CGSize) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: originalSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: originalSize))
        }
    }
    
    func createMaskImage(from path: Path, size: CGSize) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true // Маска должна быть строго непрозрачной (черно-белой)
        
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            // Черный фон (0)
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            ctx.cgContext.fill(CGRect(origin: .zero, size: size))
            
            // Белая кисть (255) - зона для удаления
            ctx.cgContext.setStrokeColor(UIColor.white.cgColor)
            ctx.cgContext.setLineWidth(40)
            ctx.cgContext.setLineCap(.round)
            ctx.cgContext.setLineJoin(.round)
            
            ctx.cgContext.addPath(path.cgPath)
            ctx.cgContext.strokePath()
        }
        return image
    }
    
    func createUIImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

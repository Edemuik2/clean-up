import SwiftUI

struct EditorView: View {
    @State var image: UIImage
    var onCancel: () -> Void
    
    @State private var currentPath = Path()
    @State private var isEraserActive = true
    @State private var isProcessing = false
    @State private var maskOpacity: Double = 1.0
    @State private var segmentedMask: UIImage? = nil
    
    private let coreMLManager = CoreMLManager()
    private let imageProcessor = ImageProcessor()
    
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    
                    // Слой с маской сегментации
                    if let mask = segmentedMask {
                        Image(uiImage: mask)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .opacity(maskOpacity)
                            .blendMode(.screen)
                    }
                    
                    // Слой рисования (Неоновый эффект)
                    Canvas { context, size in
                        let imageRect = calculateImageRect(in: size, imageSize: image.size)
                        
                        // Смещение и масштабирование пути под отображаемую картинку
                        var transform = CGAffineTransform(translationX: imageRect.minX, y: imageRect.minY)
                        let scale = imageRect.width / image.size.width
                        transform = transform.scaledBy(x: scale, y: scale)
                        
                        let scaledPath = currentPath.applying(transform)
                        
                        // Неоновое свечение
                        context.stroke(
                            scaledPath,
                            with: .linearGradient(
                                Gradient(colors: [.pink, .purple, .cyan]),
                                startPoint: .zero,
                                endPoint: CGPoint(x: size.width, y: size.height)
                            ),
                            lineWidth: 30
                        )
                        
                        // Белое ядро
                        context.stroke(scaledPath, with: .color(.white), lineWidth: 10)
                    }
                    .blur(radius: 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard isEraserActive, !isProcessing else { return }
                                let imageRect = calculateImageRect(in: geometry.size, imageSize: image.size)
                                guard imageRect.contains(value.location) else { return }
                                
                                // Перевод координат экрана в координаты оригинального изображения
                                let localX = (value.location.x - imageRect.minX) * (image.size.width / imageRect.width)
                                let localY = (value.location.y - imageRect.minY) * (image.size.height / imageRect.height)
                                let point = CGPoint(x: localX, y: localY)
                                
                                if currentPath.isEmpty {
                                    currentPath.move(to: point)
                                } else {
                                    currentPath.addLine(to: point)
                                }
                            }
                            .onEnded { _ in
                                guard isEraserActive, !currentPath.isEmpty else { return }
                                runSegmentation()
                            }
                    )
                    
                    if isProcessing {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        ProgressView("Обработка ИИ...")
                            .tint(.white)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(12)
                    }
                }
            }
            
            // Панель управления
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                Button(action: {
                    isEraserActive.toggle()
                }) {
                    Image(systemName: "eraser.fill")
                        .font(.title2)
                        .foregroundColor(isEraserActive ? .black : .white)
                        .padding()
                        .background(isEraserActive ? Color.white : Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                Button(action: runInpainting) {
                    Text("Стереть")
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(currentPath.isEmpty && segmentedMask == nil ? Color.gray : Color.blue)
                        .cornerRadius(20)
                }
                .disabled(currentPath.isEmpty && segmentedMask == nil || isProcessing)
                
                Spacer()
                
                Button(action: saveImage) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(UIColor.systemBackground).ignoresSafeArea())
        }
        .onAppear {
            coreMLManager.loadModels()
        }
    }
    
    private func calculateImageRect(in viewSize: CGSize, imageSize: CGSize) -> CGRect {
        let viewRatio = viewSize.width / viewSize.height
        let imageRatio = imageSize.width / imageSize.height
        
        var rect = CGRect.zero
        if imageRatio > viewRatio {
            rect.size.width = viewSize.width
            rect.size.height = viewSize.width / imageRatio
            rect.origin.x = 0
            rect.origin.y = (viewSize.height - rect.size.height) / 2
        } else {
            rect.size.height = viewSize.height
            rect.size.width = viewSize.height * imageRatio
            rect.origin.y = 0
            rect.origin.x = (viewSize.width - rect.size.width) / 2
        }
        return rect
    }
    
    private func runSegmentation() {
        guard !currentPath.isEmpty else { return }
        isProcessing = true
        
        Task {
            let boundingBox = currentPath.boundingRect
            let centerPoint = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
            
            if let resultMask = await coreMLManager.segment(image: image, point: centerPoint) {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.segmentedMask = resultMask
                        self.currentPath = Path() // Очищаем линию, оставляем маску
                    }
                    self.isProcessing = false
                }
            } else {
                // Фолбэк: если модель не сработала, используем нарисованный путь как маску
                let fallbackMask = imageProcessor.createMaskImage(from: currentPath, size: image.size)
                await MainActor.run {
                    self.segmentedMask = fallbackMask
                    self.currentPath = Path()
                    self.isProcessing = false
                }
            }
        }
    }
    
    private func runInpainting() {
        guard let mask = segmentedMask else { return }
        isProcessing = true
        
        Task {
            if let resultImage = await coreMLManager.inpaint(image: image, mask: mask) {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.maskOpacity = 0
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.image = resultImage
                        self.segmentedMask = nil
                        self.maskOpacity = 1.0
                        self.isProcessing = false
                    }
                }
            } else {
                await MainActor.run {
                    self.isProcessing = false
                }
            }
        }
    }
    
    private func saveImage() {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
}
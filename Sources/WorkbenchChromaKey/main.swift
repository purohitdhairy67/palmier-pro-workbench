@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal

struct Options {
    var inputURL: URL
    var outputURL: URL
    var keyColor = SIMD3<Double>(0.0, 0.78, 0.0)
    var similarity = 0.34
    var softness = 0.12
    var despill = 0.65
    var backgroundColor: SIMD3<Double>?
}

enum ChromaKeyError: LocalizedError {
    case usage
    case invalidOption(String)
    case noVideoTrack
    case cannotCreateMetalDevice
    case readerSetup(Error?)
    case writerSetup(Error?)
    case pixelBufferPool
    case appendFailed(Error?)
    case writeFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: WorkbenchChromaKey --input in.mp4 --output keyed.mov [--key-rgb 0,0.78,0] [--similarity 0.34] [--softness 0.12] [--despill 0.65] [--background-rgb 0.95,0.95,0.95]"
        case .invalidOption(let message): message
        case .noVideoTrack: "No video track found"
        case .cannotCreateMetalDevice: "Could not create a Metal device"
        case .readerSetup(let error): "Could not set up video reader: \(error?.localizedDescription ?? "unknown error")"
        case .writerSetup(let error): "Could not set up ProRes 4444 writer: \(error?.localizedDescription ?? "unknown error")"
        case .pixelBufferPool: "Could not create output pixel buffer"
        case .appendFailed(let error): "Could not append keyed frame: \(error?.localizedDescription ?? "unknown error")"
        case .writeFailed(let error): "Could not finish writing keyed video: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}

final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func resume(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(with: result)
    }
}

final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

let kernelSource = """
kernel vec4 chromaKey(__sample image, vec3 keyColor, float similarity, float softness, float despill, vec4 background) {
    vec3 rgb = clamp(image.rgb, 0.0, 1.0);
    float greenExcess = rgb.g - max(rgb.r, rgb.b);
    float alpha = 1.0 - smoothstep(similarity - softness, similarity + softness, greenExcess);

    greenExcess = max(greenExcess, 0.0);
    float edgeDespill = (1.0 - alpha) + 0.35;
    rgb.g = max(0.0, rgb.g - greenExcess * despill * edgeDespill);

    if (background.a > 0.5) {
        return vec4(mix(background.rgb, rgb, alpha), 1.0);
    }
    return vec4(rgb, image.a * alpha);
}
"""

@main
enum WorkbenchChromaKey {
    static func main() async {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            try await render(options)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }

    private static func parseOptions(_ args: [String]) throws -> Options {
        guard !args.isEmpty else { throw ChromaKeyError.usage }
        var input: URL?
        var output: URL?
        var keyColor = SIMD3<Double>(0.0, 0.78, 0.0)
        var similarity = 0.34
        var softness = 0.12
        var despill = 0.65
        var backgroundColor: SIMD3<Double>?

        var index = 0
        while index < args.count {
            let flag = args[index]
            guard index + 1 < args.count else { throw ChromaKeyError.invalidOption("Missing value for \(flag)") }
            let value = args[index + 1]
            switch flag {
            case "--input":
                input = URL(fileURLWithPath: value)
            case "--output":
                output = URL(fileURLWithPath: value)
            case "--key-rgb":
                keyColor = try parseRGB(value)
            case "--similarity":
                similarity = try parseUnit(value, name: flag)
            case "--softness":
                softness = try parseUnit(value, name: flag)
            case "--despill":
                despill = try parseUnit(value, name: flag)
            case "--background-rgb":
                backgroundColor = try parseRGB(value)
            default:
                throw ChromaKeyError.invalidOption("Unknown option: \(flag)")
            }
            index += 2
        }

        guard let input, let output else { throw ChromaKeyError.usage }
        return Options(
            inputURL: input,
            outputURL: output,
            keyColor: keyColor,
            similarity: similarity,
            softness: softness,
            despill: despill,
            backgroundColor: backgroundColor
        )
    }

    private static func parseRGB(_ value: String) throws -> SIMD3<Double> {
        let parts = value.split(separator: ",").map(String.init)
        guard parts.count == 3,
              let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else {
            throw ChromaKeyError.invalidOption("--key-rgb expects r,g,b values between 0 and 1")
        }
        return SIMD3(clamp01(r), clamp01(g), clamp01(b))
    }

    private static func parseUnit(_ value: String, name: String) throws -> Double {
        guard let parsed = Double(value), parsed.isFinite else {
            throw ChromaKeyError.invalidOption("\(name) expects a number between 0 and 1")
        }
        return clamp01(parsed)
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func render(_ options: Options) async throws {
        let asset = AVURLAsset(url: options.inputURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ChromaKeyError.noVideoTrack
        }
        let size = try await outputSize(for: track)
        let preferredTransform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let frameRate = try await track.load(.nominalFrameRate)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw ChromaKeyError.readerSetup(reader.error) }
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: options.outputURL)
        try FileManager.default.createDirectory(
            at: options.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer = try AVAssetWriter(outputURL: options.outputURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else { throw ChromaKeyError.writerSetup(writer.error) }
        writer.add(input)

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ChromaKeyError.cannotCreateMetalDevice
        }
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ])
        guard let kernel = CIColorKernel(source: kernelSource) else {
            throw ChromaKeyError.invalidOption("Could not compile Core Image chroma key kernel")
        }

        guard reader.startReading() else { throw ChromaKeyError.readerSetup(reader.error) }
        guard writer.startWriting() else { throw ChromaKeyError.writerSetup(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "io.palmier.workbench.chroma-key")
        let started = Date()
        let totalSeconds = duration.seconds.isFinite ? duration.seconds : 0
        let backgroundVector = CIVector(
            x: options.backgroundColor?.x ?? 0,
            y: options.backgroundColor?.y ?? 0,
            z: options.backgroundColor?.z ?? 0,
            w: options.backgroundColor == nil ? 0 : 1
        )

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let completion = CompletionBox()
            let frameCounter = CounterBox()

            @Sendable func resume(_ result: Result<Void, Error>) {
                completion.resume(cont, with: result)
            }

            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = readerOutput.copyNextSampleBuffer() else {
                        if reader.status == .failed {
                            resume(.failure(ChromaKeyError.readerSetup(reader.error)))
                        } else {
                            input.markAsFinished()
                            resume(.success(()))
                        }
                        return
                    }
                    guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample),
                          let outputBuffer = makePixelBuffer(from: adaptor, size: size) else {
                        resume(.failure(ChromaKeyError.pixelBufferPool))
                        return
                    }

                    let sourceImage = orientedImage(
                        CIImage(cvPixelBuffer: sourceBuffer),
                        preferredTransform: preferredTransform,
                        outputSize: size,
                        sourceExtent: sourceImageExtent(sourceBuffer)
                    )
                    let cropped = sourceImage.cropped(to: CGRect(origin: .zero, size: size))
                    guard let keyed = kernel.apply(
                        extent: cropped.extent,
                        arguments: [
                            cropped,
                            CIVector(x: options.keyColor.x, y: options.keyColor.y, z: options.keyColor.z),
                            Float(options.similarity),
                            Float(options.softness),
                            Float(options.despill),
                            backgroundVector,
                        ]
                    ) else {
                        resume(.failure(ChromaKeyError.invalidOption("Could not apply chroma key kernel")))
                        return
                    }

                    context.render(keyed, to: outputBuffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    if !adaptor.append(outputBuffer, withPresentationTime: pts) {
                        resume(.failure(ChromaKeyError.appendFailed(writer.error)))
                        return
                    }

                    let frames = frameCounter.increment()
                    if frames % 90 == 0 {
                        let seconds = pts.seconds.isFinite ? pts.seconds : 0
                        let percent = totalSeconds > 0 ? min(100, seconds / totalSeconds * 100) : 0
                        print(String(format: "keyed %.1f%% (%d frames)", percent, frames))
                    }
                }
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw ChromaKeyError.writeFailed(writer.error) }

        let elapsed = Date().timeIntervalSince(started)
        let fps = frameRate > 0 ? String(format: "%.2f", frameRate) : "unknown"
        print("done \(options.outputURL.path) fps=\(fps) elapsed=\(String(format: "%.1f", elapsed))s")
    }

    private static func makePixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer != nil { return buffer }
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary, &buffer)
        return buffer
    }

    private static func outputSize(for track: AVAssetTrack) async throws -> CGSize {
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = even(abs(rect.width) > 0 ? abs(rect.width) : naturalSize.width)
        let height = even(abs(rect.height) > 0 ? abs(rect.height) : naturalSize.height)
        return CGSize(width: width, height: height)
    }

    private static func even(_ value: Double) -> Int {
        max(2, (Int(value.rounded()) / 2) * 2)
    }

    private static func sourceImageExtent(_ buffer: CVPixelBuffer) -> CGRect {
        CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }

    private static func orientationTransform(_ transform: CGAffineTransform, imageExtent: CGRect) -> CGAffineTransform {
        let transformed = imageExtent.applying(transform)
        return transform.concatenating(CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY))
    }

    private static func orientedImage(
        _ image: CIImage,
        preferredTransform: CGAffineTransform,
        outputSize: CGSize,
        sourceExtent: CGRect
    ) -> CIImage {
        var oriented = image.transformed(by: orientationTransform(preferredTransform, imageExtent: sourceExtent))
        if preferredTransform.a == 0, preferredTransform.b > 0, preferredTransform.c < 0, preferredTransform.d == 0 {
            oriented = oriented.transformed(
                by: CGAffineTransform(translationX: outputSize.width, y: outputSize.height)
                    .rotated(by: .pi)
            )
        }
        return oriented
    }
}

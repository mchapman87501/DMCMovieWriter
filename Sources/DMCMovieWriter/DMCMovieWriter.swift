// Many thanks to:
// https://ios.programmingpedia.net/en/tutorial/10607/create-a-video-from-images

import AVFoundation
import AppKit  // For NSImage
import CoreGraphics  // For CGImage
import Foundation

private func getAdapter(writerInput: AVAssetWriterInput)
    -> AVAssetWriterInputPixelBufferAdaptor
{
    let attrs: [String: Any] = [
        String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32ARGB,
        String(kCVPixelBufferCGImageCompatibilityKey): true,
        String(kCVPixelBufferCGBitmapContextCompatibilityKey): true,
    ]
    return AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: writerInput, sourcePixelBufferAttributes: attrs)
}

private func getPixelBuff(pixelWidth w: Int, height h: Int) -> CVPixelBuffer? {
    let attrs = [
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferCGImageCompatibilityKey: true,
    ]

    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        nil, w, h, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &result
    )
    if status == kCVReturnSuccess {
        return result
    }
    return nil
}

private func createPixelBuff(from img: NSImage) -> CVPixelBuffer? {
    var result: CVPixelBuffer?
    autoreleasepool {
        let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let ciImage = CIImage(cgImage: cgImg)
        result = getPixelBuff(pixelWidth: cgImg.width, height: cgImg.height)
        CIContext().render(ciImage, to: result!)
    }
    return result
}

/// A type representing some kinds of errors that can arise when creating movies.
public enum DMCMovieWriterError: Error {
    /// An error that indicates something went wrong during movie initialization,
    /// e.g., a failure to remove an existing movie at the given path, or an inability to create an `AVAssetWriter`.
    case initError(msg: String)

    /// An error that indicates a problem adding a frame to a movie.
    case addFrameError(msg: String)

    /// An error that indicates a timeout occurred when trying to flush movie frames.
    case writeTimeout(msg: String)
}

/// DMCMovieWriter creates movies from sequences of `NSImage`s.
public class DMCMovieWriter {
    struct BuffInfo {
        let buffer: CVPixelBuffer
        let duration: Double  // How long to show this buffered image, in seconds.
    }

    let outPath: URL
    let writer: AVAssetWriter
    let writerInput: AVAssetWriterInput
    let adapter: AVAssetWriterInputPixelBufferAdaptor

    private var currFrame = 0
    private var currTime = 0.0

    private let prepareQ = DispatchQueue(
        label: "Prepare pixel buff", qos: .utility, attributes: .concurrent)
    private let storeQ = DispatchQueue(label: "Store buffer")
    private let prepareGroup = DispatchGroup()

    typealias BuffInfoResult = Result<BuffInfo, DMCMovieWriterError>

    private var buffByFrame = [Int: BuffInfoResult]()

    /// Create or replace a movie.
    /// - Parameters:
    ///   - url: the location of the movie
    ///   - width: the width of the movie in pixels
    ///   - height: the height of the movie in pixels
    public init(outpath url: URL, width: Int, height: Int) throws {
        outPath = url

        // Always start fresh.
        try? FileManager.default.removeItem(at: url)

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let compressionSettings = [AVVideoAverageBitRateKey: Int(30e6)]
        let inputParams: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionSettings,
        ]

        writerInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: inputParams)
        if writer.canAdd(writerInput) {
            writer.add(writerInput)
        } else {
            throw DMCMovieWriterError.initError(
                msg: "Can't add AVAssetWriterInput")
        }
        adapter = getAdapter(writerInput: writerInput)

        writer.startWriting()
        writer.startSession(atSourceTime: CMTime.zero)
    }

    /// Add a frame to the movie.
    ///
    /// Frames are written asynchronously.   This method buffers the provided frame, which will be written to the
    /// movie's `outpath` when possible.
    ///
    /// - Parameters:
    ///   - image: the content of the new frame
    ///   - seconds: how long to "play" the new frame
    public func addFrame(
        _ image: NSImage, duration seconds: Double = 1.0 / 30.0
    ) throws {
        let thisFrame = currFrame
        currFrame += 1
        prepareQ.async(group: prepareGroup) {
            autoreleasepool {
                let result: BuffInfoResult
                if seconds <= 0.0 {
                    result = .failure(
                        DMCMovieWriterError.addFrameError(
                            msg: "Duration (\(seconds)) must be > 0.0"))
                } else if let pixelBuff = createPixelBuff(from: image) {
                    result = .success(
                        BuffInfo(buffer: pixelBuff, duration: seconds))
                } else {
                    result = .failure(
                        DMCMovieWriterError.addFrameError(
                            msg:
                                "Could not create pixel buff for frame \(thisFrame)"
                        ))
                }
                self.storeQ.async(group: self.prepareGroup) {
                    self.buffByFrame[thisFrame] = result
                }
            }
        }

        // Drain the result dictionary once it starts eating too much memory.
        let highWater = 20
        if buffByFrame.count >= highWater {
            try drain(lowWater: 10)
        }
    }

    /// Synchronously flush buffered frames.
    ///
    /// You can call this method to reduce the memory consumed by a ``DMCMovieWriter``.
    ///
    /// - Parameter lowWater: stop writing when the number of unwritten frames is &le; this value
    public func drain(lowWater: Int = 0) throws {
        prepareGroup.wait()
        let numToWrite = max(0, buffByFrame.count - lowWater)
        if numToWrite <= 0 {
            return
        }
        let keys = buffByFrame.keys.sorted()
        for k in keys[0..<numToWrite] {
            let result = self.buffByFrame.removeValue(forKey: k)!
            switch result {
            case .success(let buffInfo):
                try awaitWriterReady()
                try writeFrameBuffer(k, buffInfo: buffInfo)

            case .failure(let error):
                throw error
            }
        }
    }

    private func awaitWriterReady() throws {
        var retriesRemaining = 5
        while !writerInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 1.0)
            retriesRemaining -= 1
            if retriesRemaining <= 0 {
                throw DMCMovieWriterError.writeTimeout(
                    msg:
                        "Writer input is still not ready after too many retries."
                )
            }
        }
    }

    private func writeFrameBuffer(_ frameID: Int, buffInfo: BuffInfo) throws {
        let presTime = CMTimeMakeWithSeconds(
            currTime, preferredTimescale: 1_000_000)
        if !self.adapter.append(buffInfo.buffer, withPresentationTime: presTime)
        {
            throw DMCMovieWriterError.addFrameError(
                msg: "Failed to append frame \(frameID)")
        }
        currTime += buffInfo.duration
    }

    /// Flush all buffered frames and finish writing the movie.
    ///
    /// Once this method is called, no more frames can be added to the movie.
    public func finish() throws {
        let sema = DispatchSemaphore(value: 0)
        try drain()
        writerInput.markAsFinished()
        writer.finishWriting {
            sema.signal()
        }
        sema.wait()
    }
}

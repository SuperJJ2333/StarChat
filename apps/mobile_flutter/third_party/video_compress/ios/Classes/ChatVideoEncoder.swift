import AVFoundation
import AudioToolbox
import CoreMedia

/// Explicit H.264/AAC settings shared with Android. Export presets alone do not
/// expose bitrate or audio settings, so bounded chat encoding uses Reader/Writer.
final class ChatVideoEncoder {
    private let queue = DispatchQueue(label: "video_compress.chat_encoder")
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var inputs: [AVAssetWriterInput] = []
    private var finishedInputs = Set<ObjectIdentifier>()
    private var completed = false
    private var outputURL: URL?
    private var completion: ((URL?) -> Void)?

    func cancel() {
        queue.async { self.finish(nil) }
    }

    func start(path: String, args: [String: Any], progress: @escaping (Double) -> Void,
               completion: @escaping (URL?) -> Void) {
        self.completion = completion
        queue.async {
            do {
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                guard let track = asset.tracks(withMediaType: .video).first,
                      let bitrate = args["videoBitrate"] as? Int,
                      let dimension = args["maxDimension"] as? Int,
                      bitrate > 0, dimension >= 2 else { self.finish(nil); return }
                let fps = max(1, args["frameRate"] as? Int ?? 24)
                let bounds = CGRect(origin: .zero, size: track.naturalSize)
                    .applying(track.preferredTransform)
                guard bounds.width.isFinite, bounds.height.isFinite,
                      abs(bounds.width) > 0, abs(bounds.height) > 0 else {
                    self.finish(nil); return
                }
                let scale = min(1, CGFloat(dimension) / max(abs(bounds.width), abs(bounds.height)))
                let size = CGSize(width: max(2, floor(abs(bounds.width) * scale / 2) * 2),
                                  height: max(2, floor(abs(bounds.height) * scale / 2) * 2))
                let composition = AVMutableVideoComposition()
                composition.renderSize = size
                composition.frameDuration = CMTime(value: 1, timescale: Int32(fps))
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                let transform = track.preferredTransform
                    .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                    .concatenating(CGAffineTransform(scaleX: size.width / abs(bounds.width),
                                                   y: size.height / abs(bounds.height)))
                layer.setTransform(transform, at: .zero)
                instruction.layerInstructions = [layer]
                composition.instructions = [instruction]

                let reader = try AVAssetReader(asset: asset)
                let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
                    videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
                videoOutput.videoComposition = composition
                videoOutput.alwaysCopiesSampleData = false
                guard reader.canAdd(videoOutput) else { self.finish(nil); return }
                reader.add(videoOutput)
                let url = URL(fileURLWithPath: Utility.basePath())
                    .appendingPathComponent("chat-\(UUID().uuidString).mp4")
                self.outputURL = url
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                writer.shouldOptimizeForNetworkUse = true
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitrate,
                        AVVideoExpectedSourceFrameRateKey: fps,
                        AVVideoMaxKeyFrameIntervalKey: fps * 3,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
                    ]
                ])
                videoInput.expectsMediaDataInRealTime = false
                guard writer.canAdd(videoInput) else { self.finish(nil); return }
                writer.add(videoInput)
                var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]
                if args["includeAudio"] as? Bool != false,
                   let audioTrack = asset.tracks(withMediaType: .audio).first {
                    let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM
                    ])
                    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVEncoderBitRateKey: args["audioBitrate"] as? Int ?? 64000,
                        AVSampleRateKey: args["audioSampleRate"] as? Int ?? 44100,
                        AVNumberOfChannelsKey: args["audioChannels"] as? Int ?? 1
                    ])
                    audioInput.expectsMediaDataInRealTime = false
                    guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else {
                        self.finish(nil); return
                    }
                    reader.add(audioOutput)
                    writer.add(audioInput)
                    pairs.append((audioOutput, audioInput))
                }
                self.inputs = pairs.map { $0.1 }
                self.reader = reader
                self.writer = writer
                guard writer.startWriting(), reader.startReading() else { self.finish(nil); return }
                writer.startSession(atSourceTime: .zero)
                for (output, input) in pairs {
                    var ended = false
                    input.requestMediaDataWhenReady(on: self.queue) { [weak self, weak input, weak output] in
                        guard let self = self, let input = input, let output = output else { return }
                        if ended || self.completed { return }
                        while input.isReadyForMoreMediaData {
                            guard let sample = output.copyNextSampleBuffer() else {
                                if self.reader?.status == .failed || self.reader?.status == .cancelled {
                                    self.finish(nil); return
                                }
                                ended = true
                                self.completeInput(input)
                                return
                            }
                            if !input.append(sample) {
                                ended = true
                                self.completeInput(input)
                                self.finish(nil)
                                return
                            }
                            if input.mediaType == .video && asset.duration.seconds > 0 {
                                let value = CMSampleBufferGetPresentationTimeStamp(sample).seconds / asset.duration.seconds
                                DispatchQueue.main.async { progress(min(100, max(0, value * 100))) }
                            }
                        }
                    }
                }

            } catch { self.finish(nil) }
        }
    }

    private func completeInput(_ input: AVAssetWriterInput) {
        guard finishedInputs.insert(ObjectIdentifier(input)).inserted else { return }
        guard let writer = writer, writer.status == .writing else { finish(nil); return }
        input.markAsFinished()
        guard finishedInputs.count == inputs.count else { return }
        guard reader?.status == .completed else { finish(nil); return }
        writer.finishWriting { [weak self, weak writer] in
            guard let self = self else { return }
            self.queue.async {
                self.finish(writer?.status == .completed ? self.outputURL : nil)
            }
        }
    }

    private func finish(_ result: URL?) {
        guard !completed else { return }
        completed = true
        if writer?.status == .writing {
            for input in inputs where !finishedInputs.contains(ObjectIdentifier(input)) {
                input.markAsFinished()
            }
        }
        inputs.removeAll()
        if result == nil {
            if reader?.status == .reading { reader?.cancelReading() }
            if writer?.status == .writing { writer?.cancelWriting() }
            if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        }
        reader = nil
        writer = nil
        let callback = completion
        completion = nil
        DispatchQueue.main.async { callback?(result) }
    }
}

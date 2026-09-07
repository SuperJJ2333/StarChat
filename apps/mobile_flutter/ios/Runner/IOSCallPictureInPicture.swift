import AVFoundation
import AVKit
import Flutter
import UIKit
import WebRTC
import flutter_webrtc

// The system owns the cross-app window. This renders only the already-decrypted
// remote RTCVideoTrack; no media or keys cross the native method channel.
final class IOSCallPictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
  var onRestore: (() -> Void)?
  private var controller: AVPictureInPictureController?
  private var content: AVPictureInPictureVideoCallViewController?
  private var renderer: IOSCallVideoRenderer?
  private var track: RTCVideoTrack?
  private weak var sourceView: UIView?
  private var boundStreamId: String?
  private var boundOwnerTag: String?

  func setVideo(streamId: String?, ownerTag: String?) -> Bool {
    if streamId != nil, streamId == boundStreamId, ownerTag == boundOwnerTag, track != nil { return true }
    clear()
    guard AVPictureInPictureController.isPictureInPictureSupported(),
          let streamId = streamId, !streamId.isEmpty,
          let ownerTag = ownerTag, !ownerTag.isEmpty,
          let plugin = FlutterWebRTCPlugin.sharedSingleton(),
          plugin.peerConnections?[ownerTag] != nil, plugin.localStreams?[streamId] == nil,
          let stream = plugin.stream(forId: streamId, peerConnectionId: ownerTag),
          let track = stream.videoTracks.first,
          let source = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow })?.rootViewController?.view else { return false }
    let content = AVPictureInPictureVideoCallViewController()
    content.preferredContentSize = CGSize(width: 360, height: 640)
    let renderer = IOSCallVideoRenderer(frame: content.view.bounds)
    renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    content.view.backgroundColor = .black
    content.view.addSubview(renderer)
    track.add(renderer)
    self.boundStreamId = streamId
    self.boundOwnerTag = ownerTag
    self.track = track
    self.renderer = renderer
    self.content = content
    self.sourceView = source
    let sourceContent = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: source, contentViewController: content)
    let controller = AVPictureInPictureController(contentSource: sourceContent)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    self.controller = controller
    // The app targets iOS16+, which avoids the earlier separately provisioned
    // camera entitlement. Hardware/runtime support is still checked explicitly.
    if #available(iOS 16.0, *), let session = plugin.videoCapturer?.captureSession,
       session.isMultitaskingCameraAccessSupported {
      session.beginConfiguration()
      session.isMultitaskingCameraAccessEnabled = true
      session.commitConfiguration()
    }
    return true
  }

  func start() -> Bool {
    guard track != nil, let controller = controller, controller.isPictureInPicturePossible else { return false }
    controller.startPictureInPicture()
    return true
  }
  func stop() -> Bool {
    guard let controller = controller else { return false }
    controller.stopPictureInPicture()
    return true
  }
  func clear() {
    controller?.stopPictureInPicture()
    if let track = track, let renderer = renderer { track.remove(renderer) }
    renderer?.stopRendering()
    renderer?.removeFromSuperview()
    boundStreamId = nil; boundOwnerTag = nil
    track = nil; renderer = nil; content = nil; controller = nil; sourceView = nil
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    guard let scene = sourceView?.window?.windowScene else { completionHandler(false); return }
    onRestore?()
    UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil) { _ in }
    completionHandler(true)
  }
}

// AVKit PiP requires sample-buffer rendering. Metal-backed WebRTC views cannot
// continue drawing reliably in the system PiP compositor.
final class IOSCallVideoRenderer: UIView, RTCVideoRenderer {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
  private let frameLock = NSLock()
  private var pendingFrame: RTCVideoFrame?
  private var scheduled = false
  private var stopped = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    displayLayer.videoGravity = .resizeAspect
  }
  required init?(coder: NSCoder) { fatalError("Storyboard initialization is unsupported") }
  func setSize(_ size: CGSize) {}
  func stopRendering() {
    frameLock.lock()
    stopped = true
    pendingFrame = nil
    frameLock.unlock()
    displayLayer.flushAndRemoveImage()
  }
  func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame = frame else { return }
    frameLock.lock()
    guard !stopped else { frameLock.unlock(); return }
    pendingFrame = frame
    let schedule = !scheduled
    scheduled = true
    frameLock.unlock()
    guard schedule else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.frameLock.lock()
      let frame = self.pendingFrame
      self.pendingFrame = nil
      self.scheduled = false
      self.frameLock.unlock()
      if let frame = frame { self.display(frame) }
    }
  }
  private func display(_ frame: RTCVideoFrame) {
    guard let pixelBuffer = pixelBuffer(for: frame) else { return }
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
          let format = format else { return }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
          let sample = sample else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(frame.rotation.rawValue) * .pi / 180))
    if displayLayer.status == .failed { displayLayer.flush() }
    if displayLayer.isReadyForMoreMediaData { displayLayer.enqueue(sample) }
  }
  private func pixelBuffer(for frame: RTCVideoFrame) -> CVPixelBuffer? {
    if let native = frame.buffer as? RTCCVPixelBuffer { return native.pixelBuffer }
    let i420 = frame.buffer.toI420()
    let width = Int(i420.width), height = Int(i420.height)
    var output: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &output) == kCVReturnSuccess,
          let output = output else { return nil }
    CVPixelBufferLockBaseAddress(output, [])
    defer { CVPixelBufferUnlockBaseAddress(output, []) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(output, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(output, 1) else { return nil }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
    for row in 0..<height {
      memcpy(yBase.advanced(by: row * yStride), i420.dataY.advanced(by: row * Int(i420.strideY)), width)
    }
    let uv = uvBase.assumingMemoryBound(to: UInt8.self)
    for row in 0..<((height + 1) / 2) {
      for column in 0..<((width + 1) / 2) {
        uv[row * uvStride + column * 2] = i420.dataU[row * Int(i420.strideU) + column]
        uv[row * uvStride + column * 2 + 1] = i420.dataV[row * Int(i420.strideV) + column]
      }
    }
    return output
  }
}

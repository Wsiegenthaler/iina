//
//  SubSyncTask.swift
//  iina
//
//  Created by Weston Siegenthaler on 10/21/21.
//  Copyright © 2022 lhc. All rights reserved.
//

import Cocoa

fileprivate let subsystem = Logger.Subsystem(rawValue: "subsync-task")

private let PROGRESS_FREQUENCY: Int = 16
private let EXPECTED_SYNC_DURATION: Double = 0.6//3//4//TODO
//private let PROGRESS_WEIGHT_AUDIO_EXTRACTION: Int = 80
//private let PROGRESS_WEIGHT_ALASS_SYNC: Int = 100 - PROGRESS_WEIGHT_AUDIO_EXTRACTION

//TODO
private let AUDIO_EXTRACTION_PROGRESS_WEIGHT: Double = 0.85
private let SUBTITLE_EXTRACTION_PROGRESS_WEIGHT: Double = 0.35


//MARK: SubSyncTask

/** Represents a single app-agnostic subtitle synchronization task */
class SubSyncTask: NSObject {
  
  let videoPath: String
  let inSubFile: URL
  let outSubFile: URL
  let encoding: String?
  var taskHandler: SubSyncTaskHandler?
  var progressHandler: SubSyncProgressHandler?
  private let queue: DispatchQueue
  private var worker: DispatchWorkItem?
  
//TODO
//  let audioPhaseDef = SubSyncCompositeProgress.PhaseDef(key: "audio", weight: PROGRESS_WEIGHT_AUDIO_EXTRACTION)
//  let syncPhaseDef = SubSyncCompositeProgress.PhaseDef(key: "sync", weight: PROGRESS_WEIGHT_ALASS_SYNC)
  
  init(_ videoPath: String, _ inSubFile: URL, _ outSubFile: URL, encoding: String? = nil, taskHandler: SubSyncTaskHandler? = nil, progressHandler: SubSyncProgressHandler? = nil, queue: DispatchQueue? = nil) {
    self.videoPath = videoPath
    self.inSubFile = inSubFile
    self.outSubFile = outSubFile
    self.encoding = encoding
    self.taskHandler = taskHandler
    self.progressHandler = progressHandler
    self.queue = queue ?? DispatchQueue.main
  }

  // Syncs subtitle file using either the embedded subtitle stream or audio stream (fallback) as reference
  func sync() {
    
    if worker != nil {
      Logger.log("SubSync task has already been started", level: .warning, subsystem: subsystem)
      return
    }
    
    self.taskHandler?.handle(.starting)

    worker = DispatchWorkItem {
      
      // Check support for subtitle format early to avoid unnecessary work
      if let error = self.unsupportedSubError() {
        self.taskHandler?.handle(.finished(.error(error)))
        return
      }

      // Create extractor
      guard let extractor = SubSyncExtractor(self.videoPath) else {
        Logger.log("SubSync error: unable to create extractor (video='\(self.videoPath)')", level: .error, subsystem: subsystem)
        self.taskHandler?.handle(.finished(.error(.internalError)))
        return
      }

      let audioStream = SubSyncExtractor.selectBestAudioStream(extractor.getAudioStreams())
      let subStream = SubSyncExtractor.selectBestSubtitleStream(extractor.getSubtitleStreams())

      if let stream = subStream ?? audioStream {
        self.syncStreamHelper(stream, extractor)
      } else {
        Logger.log("SubSync error: unable to find suitable reference stream (video='\(self.videoPath)')", level: .error, subsystem: subsystem)
        self.taskHandler?.handle(.finished(.error(.noReferenceStream)))
      }
    }
    
    queue.async(execute: worker!)
  }
  
  // Syncs subtitle file using an embedded subtitle stream as reference
  func syncSubtitleStream() {
    if worker != nil {
      Logger.log("SubSync task has already been started", level: .warning, subsystem: subsystem)
      return
    }
    
    self.taskHandler?.handle(.starting)

    worker = DispatchWorkItem {
      
      // Check support for subtitle format early to avoid unnecessary work
      if let error = self.unsupportedSubError() {
        self.taskHandler?.handle(.finished(.error(error)))
        return
      }

      // Create extractor
      guard let extractor = SubSyncExtractor(self.videoPath) else {
        Logger.log("SubSync error: unable to create extractor (video='\(self.videoPath)')", level: .error, subsystem: subsystem)
        self.taskHandler?.handle(.finished(.error(.internalError)))
        return
      }

      // Select first embedded subtitle stream in video
      guard let stream = SubSyncExtractor.selectBestSubtitleStream(extractor.getSubtitleStreams()) else {
        Logger.log("SubSync error: no subtitle stream (video='\(self.videoPath)')", level: .error, subsystem: subsystem)
        self.taskHandler?.handle(.finished(.error(.internalError)))
        return
      }
      
      self.syncStreamHelper(stream, extractor)
    }
    
    queue.async(execute: worker!)
  }
  
  // Syncs subtitle file using an audio stream as reference
  func syncAudioStream() {
    if worker != nil {
      Logger.log("SubSync task has already been started", level: .warning, subsystem: subsystem)
      return
    }
    
    self.taskHandler?.handle(.starting)

    worker = DispatchWorkItem {
      
      // Check support for subtitle format early to avoid unnecessary work
      if let error = self.unsupportedSubError() {
        self.taskHandler?.handle(.finished(.error(error)))
        return
      }

      // Create extractor
      guard let extractor = SubSyncExtractor(self.videoPath) else {
        Logger.log("SubSync error: unable to create extractor (video='\(self.videoPath)')", level: .error, subsystem: subsystem)
        self.taskHandler?.handle(.finished(.error(.internalError)))
        return
      }

      // Select audio stream with the least channels
      guard let stream = SubSyncExtractor.selectBestAudioStream(extractor.getAudioStreams()) else {
        Logger.log("SubSync error: no audio stream (video='\(self.videoPath)')", level: .error, subsystem: subsystem)
        self.taskHandler?.handle(.finished(.error(.internalError)))
        return
      }
      
      self.syncStreamHelper(stream, extractor)
    }
    
    queue.async(execute: worker!)
  }
  
  // Common logic for syncing with a single audio or subtitle stream as reference
  private func syncStreamHelper(_ stream: AVStream, _ extractor: SubSyncExtractor) {
    
    // Get video framerate
    guard let fps = extractor.getFramerate() else {
      Logger.log("SubSync error: cant determine video framerate (video='\(self.videoPath)')", level: .error, subsystem: subsystem)
      self.taskHandler?.handle(.finished(.error(.internalError)))
      return
    }
    
    // Setup progress handler
    let progress = self.setupProgressHandler()
    
    self.taskHandler?.handle(.started)

    switch self.getSpans(stream, extractor, progress) {
      case .success(let spans):
        defer { alass_timespans_free(spans) }
      
        // Computing timespans from audio is expensive, cache them for future use
        SubSyncCache.put(self.videoPath, stream, spans)
        
        let syncResult = self.alassSync(spans, fps, progress)
        switch syncResult {
          case .success, .error: self.taskHandler?.handle(.finished(syncResult))
          case .cancelled: break
        }
      
      case .error: self.taskHandler?.handle(.finished(.error(.internalError)))
      case .cancelled: break
    }
    self.worker = nil
  }
  
  private func getSpans(_ stream: AVStream, _ extractor: SubSyncExtractor, _ progress: SubSyncPhasedProgress) -> SubSyncExtractionResult<AlassSpans> {
    // Check cache for precomputed reference timespans
    if let spans = SubSyncCache.get(self.videoPath, stream) {
      return .success(spans)
    }

    let mediaType = SubSyncExtractor.getMediaType(stream)
    switch mediaType {
      case AVMEDIA_TYPE_SUBTITLE:
        // Compute spans from subtitle track
        return extractor.extractSubtitles(stream, AlassSpanHandler(), progress.next(SUBTITLE_EXTRACTION_PROGRESS_WEIGHT), self.isCancelled)
      case AVMEDIA_TYPE_AUDIO:
        // Compute spans from audio
        let sampleRate = alass_expected_sample_rate()
        return extractor.extractAudio(stream, AlassSampleHandler(), progress.next(AUDIO_EXTRACTION_PROGRESS_WEIGHT), self.isCancelled, sampleRate: sampleRate)
      default:
        let type = SubSyncExtractor.getAVMediaTypeStr(mediaType)
        Logger.log("SubSync error: reference stream must be of type AVMEDIA_TYPE_AUDIO or AVMEDIA_TYPE_SUBTITLE (stream.index=\(stream.index), stream.type=\(type), video='\(self.videoPath)')", level: .error, subsystem: subsystem)
        return .error
    }
  }

  private func alassSync(_ spans: OpaquePointer?, _ fps: Framerate, _ progress: SubSyncPhasedProgress) -> SubSyncResult {
    measure("Synchronize subtitle file") {
      
      // Simulate progress based on expected duration
      let simulatedProgress = SubSyncSimulatedProgress(progress.last(), EXPECTED_SYNC_DURATION, frequency: PROGRESS_FREQUENCY)
      simulatedProgress.start()
      
      // Synchronize subtitle file with reference spans
      let rc = alass_sync(inSubFile.path, outSubFile.path, spans, fps, encoding, nil)

      simulatedProgress.finish()
      
      if isCancelled() {
        return .cancelled //TODO make sure not to emit cancelled msg as a result of this
      } else if rc == ALASS_SUCCESS {
        return .success(inSubFile: inSubFile, outSubFile: outSubFile)
      } else if rc == ALASS_UNSUPPORTED_FORMAT {
        return .error(.unsupportedSub)
      } else {
        return .error(.internalError)
      }
    }
  }
  
  // Check support for subtitle format
  private func unsupportedSubError() -> SubSyncError? {
    let inSubPath = self.inSubFile.path
    let rc = alass_format_is_supported(inSubPath)
    if rc != ALASS_SUCCESS {
      if rc == ALASS_UNSUPPORTED_FORMAT {
        Logger.log("SubSync error: aborting early due to unsupported subtitle format (file='\(inSubPath)')", level: .error, subsystem: subsystem)
        return .unsupportedSub
      } else {
        Logger.log("SubSync error: unable to verify support for subtitle format (code=\(rc), file='\(inSubPath)')", level: .error, subsystem: subsystem)
        return .internalError
      }
    }
    return nil
  }
  
  private func setupProgressHandler() -> SubSyncPhasedProgress {
    let progressCoupler = SubSyncProgressCoupler({ [weak self] in self?.progressHandler })
    let progressThrottle = SubSyncThrottleProgress(progressCoupler, frequency: PROGRESS_FREQUENCY)
    return SubSyncPhasedProgress(progressThrottle)
  }
  
  /** Cancels this worker if it is in progress */
  func cancel() {
    if worker != nil {
      worker?.cancel()
      self.taskHandler?.handle(.finished(.cancelled))
    }
  }
  
  /** Determines whether this worker was user cancelled */
  private func isCancelled() -> Bool {
    worker?.isCancelled ?? true
  }
  
  fileprivate func measure<R>(_ msg: String, _ block: () -> R) -> R {
    let start = DispatchTime.now().uptimeNanoseconds / 1_000_000
    let result = block()
    let elapsed = DispatchTime.now().uptimeNanoseconds / 1_000_000 - start
    Logger.log("\(msg) (result=\(result), elapsed=\(elapsed)ms)", subsystem: subsystem)
    return result
  }
}

//MARK: SubSyncHandler

protocol SubSyncHandler: AnyObject {}

//MARK: SubSyncTaskHandler

protocol SubSyncTaskHandler: SubSyncHandler {
  func handle(_ status: SubSyncTaskStatus)
}

//MARK: SubSyncTaskStatus

enum SubSyncTaskStatus {
  case starting
  case started
  case finished(SubSyncResult)
}

//MARK: SubSyncResult

enum SubSyncResult {
  case success(inSubFile: URL, outSubFile: URL)
  case error(SubSyncError)
  case cancelled
}

//MARK: SubSyncError

enum SubSyncError {
  case videoError
  case unsupportedSub
  case noReferenceStream
  case internalError
}

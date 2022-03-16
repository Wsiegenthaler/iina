//
//  SubSyncExtractor.swift
//  iina
//
//  Created by Weston Siegenthaler on 10/21/21.
//  Copyright © 2022 lhc. All rights reserved.
//

import Cocoa

fileprivate let subsystem = Logger.Subsystem(rawValue: "subsync-extractor")

private let AUDIO_PACKETS_PER_PROGRESS_EVENT = 2400
private let AUDIO_PACKETS_PER_CANCEL_CHECK = 1600
private let SUBTITLE_PACKETS_PER_PROGRESS_EVENT = 5
private let SUBTITLE_PACKETS_PER_CANCEL_CHECK = 10

typealias Framerate = Double
typealias IsCancelled = () -> Bool
typealias AlassSpans = OpaquePointer
typealias ExtractorSpan = (Int64, Int64)


//MARK: SubSyncExtractionResult

// The result of an extraction operation
enum SubSyncExtractionResult<R> {
  case success(_ result: R)
  case error
  case cancelled
}

//MARK: SubSyncExtractionHandler

// Accepts extraction values and produces a result
protocol SubSyncExtractionHandler {
  associatedtype Input
  associatedtype Result

  func handle(_ input: Input) -> Bool
  func finish() -> Result
}

//MARK: SubSyncExtractor

// Extracts various data streams from video file using ffmpeg
class SubSyncExtractor: NSObject {
  
  internal let AVERROR_EOF = -541478725
  internal let AVERROR_EAGAIN = -EAGAIN
  
  let videoPath: String

  internal var formatCtxPtr = UnsafeMutablePointer<AVFormatContext>(nil)
  internal var formatCtx: AVFormatContext { return (formatCtxPtr?.pointee)! }
  
  init?(_ videoPath: String) {
    // Register all formats and codecs (should have already been called)
    //av_register_all()
    
    self.videoPath = videoPath

    // Open video and obtain AVFormatContext
    var rc = avformat_open_input(&formatCtxPtr, videoPath, nil, nil)
    if rc != 0 {
      Logger.log("Cannot open video (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
      return nil
    }
    
    // Retrieve stream information
    rc = avformat_find_stream_info(formatCtxPtr, nil)
    if (rc != 0) {
      Logger.log("Could not find stream information (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
      return nil
    }
  }
  
  deinit {
    avformat_close_input(&formatCtxPtr)
  }
  
  func getStreams() -> [AVStream] {
    (0..<Int(formatCtx.nb_streams))
      .compactMap({ formatCtx.streams.advanced(by: $0).pointee?.pointee })
  }
  
  func getStreams(type: AVMediaType) -> [AVStream] {
    getStreams().filter({ Self.getMediaType($0) == type })
  }
  
  func getDuration(_ timeBase: AVRational) -> Double {
    Double(formatCtx.duration) * (Double(timeBase.den) / Double(timeBase.num)) / Double(AV_TIME_BASE)
  }
  
  // Determine the framerate by inspecting first video stream
  func getFramerate() -> Framerate? {
    getStreams(type: AVMEDIA_TYPE_VIDEO)
      .map({ av_q2d($0.r_frame_rate) })
      .first(where: { !$0.isNaN })
  }
  
  static func getMediaType(_ stream: AVStream) -> AVMediaType {
    return getCodecParams(stream).codec_type
  }
  
  fileprivate func seekToFrame(_ stream: AVStream, _ frame: Int64) -> Bool {
    avformat_seek_file(formatCtxPtr, stream.index, frame, frame, frame, AVSEEK_FLAG_FRAME) == 0
  }
  
  fileprivate static func getCodecParams(_ stream: AVStream) -> AVCodecParameters {
    return (stream.codecpar?.pointee)!
  }
  
  static func getAVErrorStr(_ errCode: Int32) -> String {
    let buf = UnsafeMutablePointer<Int8>.allocate(capacity: Int(AV_ERROR_MAX_STRING_SIZE))
    defer { free(buf) }
    return String(cString: av_make_error_string(buf, Int(AV_ERROR_MAX_STRING_SIZE), errCode))
  }
  
  static func getAVMediaTypeStr(_ type: AVMediaType) -> String {
    String(cString: av_get_media_type_string(type))
  }
}

fileprivate func measure<R>(_ msg: String, _ block: () -> R) -> R {
  let start = DispatchTime.now().uptimeNanoseconds / 1_000_000
  let result = block()
  let elapsed = DispatchTime.now().uptimeNanoseconds / 1_000_000 - start
  Logger.log("\(msg) (result=\(result), elapsed=\(elapsed)ms)", subsystem: subsystem)
  return result
}

//MARK: Subtitle Span Extraction

/**
 Extracts embedded subtitle timing information from video file
 */
extension SubSyncExtractor {
    
  func extractSubtitles<H: SubSyncExtractionHandler>(_ stream: AVStream, _ handler: H, _ progress: SubSyncProgressHandler, _ isCancelled: IsCancelled)
    -> SubSyncExtractionResult<H.Result> where H.Input == ExtractorSpan {
    
    measure("Subtitle extraction task") {
      progress.handle(0.0)

      // Ensure stream is correct media type
      if Self.getMediaType(stream) != AVMEDIA_TYPE_SUBTITLE {
        Logger.log("Cannot extract subtitles from stream which is not AVMEDIA_TYPE_SUBTITLE (stream.index=\(stream.index), video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
      
      // Seek to the beginning of the stream
      if !seekToFrame(stream, 0) {
        Logger.log("Unable to seek to beginning of stream (video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
        
      //MARK: Find and prepare codec

      let codecId = Self.getCodecParams(stream).codec_id
      guard let codecPtr: UnsafeMutablePointer<AVCodec> = avcodec_find_decoder(codecId) else {
        Logger.log("Unable to find suitable codec (video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
      let codec: AVCodec = codecPtr.pointee

      //MARK: Prepare AVCodecContext

      guard let codecCtxPtr = avcodec_alloc_context3(codecPtr) else {
       Logger.log("Unable to create AVCodecContext (video='\(videoPath)')", level: .error, subsystem: subsystem)
       return .error
      }
      let codecCtx = codecCtxPtr.pointee
      defer {
       var ctxPtr: UnsafeMutablePointer<AVCodecContext>? = codecCtxPtr
       avcodec_free_context(&ctxPtr)
      }
      
      // Initialize AVCodecContext with AVCodecParameters
      var rc = avcodec_parameters_to_context(codecCtxPtr, stream.codecpar)
      if (rc != 0) {
       Logger.log("Unable to initialize AVCodecContext with AVCodecParameters (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
       return .error
      }
      
      // Initialize AVCodecContext with AVCodec
      rc = avcodec_open2(codecCtxPtr, codecPtr, nil)
      if (rc != 0) {
       Logger.log("Unable to initialize AVCodecContext with AVCodec (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
       return .error
      }
      
      //MARK: Create AVPacket
      
      var packetPtr = av_packet_alloc()
      guard packetPtr != nil else {
        Logger.log("Unable to allocate AVPacket for subtitle extraction (video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
      defer { av_packet_free(&packetPtr) }
      
      //MARK: Begin subtitle extraction
      
      let streamDuration = getDuration(stream.time_base)
      let millisFactor = Double(stream.time_base.num) / Double(stream.time_base.den) * 1000
      var packetCnt = 0
      
      repeat {
        
        // Check for cancellation
        if packetCnt % SUBTITLE_PACKETS_PER_CANCEL_CHECK == 0 {
          if isCancelled() { return .cancelled }
        }

        // Read from stream
        rc = av_read_frame(formatCtxPtr, packetPtr)
        
        // Clear packet each iteration
        defer {
          av_packet_unref(packetPtr)
        }

        if rc == 0 {

          // Only process packets belonging to the target audio stream
          if (stream.index == packetPtr!.pointee.stream_index) {
            
            //MARK: Report progress

            if packetCnt % SUBTITLE_PACKETS_PER_PROGRESS_EVENT == 0 {
              progress.handle(SubSyncProgress(packetPtr!.pointee.pts) / streamDuration)
            }
            packetCnt += 1

            //MARK: Extract subtitle and compute span timing
            
            let subtitlePtr = UnsafeMutablePointer<AVSubtitle>.allocate(capacity: 1)
            defer { av_free(subtitlePtr) }
            var gotSubPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            defer { gotSubPtr.deallocate() }
            
            let capDelay = codecPtr.pointee.capabilities & AV_CODEC_CAP_DELAY
            
            // Decode subtitle
            let rc = avcodec_decode_subtitle2(codecCtxPtr, subtitlePtr, gotSubPtr, packetPtr)
            if rc >= 0 && gotSubPtr.pointee > 0 {
              let subtitle = subtitlePtr.pointee
              
              // Compute start and end of span
              let start = Int64(Double(packetPtr!.pointee.pts + Int64(subtitle.start_display_time)) * millisFactor)
              let end = Int64(Double(packetPtr!.pointee.pts + Int64(subtitle.end_display_time) + packetPtr!.pointee.duration) * millisFactor)
              let span = (start, end)
              
              //MARK: Vend subtitle span

              if !handler.handle(span) {
                Logger.log("An unknown error occurred while processing subtitle spans (video='\(videoPath)')", level: .error, subsystem: subsystem)
                return .error
              }
            }
          }
        } else if rc != AVERROR_EOF {
          Logger.log("Error reading frame from decoder (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
          return .error
        }
      } while rc == 0
      
      //MARK: Final actions
      
      let result = handler.finish()
      progress.handle(1)
      
      return .success(result)
    }
  }
  
  func getSubtitleStreams() -> [AVStream] {
    getStreams(type: AVMEDIA_TYPE_SUBTITLE)
  }
  
  // Selects the first available subtitle stream
  static func selectBestSubtitleStream(_ streams: [AVStream]) -> AVStream? {
    streams
      .filter({ getMediaType($0) == AVMEDIA_TYPE_SUBTITLE })
      .first
  }

}

//MARK: Audio Extraction

/**
 Extracts and resamples an audio stream from a video file. Samples produced are
 8kHz 16-bit signed little-endian mono by default.
 */
extension SubSyncExtractor {
  
  func extractAudio<H: SubSyncExtractionHandler>(_ stream: AVStream, _ handler: H, _ progress: SubSyncProgressHandler, _ isCancelled: IsCancelled, sampleRate: Int32, channelCount: Int = 1, channelLayout: Int32 = AV_CH_LAYOUT_MONO, sampleFormat: AVSampleFormat = AV_SAMPLE_FMT_S16P)
    -> SubSyncExtractionResult<H.Result> where H.Input == SubSyncSamples {
    
    measure("Audio extraction task") {
      progress.handle(0.0)

      // Ensure stream is correct media type
      if Self.getMediaType(stream) != AVMEDIA_TYPE_AUDIO {
        Logger.log("Cannot extract audio from stream which is not AVMEDIA_TYPE_AUDIO (stream.index=\(stream.index), video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
      
      // Seek to the beginning of the stream
      if !seekToFrame(stream, 0) {
        Logger.log("Unable to seek to beginning of stream (video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }

      //MARK: Find and prepare codec

      let codecId = Self.getCodecParams(stream).codec_id
      guard let codecPtr: UnsafeMutablePointer<AVCodec> = avcodec_find_decoder(codecId) else {
        Logger.log("Unable to find suitable codec (video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
      let codec: AVCodec = codecPtr.pointee

      //MARK: Prepare AVCodecContext
      
      guard let codecCtxPtr = avcodec_alloc_context3(codecPtr) else {
        Logger.log("Unable to create AVCodecContext (video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
      let codecCtx = codecCtxPtr.pointee
      defer {
        var ctxPtr: UnsafeMutablePointer<AVCodecContext>? = codecCtxPtr
        avcodec_free_context(&ctxPtr)
      }
      
      // Initialize AVCodecContext with AVCodecParameters
      var rc = avcodec_parameters_to_context(codecCtxPtr, stream.codecpar)
      if (rc != 0) {
        Logger.log("Unable to initialize AVCodecContext with AVCodecParameters (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }

      // Initialize AVCodecContext with AVCodec
      rc = avcodec_open2(codecCtxPtr, codecPtr, nil)
      if (rc != 0) {
        Logger.log("Unable to initialize AVCodecContext with AVCodec (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
      
      //MARK: Build resampler

      var swrCtxPtr = swr_alloc()
      guard swrCtxPtr != nil else {
        Logger.log("Unable to allocate SwrContext (video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
      let swrCtx = UnsafeMutableRawPointer(swrCtxPtr)
      defer { swr_free(&swrCtxPtr) }

      //MARK: Configure resampler

      // SOXR Resampler offers slightly better performance
      av_opt_set_int(swrCtx, "resampler", Int64(SWR_ENGINE_SOXR.rawValue), 0)

      // Configure input
      let inChannelCnt = Int64(codecCtxPtr.pointee.channels)
      let inChannelLayout = Int64(codecCtxPtr.pointee.channel_layout)
      let inSampleRate = Int64(codecCtxPtr.pointee.sample_rate)
      let inSampleFmt = codecCtxPtr.pointee.sample_fmt
      av_opt_set_int(swrCtx, "in_channel_count", inChannelCnt, 0)
      av_opt_set_int(swrCtx, "in_channel_layout", inChannelLayout, 0)
      av_opt_set_int(swrCtx, "in_sample_rate", inSampleRate, 0)
      av_opt_set_sample_fmt(swrCtx, "in_sample_fmt", inSampleFmt, 0)

      // Configure output
      av_opt_set_int(swrCtx, "out_channel_count", Int64(channelCount), 0)
      av_opt_set_int(swrCtx, "out_channel_layout", Int64(channelLayout), 0)
      av_opt_set_int(swrCtx, "out_sample_rate", Int64(sampleRate), 0)
      av_opt_set_sample_fmt(swrCtx, "out_sample_fmt", sampleFormat, 0)

      // Log config
      let inParamStr = Self.resampleParamStr(Int(inSampleRate), inSampleFmt, Int32(inChannelCnt), UInt64(inChannelLayout))
      Logger.log("Resampler input => \(inParamStr)", level: .debug, subsystem: subsystem)
      let outParamStr = Self.resampleParamStr(Int(sampleRate), sampleFormat, Int32(channelCount), UInt64(channelLayout))
      Logger.log("Resampler output => \(outParamStr)", level: .debug, subsystem: subsystem)

      //MARK: Initialize resampler
      
      rc = swr_init(swrCtxPtr)
      if rc != 0 {
        Logger.log("Unable to properly initialize SwrContext (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }

      //MARK: Create AVPacket
      
      var packetPtr = av_packet_alloc()
      guard packetPtr != nil else {
        Logger.log("Unable to allocate AVPacket for resampling (video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
      defer { av_packet_free(&packetPtr) }

      //MARK: Create AVFrame
      
      var framePtr = av_frame_alloc()
      guard framePtr != nil else {
        Logger.log("Unable to allocate AVFrame for resampling (video='\(videoPath)')", level: .error, subsystem: subsystem)
        return .error
      }
      defer { av_frame_free(&framePtr) }

      //MARK: Begin resampling

      // Create reference for output buffer
      var buffer: UnsafeMutablePointer<UInt8>? = nil
      var bufferLen: Int32 = 0
      var bufferSampleLen: Int32 = 0
      defer { if var b = buffer { av_freep(&b) } }

      let streamDuration = getDuration(stream.time_base)
      let bytesPerSample = av_get_bytes_per_sample(sampleFormat)
      
      var packetCnt = 0
      
      repeat {

        // Check for cancellation
        if packetCnt % AUDIO_PACKETS_PER_CANCEL_CHECK == 0 {
          if isCancelled() { return .cancelled }
        }

        // Read from stream
        rc = av_read_frame(formatCtxPtr, packetPtr)
        
        // Clear frame and packet each iteration
        defer {
          av_frame_unref(framePtr)
          av_packet_unref(packetPtr)
        }

        if rc == 0 {

          // Only process packets belonging to the target audio stream
          if (stream.index == packetPtr!.pointee.stream_index) {
            
            //MARK: Report progress

            if packetCnt % AUDIO_PACKETS_PER_PROGRESS_EVENT == 0 {
              progress.handle(SubSyncProgress(packetPtr!.pointee.pts) / streamDuration)
            }
            packetCnt += 1
            
            //MARK: Send packet data to decoder
            
            let rc = avcodec_send_packet(codecCtxPtr, packetPtr)
            if (rc != 0) {
              Logger.log("Unable to send raw packet data as input to the decoder (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
              return .error
            }

            repeat {

              //MARK: Recieve frame data from decoder
              
              let rc = avcodec_receive_frame(codecCtxPtr, framePtr)
              if (rc == AVERROR_EAGAIN) {
                  break // Frame data not ready, try again...
              } else if (rc != 0) {
                Logger.log("Unable to receive frame from decoder (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
                return .error
              }

              //MARK: Prepare output buffer
              
              // Retrieve max anticipated sample count
              let expectedSampleCnt = swr_get_out_samples(swrCtxPtr, framePtr!.pointee.nb_samples)

              // Allocate or resize buffer if necessary
              if (buffer == nil || bufferSampleLen < expectedSampleCnt) {
                // Release existing buffer
                if (buffer != nil) { av_free(buffer!) }
                
                // Allocate buffer, asking for 4x the expected to minimize reallocations
                bufferLen = av_samples_alloc(&buffer, nil, Int32(channelCount), 4 * expectedSampleCnt, sampleFormat, 0)
                if (bufferLen <= 0) {
                  Logger.log("Unable to allocate sample buffer (code=\(bufferLen), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
                  return .error
                }
                
                // Precompute sample capacity so it's not recomputed each frame
                bufferSampleLen = bufferLen / bytesPerSample
              }
              
              //MARK: Resample

              // Cast frame buffer to UnsafeMutablePointer<UnsafePointer<UInt8>?> as expected by `swr_convert`
              let _frameDataPtr = withUnsafeMutablePointer(to: &(framePtr!.pointee.data)){$0}
              let frameDataPtr = _frameDataPtr.withMemoryRebound(to: Optional<UnsafePointer<UInt8>>.self, capacity: MemoryLayout<UnsafePointer<UInt8>>.stride * Int(AV_NUM_DATA_POINTERS)){$0}
              
              // Call resampler
              let sampleCnt = swr_convert(swrCtxPtr, &buffer, bufferLen, frameDataPtr, framePtr!.pointee.nb_samples)

              //MARK: Vend resampled data
              
              if sampleCnt > 0 {
                let samples = SubSyncSamples(data: buffer!, count: sampleCnt, byteCount: sampleCnt * bytesPerSample)
                if !handler.handle(samples) {
                  Logger.log("An unknown error occurred while processing audio samples (video='\(videoPath)')", level: .error, subsystem: subsystem)
                  return .error
                }
              }
            } while (true)

          }
        } else if rc != AVERROR_EOF {
          Logger.log("Error reading frame from decoder (code=\(rc), msg='\(Self.getAVErrorStr(rc))', video='\(videoPath)')", level: .error, subsystem: subsystem)
          return .error
        }
      } while rc == 0
          
      //MARK: Final actions
      
      let result = handler.finish()
      progress.handle(1)
      
      return .success(result)
    }
  }
  
  func getAudioStreams() -> [AVStream] {
    getStreams(type: AVMEDIA_TYPE_AUDIO)
  }
  
  // Find audio stream with the least number of channels
  static func selectBestAudioStream(_ streams: [AVStream]) -> AVStream? {
    streams
      .filter({ getMediaType($0) == AVMEDIA_TYPE_AUDIO })
      .reduce(nil, { ($0 == nil || getChannelCount($0!) > getChannelCount($1)) ? $1 : $0! })
  }
  
  private static func getChannelCount(_ stream: AVStream) -> Int {
    return Int(getCodecParams(stream).channels)
  }
  
  private static func getSampleFormatStr(_ fmt: AVSampleFormat) -> String {
    return fmt == AV_SAMPLE_FMT_NONE ? "none" : String(cString: av_get_sample_fmt_name(fmt)!)
  }

  private static func getChannelLayoutStr(_ channelCount: Int32, _ channelLayout: UInt64) -> String {
    let bufferLen = 128
    let buf = UnsafeMutablePointer<Int8>.allocate(capacity: bufferLen)
    defer { free(buf) }
    av_get_channel_layout_string(buf, Int32(bufferLen), channelCount, channelLayout)
    return String(cString: buf)
  }

  private static func resampleParamStr(_ sampleRate: Int, _ sampleFormat: AVSampleFormat, _ channelCount: Int32, _ channelLayout: UInt64) -> String {
    let sampleFmtStr = getSampleFormatStr(sampleFormat)
    let channelLayoutStr = getChannelLayoutStr(channelCount, channelLayout)
    return "sampleRate=\(sampleRate), sampleFormat=\(sampleFmtStr), channels=\(channelCount), channelLayout=\(channelLayoutStr)"
  }
}

//MARK: AlassSpanHandler

// Generates libalass `Spans` object to be used as reference for syncing
class AlassSpanHandler: SubSyncExtractionHandler {
  typealias Input = ExtractorSpan
  typealias Result = AlassSpans
  
  let spans: AlassSpans = alass_timespans_new()
    
  func handle(_ span: ExtractorSpan) -> Bool {
    alass_timespans_push(spans, span.0, span.1) == ALASS_SUCCESS
  }
  
  func finish() -> AlassSpans {
    spans
  }
}

//MARK: SubSyncSamples

// A chunk of samples resulting from audio extraction
struct SubSyncSamples {
  let data: UnsafeMutablePointer<UInt8>
  let count: Int32
  let byteCount: Int32
}

//MARK: AlassSampleHandler

// Writes audio samples to libalass `Sink` for processing
class AlassSampleHandler: SubSyncExtractionHandler {
    
  typealias Input = SubSyncSamples
  typealias Result = AlassSpans
  
  let sink = alass_audio_sink_new()
    
  func handle(_ input: SubSyncSamples) -> Bool {
    if sink == nil { return false }
    
    let rc = alass_audio_sink_send(sink, input.data, Int64(input.count))
    if rc != ALASS_SUCCESS {
      Logger.log("SubSync error (op=alass_send_samples rc=\(rc))", level: .error, subsystem: subsystem)
      return false
    }
    return true
  }
  
  func finish() -> AlassSpans {
    let activity = alass_voice_activity_compute(sink)
    defer { alass_voice_activity_free(activity) }
    return alass_timespans_compute(activity)
  }
  
  deinit { alass_audio_sink_free(sink) }
}

//MARK: SampleFileWriter

// Writes audio samples to an output file for inspection (useful for debugging)
private class SampleFileWriter : AlassSampleHandler {
  var file: FileHandle?
  
  init?(filename: String) {
    if FileManager().createFile(atPath: filename, contents: nil) {
      file = FileHandle(forWritingAtPath: filename)
    }
    
    if (file == nil) {
      Logger.log("Unable to create output file (file=\(filename))")
      return nil
    }
    
    super.init()
  }
  
  override func handle(_ input: SubSyncSamples) -> Bool {
    if file != nil {
      file?.write(Data(UnsafeBufferPointer(start: input.data, count: Int(input.byteCount))))
      return super.handle(input)
    } else {
      return false
    }
  }
  
  override func finish() -> AlassSpans {
    file?.closeFile()
    return super.finish()
  }
}

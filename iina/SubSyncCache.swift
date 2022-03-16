//
//  SubSyncCache.swift
//  iina
//
//  Created by Weston Siegenthaler on 10/21/21.
//  Copyright © 2022 lhc. All rights reserved.
//

import Cocoa

fileprivate let subsystem = Logger.Subsystem(rawValue: "subsync-cache")

//MARK: SubSyncCache

/** Simple file based cache for computed timespans */
class SubSyncCache {

  typealias CacheKey = String
  
  static private let cacheUrl = Utility.subSyncCacheURL
  
  // Bump this when changes to the on-disk cache format aren't backwards compatible
  private static let CACHE_VERSION = 1

  static func key(_ videoPath: String, _ stream: AVStream) -> CacheKey {
    hash("video-\(hash(videoPath))/stream-\(stream.id)/version-\(CACHE_VERSION)")
  }
  
  static func put(_ videoPath: String, _ stream: AVStream, _ spans: OpaquePointer) {
    put(key(videoPath, stream), spans)
  }

  static func get(_ videoPath: String, _ stream: AVStream) -> OpaquePointer? {
    get(key(videoPath, stream))
  }

  static func put(_ key: CacheKey, _ spans: OpaquePointer) {
    alass_timespans_save_raw(spans, filePath(key))
  }
  
  static func get(_ key: CacheKey) -> OpaquePointer? {
    alass_timespans_load_raw(filePath(key))
  }
  
  static private func filePath(_ key: CacheKey) -> String {
    URL(fileURLWithPath: "\(key).spans", relativeTo: cacheUrl).path
  }
  
  static private func hash(_ s: String) -> String {
    s.md5.lowercased()
  }
}

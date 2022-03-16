//
//  SubSyncController.swift
//  iina
//
//  Created by Weston Siegenthaler on 10/21/21.
//  Copyright © 2022 lhc. All rights reserved.
//

import Cocoa

fileprivate let subsystem = Logger.Subsystem(rawValue: "subsync-controller")


//MARK: SubSyncController

/**
 IINA-aware  controller meant as a player-attached singleton. Allows
 callers to start and cancel synchronization tasks and vends state/progress
 information to any registered handlers. Also provides application integration
 functionality such as:
  - automaticly loads synced subs into player
  - notifies observers of the the currently selected subtitle track's eligibility for syncing
  - switches to already synced tracks upon reselection of original
  - provides OSD messaging
 */
class SubSyncController: NSObject {
  
  private var player: PlayerCore!
  private var queue: DispatchQueue!
  private var task: SubSyncTask?
  private var proxy: ProxyHandler!
  private var syncedMap: [String : SyncedSub] = [:]
  private var observers: [NSObjectProtocol] = []
  
  // Represents subtitles which have either been the input of a sync operation, or the result
  private enum SyncedSub { case syncInput(outputPath: String), syncOutput }
  
  init(player: PlayerCore, queue: DispatchQueue) {
    super.init()
    self.player = player
    self.queue = queue
    self.proxy = ProxyHandler(self, player)
        
    // Determine whether current subtitle is eligible to be synced
    observePlayer(.iinaSIDChanged) { _  in self.proxy.emitCurrentSubTrack() }

    // Clear map of synced subs that have already been either the input or output of syncing
    observePlayer(.iinaFileLoaded) { _ in self.syncedMap.removeAll() }
  }
  
  func sync() {
    if task != nil {
      Logger.log("SubSync should only execute one SubSyncTask at a time", level: .warning, subsystem: subsystem)
      return
    }
    
    guard let videoPath = player.mpv.getString(MPVProperty.path) else {
      Logger.log("SubSync can't obtain video path from mpv", level: .warning, subsystem: subsystem)
      sendOSD(OSDMessage.subSyncError)
      return
    }

    guard let subTrack = currentTrack() else {
      Logger.log("SubSync can't obtain subtitle track from player", level: .warning, subsystem: subsystem)
      sendOSD(OSDMessage.subSyncError)
      return
    }

    if subTrack.externalFilename == nil {
      Logger.log("SubSync can't obtain external filename for subtitles", level: .warning, subsystem: subsystem)
      sendOSD(OSDMessage.subSyncError)
      return
    }
    let inSubFile = URL(fileURLWithPath: subTrack.externalFilename!)
    
    let encoding = Preference.string(for: .defaultEncoding)

    // If this sub has already been synced just switch to existing track
    if let syncedEntry = syncedMap[inSubFile.path] {
      switch syncedEntry {
        case .syncInput(let outputPath):
          if let syncedTrack = player.info.subTracks.first(where: { outputPath == $0.externalFilename ?? "" }) {
            player.setTrack(syncedTrack.id, forType: .sub)
          }
        case .syncOutput: break
      }
      return
    }

    // Determine paths
    let prefixStr = NSLocalizedString("sub_sync.sub_out_prefix", comment: "SYNC")
    let outSubFile = SubSyncController.tmpSubPath(inSubFile, prefix: prefixStr)

    // Start task
    task = SubSyncTask(videoPath, inSubFile, outSubFile, encoding: encoding, taskHandler: proxy, progressHandler: proxy, queue: queue)
    task?.sync()
  }
  
  func cancel() {
    task?.cancel()
    
    // Stop propagation of handler events
    task?.taskHandler = nil
    task?.progressHandler = nil
    
    task = nil
  }
  
  func syncOrCancel() {
    task == nil ? sync() : cancel()
  }

  func addHandler(_ handler: SubSyncHandler, useMainQueue: Bool = true) {
    if let handler = handler as? SubSyncControllerHandler {
      // Notify handler of currently selected subtitle track
      self.proxy.emitCurrentSubTrack(onlyTo: handler)
      
      self.proxy.ctrlHandlers.append((handler, useMainQueue))
    }

    if let handler = handler as? SubSyncTaskHandler {
      // Notify handler if operation is pending
      if task != nil { handler.handle(.started) }
      
      self.proxy.taskHandlers.append((handler, useMainQueue))
    }
    
    if let handler = handler as? SubSyncProgressHandler {
      self.proxy.progressHandlers.append((handler, useMainQueue))
    }
  }

  func removeHandler(_ handler: SubSyncHandler) {
      if let handler = handler as? SubSyncControllerHandler {
        self.proxy.ctrlHandlers.removeAll { $0.0 === handler }
      }
      
      if let handler = handler as? SubSyncTaskHandler {
        self.proxy.taskHandlers.removeAll { $0.0 === handler }
      }
      
      if let handler = handler as? SubSyncProgressHandler {
        self.proxy.progressHandlers.removeAll { $0.0 === handler }
      }
    }

  // Determines whether the given subtitle track can by synced. Does not check whether the
  // subtitle file format is supported, only that it is an external file and hasn't yet
  // been synced.
  private func canSync(_ track: MPVTrack?) -> Bool {
    // Workaround for issue where the subtitle track id is loaded from watch_later
    // cache at startup but player hasn't yet had a chance to populate subTracks.
    // In this case the computed 'canSync' value may be eroneously false.
    if track == nil && player.info.sid != nil && player.info.sid! > 0 && player.info.subTracks.count == 0 {
      return true
    }
    
    // Only external subs can by synced
    if !(track?.isExternal ?? false) { return false }
    
    // Only tracks that haven't been the input or output of a previous operation can by synced, but
    // we treat those which have already been an input as if they can. If the user tries to sync
    // such tracks again we simply select it's corresponding output track.
    if let entry = syncedMap[track?.externalFilename ?? ""] {
      switch entry {
        case .syncOutput: return false
        case .syncInput: return true
      }
    }
    return true
  }
  
  private func currentTrack() -> MPVTrack? {
    player.info.sid == nil ? nil : player.info.subTracks[at: player.info.sid!-1]
  }
  
  private func observePlayer(_ name: Notification.Name, block: @escaping (Notification) -> Void) {
    let observer = NotificationCenter.default.addObserver(forName: name, object: player, queue: .main, using: block)
    observers.append(observer)
  }
  
  private func sendOSD(_ msg: OSDMessage, delay: Bool = false) {
    if delay {
      DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.35) { self.player.sendOSD(msg) }
    } else {
      self.player.sendOSD(msg)
    }
  }
  
  private static func tmpSubPath(_ subUrl: URL, prefix: String? = nil) -> URL {
    let prefixStr = prefix == nil ? "" : "[\(prefix!)] "
    let subFilename = prefixStr + subUrl.lastPathComponent
    return URL(fileURLWithPath: subFilename, relativeTo: Utility.tempDirURL)
  }
  
  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }
  
  // This handler responds to SubSyncTask and SubSyncProgress events to proxy events to any
  // handlers registered by the application and also performs controller related duties.
  private class ProxyHandler: SubSyncTaskHandler, SubSyncProgressHandler {
    
    let ctrl: SubSyncController
    let player: PlayerCore
    
    var ctrlHandlers: [(SubSyncControllerHandler, Bool)] = []
    var taskHandlers: [(SubSyncTaskHandler, Bool)] = []
    var progressHandlers: [(SubSyncProgressHandler, Bool)] = []
    
    init(_ ctrl: SubSyncController, _ player: PlayerCore) {
      self.ctrl = ctrl
      self.player = player
    }
    
    // Respond to lifetime events from the task
    func handle(_ status: SubSyncTaskStatus) {
      
      // SubSyncTaskStatus events execute on the SubSyncTask queue but must be handled on main
      DispatchQueue.main.async(execute: {
        let ctrl = self.ctrl
        let player = self.player
        
        switch status {

          case .started:
            // Show in-progress OSD once we've started
            let subTitle = ctrl.currentTrack()?.readableTitle ?? ""
            player.sendOSD(.subSyncProgress, autoHide: false, accessoryView: SubSyncOSDViewController(ctrl, subTitle).view)

          case .finished(let result):
            switch result {
              case .success(let inSubFile, let outSubFile):
                ctrl.task = nil

                // Clear user-specified delay
                player.setSubDelay(0.0)
                
                // Load sub into player
                player.loadExternalSubFile(outSubFile)

                // Mark both input and output tracks as having been synced
                ctrl.syncedMap[outSubFile.path] = .syncOutput
                ctrl.syncedMap[inSubFile.path] = .syncInput(outputPath: outSubFile.path)

              case .error(let reason):
                ctrl.task = nil
                switch reason {
                  case .internalError: ctrl.sendOSD(OSDMessage.subSyncError, delay: true)
                  case .unsupportedSub: ctrl.sendOSD(OSDMessage.unsupportedSub, delay: true)
                  default: ctrl.sendOSD(OSDMessage.subSyncError, delay: true)
                }
              
              case .cancelled:
                self.ctrl.sendOSD(OSDMessage.canceled, delay: true)
            }
          
          default: break
        }
      })
      
      // Pass along all task status events to handlers
      emitTaskStatus(status)
    }
        
    // Respond to progress events from the task
    func handle(_ progress: SubSyncProgress) {
      emitProgress(progress)
    }
    
    // Emit task status event to all registered handlers
    func emitTaskStatus(_ status: SubSyncTaskStatus) {
      for (h, useMainQueue) in taskHandlers {
        if useMainQueue && !Thread.isMainThread {
          DispatchQueue.main.async(execute: { h.handle(status) })
        } else {
          h.handle(status)
        }
      }
    }

    // Emit controller event to all registered SubSyncControllerHandlers
    func emitControllerEvent(_ event: SubSyncPlayerEvent) {
      for (h, useMainQueue) in ctrlHandlers {
        if useMainQueue && !Thread.isMainThread {
          DispatchQueue.main.async(execute: { h.handle(event) })
        } else {
          h.handle(event)
        }
      }
    }
    
    // Emit progress event to all registered handlers
    func emitProgress(_ progress: SubSyncProgress) {
      for (h, useMainQueue) in progressHandlers {
        if useMainQueue && !Thread.isMainThread {
          DispatchQueue.main.async(execute: { h.handle(progress) })
        } else {
          h.handle(progress)
        }
      }
    }
    
    // Emit controller event to all registered handlers
    func emitCurrentSubTrack(onlyTo handler: SubSyncControllerHandler? = nil) {
      let track = ctrl.currentTrack()
      let canSync = ctrl.canSync(track)
      let event: SubSyncPlayerEvent = .currentSubTrack(track: track, canSync: canSync)
      if handler != nil {
        handler?.handle(event)
      } else {
        self.emitControllerEvent(.currentSubTrack(track: track, canSync: canSync))
      }
    }
  }
}

//MARK: SubSyncControllerHandler

protocol SubSyncControllerHandler: SubSyncHandler {
  func handle(_ event: SubSyncPlayerEvent)
}

//MARK: SubSyncControllerEvent

enum SubSyncPlayerEvent {
  case currentSubTrack(track: MPVTrack?, canSync: Bool)
}

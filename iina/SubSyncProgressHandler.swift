//
//  SubSyncProgressHandler.swift
//  iina
//
//  Created by Weston Siegenthaler on 11/13/21.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

/** A floating point value between 0 and 1 representing the completion of an operation */
typealias SubSyncProgress = Double

//MARK: SubSyncProgressHandler

/** Handles progress information reported from the decoding/resampling process */
protocol SubSyncProgressHandler: SubSyncHandler {
  func handle(_ value: SubSyncProgress) -> Void
}

//MARK: SubSyncLogProgress

/** Writes progress information to console */
class SubSyncLogProgress : SubSyncProgressHandler {
  private let label: String
  private let format: String
  private let level: Logger.Level
  private let subsystem: Logger.Subsystem

  init(_ label: String, format: String = "%.1f", level: Logger.Level = .debug, subsystem: Logger.Subsystem = .general) {
    self.label = label
    self.format = format
    self.level = level
    self.subsystem = subsystem
  }
      
  func handle(_ value: SubSyncProgress) -> Void {
    Logger.log("\(label) \(String(format: format, value * 100))%", level: level, subsystem: subsystem)
  }
}

//MARK: SubSyncThrottleProgress

/** Throttles progress information so it's only processed once per increment */
class SubSyncThrottleProgress: SubSyncProgressHandler {
  private let output: SubSyncProgressHandler
  private let interval: Double
  private var lastProgress: Double = 0.0

  init(_ output: SubSyncProgressHandler, frequency: Int) {
    self.output = output
    self.interval = 1.0 / Double(frequency)
  }
      
  func handle(_ value: SubSyncProgress) -> Void {
      let now = Date().timeIntervalSince1970
      let elapsed = now - self.lastProgress
      if elapsed >= self.interval {
        DispatchQueue.main.async {

        self.output.handle(value)
        self.lastProgress = now
        }
      }
    }
}

//MARK: SubSyncProgressCoupler

/**
 Passes progress information to output handler if one exists. This is used to stop
 progress information from propagating when the task's handler is unset.
 */
class SubSyncProgressCoupler: SubSyncProgressHandler {
  typealias HandlerGetter = () -> SubSyncProgressHandler?
  
  private let out: HandlerGetter
  
  init(_ out: @escaping HandlerGetter) {
    self.out = out
  }
  
  func handle(_ value: SubSyncProgress) {
    out()?.handle(value)
  }
}

//MARK: SubSyncSimulatedProgress

/** Simulated progress based on the expected time to complete a task */
class SubSyncSimulatedProgress {
  private let output: SubSyncProgressHandler
  private let taskDuration: Double
  private let interval: Double
  private let waitAt: SubSyncProgress
  private var startedAt: Double = 0
  private var finished = false

  init(_ output: SubSyncProgressHandler, _ taskDuration: Double, frequency: Int, waitAt: SubSyncProgress = 0.925) {
    self.output = output
    self.taskDuration = max(taskDuration, 0.0001)
    self.waitAt = waitAt
    self.interval = 1.0 / Double(frequency)
  }

  private lazy var timer: DispatchSourceTimer = {
      let t = DispatchSource.makeTimerSource()
      t.schedule(deadline: .now() + interval, repeating: interval)
      t.setEventHandler(handler: { [weak self] in self?.fire() })
      return t
  }()

  func start() -> Void {
    if startedAt == 0.0 && !finished {
      timer.resume()
      startedAt = now()
    }
  }

  func finish() -> Void {
    if startedAt != 0.0 && !finished {
      finished = true
      output.handle(1.0)
      timer.cancel()
    }
  }

  private func fire() -> Void {
    let progress = min((now() - startedAt) / taskDuration, 1.0)
    let scaled = SubSyncProgress(progress) * waitAt
    output.handle(scaled)
  }

  private func now() -> Double {
    Date().timeIntervalSince1970
  }
}

//MARK: SubSyncCompositeProgress

/** Combines the progress information of multiple sequential operations into a single logical operation */
//TODO deprecate?
class SubSyncCompositeProgress {
  private let output: SubSyncProgressHandler
  var handlers: [PhaseDef: SubSyncProgressHandler] = [:]

  init(_ output: SubSyncProgressHandler, _ phases: PhaseDef...) {
    self.output = output
    
    var curStart = 0
    let totalWeight = SubSyncProgress(phases.map({ s in s.weight }).reduce(0, +))
    
    for p in phases {
      let start = SubSyncProgress(curStart) / totalWeight
      let range = SubSyncProgress(p.weight) / totalWeight
      handlers[p] = PhaseHandler(output, start, range)
      curStart += p.weight
    }
  }
  
  struct PhaseDef: Hashable {
    let key: String
    let weight: Int
    
    init(key: String, weight: Int) {
      self.key = key
      self.weight = weight
    }
  }
  
  private class PhaseHandler: SubSyncProgressHandler {
    let output: SubSyncProgressHandler
    let start: SubSyncProgress
    let range: SubSyncProgress
    
    init(_ output: SubSyncProgressHandler, _ start: SubSyncProgress, _ range: SubSyncProgress) {
      self.output = output
      self.start = start
      self.range = range
    }
    
    func handle(_ value: SubSyncProgress) {
      output.handle(start + value * range)
    }
  }
}

//MARK: SubSyncPhasedProgress

/** Combines the progress information of multiple sequential operations into a single logical operation */
class SubSyncPhasedProgress: SubSyncProgressHandler {
  
  let output: SubSyncProgressHandler
  var checkpoint: SubSyncProgress = 0.0
  var current: SubSyncProgress = 0.0
  var shareOfRemaining: SubSyncProgress = 1.0
  
  init(_ output: SubSyncProgressHandler) {
    self.output = output
  }
  
  func handle(_ value: SubSyncProgress) {
    DispatchQueue.main.async {
      self.current = self.checkpoint + (value * (self.shareOfRemaining - self.checkpoint))
      self.output.handle(self.current)
    }
  }
  
  // Advances to the next phase, leaving `shareOfRemaining` remainder for subsequent phases
  func next(_ shareOfRemaining: SubSyncProgress) -> Self {
    checkpoint = current
    self.shareOfRemaining = shareOfRemaining
    return self
  }
  
  // Advances to the last phase, expecting for overall progress to reach 1.0 with the completion of this phase
  func last() -> Self {
    next(1.0)
  }
}

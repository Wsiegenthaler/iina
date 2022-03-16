//
//  SubSyncOSDViewController.swift
//  iina
//
//  Created by Weston Siegenthaler on 12/7/21.
//  Copyright © 2022 lhc. All rights reserved.
//

import Foundation

class SubSyncOSDViewController: NSViewController, SubSyncTaskHandler, SubSyncProgressHandler {

  @IBOutlet weak var progressBar: NSProgressIndicator!
  @IBOutlet weak var cancelBtn: NSButton!
  @IBOutlet weak var subTrackLabel: NSTextField!

  private let subSync: SubSyncController
  private let subTrackName: String

  init(_ subSync: SubSyncController, _ subTrackName: String) {
    self.subSync = subSync
    self.subTrackName = subTrackName
    super.init(nibName: nil, bundle: nil)
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    let labelFontSize = CGFloat(Preference.float(for: .osdTextSize) * 0.6)
    subTrackLabel.font = NSFont.monospacedDigitSystemFont(ofSize: labelFontSize, weight: .regular)
    subTrackLabel.stringValue = subTrackName
    
    progressBar.doubleValue = 0
    progressBar.maxValue = 1
    
    subSync.addHandler(self)
  }
  
  @IBAction func cancelBtnAction(_ sender: Any) {
    subSync.cancel()
  }
  
  func handle(_ status: SubSyncTaskStatus) {
    switch status {
      case .finished:
        subSync.removeHandler(self)
        PlayerCore.active.hideOSD()
      default: break
    }
  }
  
  func handle(_ value: SubSyncProgress) {
    progressBar.doubleValue = value
  }
}

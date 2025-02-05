//
//  QuickSettingViewController.swift
//  iina
//
//  Created by lhc on 12/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

fileprivate extension QuickSettingViewController.TabViewType {
  init(buttonTag: Int) {
    self = [.video, .audio, .sub][at: buttonTag] ?? .video
  }
}

@available(OSX 10.14, *)
fileprivate extension NSColor {
  static let sidebarTabTint: NSColor = NSColor(named: .sidebarTabTint)!
  static let sidebarTabTintActive: NSColor = NSColor(named: .sidebarTabTintActive)!
}

class QuickSettingViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, SidebarViewController {

  override var nibName: NSNib.Name {
    return NSNib.Name("QuickSettingViewController")
  }

  let sliderSteps = 24.0

  /**
   Similar to the one in `PlaylistViewController`.
   Since IBOutlet is `nil` when the view is not loaded at first time,
   use this variable to cache which tab it need to switch to when the
   view is ready. The value will be handled after loaded.
   */
  private var pendingSwitchRequest: TabViewType?

  /** Tab type. Use TrackType for now. Probably not a good choice. */
  typealias TabViewType = MPVTrack.TrackType

  weak var player: PlayerCore!

  weak var mainWindow: MainWindowController! {
    didSet {
      self.player = mainWindow.player
    }
  }

  var currentTab: TabViewType = .video

  var observers: [NSObjectProtocol] = []


  @IBOutlet weak var videoTabBtn: NSButton!
  @IBOutlet weak var audioTabBtn: NSButton!
  @IBOutlet weak var subTabBtn: NSButton!
  @IBOutlet weak var tabView: NSTabView!

  @IBOutlet weak var buttonTopConstraint: NSLayoutConstraint!

  @IBOutlet weak var videoTableView: NSTableView!
  @IBOutlet weak var audioTableView: NSTableView!
  @IBOutlet weak var subTableView: NSTableView!
  @IBOutlet weak var secSubTableView: NSTableView!

  @IBOutlet weak var rotateSegment: NSSegmentedControl!

  @IBOutlet weak var aspectSegment: NSSegmentedControl!
  @IBOutlet weak var customAspectTextField: NSTextField!

  @IBOutlet weak var cropSegment: NSSegmentedControl!

  @IBOutlet weak var speedSlider: NSSlider!
  @IBOutlet weak var speedSliderIndicator: NSTextField!
  @IBOutlet weak var speedSliderConstraint: NSLayoutConstraint!
  @IBOutlet weak var customSpeedTextField: NSTextField!
  @IBOutlet weak var switchHorizontalLine: NSBox!
  @IBOutlet weak var hardwareDecodingSwitch: Switch!
  @IBOutlet weak var deinterlaceSwitch: Switch!

  @IBOutlet weak var brightnessSlider: NSSlider!
  @IBOutlet weak var contrastSlider: NSSlider!
  @IBOutlet weak var saturationSlider: NSSlider!
  @IBOutlet weak var gammaSlider: NSSlider!
  @IBOutlet weak var hueSlider: NSSlider!

  @IBOutlet weak var audioDelaySlider: NSSlider!
  @IBOutlet weak var audioDelaySliderIndicator: NSTextField!
  @IBOutlet weak var audioDelaySliderConstraint: NSLayoutConstraint!
  @IBOutlet weak var customAudioDelayTextField: NSTextField!


  @IBOutlet weak var subLoadSementedControl: NSSegmentedControl!
  @IBOutlet weak var subDelaySlider: NSSlider!
  @IBOutlet weak var subDelaySliderIndicator: NSTextField!
  @IBOutlet weak var subDelaySliderConstraint: NSLayoutConstraint!
  @IBOutlet weak var customSubDelayTextField: NSTextField!

  @IBOutlet weak var audioEqSlider1: NSSlider!
  @IBOutlet weak var audioEqSlider2: NSSlider!
  @IBOutlet weak var audioEqSlider3: NSSlider!
  @IBOutlet weak var audioEqSlider4: NSSlider!
  @IBOutlet weak var audioEqSlider5: NSSlider!
  @IBOutlet weak var audioEqSlider6: NSSlider!
  @IBOutlet weak var audioEqSlider7: NSSlider!
  @IBOutlet weak var audioEqSlider8: NSSlider!
  @IBOutlet weak var audioEqSlider9: NSSlider!
  @IBOutlet weak var audioEqSlider10: NSSlider!

  @IBOutlet weak var subSyncBtn: NSButton!
  @IBOutlet weak var subSyncProgress: NSProgressIndicator!
  @IBOutlet weak var subSyncCancelBtn: NSButton!

  @IBOutlet weak var subScaleSlider: NSSlider!
  @IBOutlet weak var subScaleResetBtn: NSButton!
  @IBOutlet weak var subPosSlider: NSSlider!

  @IBOutlet weak var subTextColorWell: NSColorWell!
  @IBOutlet weak var subTextSizePopUp: NSPopUpButton!
  @IBOutlet weak var subTextBorderColorWell: NSColorWell!
  @IBOutlet weak var subTextBorderWidthPopUp: NSPopUpButton!
  @IBOutlet weak var subTextBgColorWell: NSColorWell!
  @IBOutlet weak var subTextFontBtn: NSButton!

  var downShift: CGFloat = 0 {
    didSet {
      buttonTopConstraint.constant = downShift
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    withAllTableViews { (view, _) in
      view.delegate = self
      view.dataSource = self
      view.superview?.superview?.layer?.cornerRadius = 4
    }

    // colors
    if #available(macOS 10.14, *) {
      withAllTableViews { tableView, _ in tableView.backgroundColor = NSColor(named: .sidebarTableBackground)! }
    }

    if pendingSwitchRequest == nil {
      updateTabActiveStatus(withCurrentButton: videoTabBtn)
    } else {
      switchToTab(pendingSwitchRequest!)
      pendingSwitchRequest = nil
    }

    subLoadSementedControl.image(forSegment: 1)?.isTemplate = true
    switchHorizontalLine.wantsLayer = true
    switchHorizontalLine.layer?.opacity = 0.5

    func observe(_ name: Notification.Name, block: @escaping (Notification) -> Void) {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main, using: block))
    }

    // notifications
    observe(.iinaTracklistChanged) { _ in
      self.withAllTableViews { view, _ in view.reloadData() }
    }
    observe(.iinaVIDChanged) { _ in self.videoTableView.reloadData() }
    observe(.iinaAIDChanged) { _ in self.audioTableView.reloadData() }
    observe(.iinaSIDChanged) { _ in
      self.subTableView.reloadData()
      self.secSubTableView.reloadData()
    }
    
    // subsync
    player.subSync.addHandler(QuickSettingViewSubSyncHandler(self))
  }

  // MARK: - Validate UI

  /** Do synchronization*/
  override func viewDidAppear() {
    // image sub
    super.viewDidAppear()
    updateControlsState()
  }

  deinit {
    observers.forEach {
      NotificationCenter.default.removeObserver($0)
    }
  }

  private func updateControlsState() {
    updateVideoTabControl()
    updateAudioTabControl()
    updateSubTabControl()
    updateVideoEqState()
    updateAudioEqState()
  }

  private func updateVideoTabControl() {
    if let index = AppData.aspectsInPanel.firstIndex(of: player.info.unsureAspect) {
      aspectSegment.selectedSegment = index
    } else {
      aspectSegment.selectedSegment = -1
    }
    if let index = AppData.cropsInPanel.firstIndex(of: player.info.unsureCrop) {
      cropSegment.selectedSegment = index
    } else {
      cropSegment.selectedSegment = -1
    }
    rotateSegment.selectSegment(withTag: AppData.rotations.firstIndex(of: player.info.rotation) ?? -1)

    deinterlaceSwitch.checked = player.info.deinterlace
    deinterlaceSwitch.action = {
      self.player.toggleDeinterlace($0)
    }
    hardwareDecodingSwitch.checked = player.info.hwdecEnabled
    hardwareDecodingSwitch.action = {
      self.player.toggleHardwareDecoding($0)
    }

    let speed = player.mpv.getDouble(MPVOption.PlaybackControl.speed)
    customSpeedTextField.doubleValue = speed
    let sliderValue = log(speed / AppData.minSpeed) / log(AppData.maxSpeed / AppData.minSpeed) * sliderSteps
    speedSlider.doubleValue = sliderValue
    redraw(indicator: speedSliderIndicator, constraint: speedSliderConstraint, slider: speedSlider, value: "\(customSpeedTextField.stringValue)x")
  }

  private func updateAudioTabControl() {
    let audioDelay = player.mpv.getDouble(MPVOption.Audio.audioDelay)
    audioDelaySlider.doubleValue = audioDelay
    customAudioDelayTextField.doubleValue = audioDelay
    redraw(indicator: audioDelaySliderIndicator, constraint: audioDelaySliderConstraint, slider: audioDelaySlider, value: "\(customAudioDelayTextField.stringValue)s")
  }

  private func updateSubTabControl() {
    if let currSub = player.info.currentTrack(.sub) {
      subScaleSlider.isEnabled = !currSub.isImageSub
      // FIXME: CollorWells cannot be disable?
      let enableTextSettings = !(currSub.isAssSub || currSub.isImageSub)
      [subTextColorWell, subTextSizePopUp, subTextBgColorWell, subTextBorderColorWell, subTextBorderWidthPopUp, subTextFontBtn].forEach { $0.isEnabled = enableTextSettings }
    }

    let currSubScale = player.mpv.getDouble(MPVOption.Subtitles.subScale).clamped(to: 0.1...10)
    let displaySubScale = Utility.toDisplaySubScale(fromRealSubScale: currSubScale)
    subScaleSlider.doubleValue = displaySubScale + (displaySubScale > 0 ? -1 : 1)
    let subDelay = player.mpv.getDouble(MPVOption.Subtitles.subDelay)
    subDelaySlider.doubleValue = subDelay
    customSubDelayTextField.doubleValue = subDelay
    redraw(indicator: subDelaySliderIndicator, constraint: subDelaySliderConstraint, slider: subDelaySlider, value: "\(customSubDelayTextField.stringValue)s")

    let currSubPos = player.mpv.getInt(MPVOption.Subtitles.subPos)
    subPosSlider.intValue = Int32(currSubPos)

    let fontSize = player.mpv.getInt(MPVOption.Subtitles.subFontSize)
    subTextSizePopUp.selectItem(withTitle: fontSize.description)

    let borderWidth = player.mpv.getDouble(MPVOption.Subtitles.subBorderSize)
    subTextBorderWidthPopUp.selectItem(at: -1)
    subTextBorderWidthPopUp.itemArray.forEach { item in
      if borderWidth == Double(item.title) {
        subTextBorderWidthPopUp.select(item)
      }
    }
  }

  private func updateVideoEqState() {
    brightnessSlider.intValue = Int32(player.info.brightness)
    contrastSlider.intValue = Int32(player.info.contrast)
    saturationSlider.intValue = Int32(player.info.saturation)
    gammaSlider.intValue = Int32(player.info.gamma)
    hueSlider.intValue = Int32(player.info.hue)
  }

  private func updateAudioEqState() {
    if let filters = player.info.audioEqFilters {
      withAllAudioEqSliders { slider in
        if let gain = filters[slider.tag]?.stringFormat.dropLast().split(separator: "=").last {
          slider.doubleValue = Double(gain) ?? 0
        } else {
          slider.doubleValue = 0
        }
      }
    } else {
      withAllAudioEqSliders { $0.doubleValue = 0 }
    }
  }

  func reload() {
    guard isViewLoaded else { return }
    if currentTab == .audio {
      audioTableView.reloadData()
      updateAudioTabControl()
      updateAudioEqState()
    } else if currentTab == .video {
      videoTableView.reloadData()
      updateVideoTabControl()
      updateVideoEqState()
    } else if currentTab == .sub {
      subTableView.reloadData()
      secSubTableView.reloadData()
      updateSubTabControl()
    }
  }

  // MARK: - Switch tab

  /** Switch tab (call from other objects) */
  func pleaseSwitchToTab(_ tab: TabViewType) {
    if isViewLoaded {
      switchToTab(tab)
    } else {
      // cache the request
      pendingSwitchRequest = tab
    }
  }

  /** Switch tab (for internal call) */
  private func switchToTab(_ tab: TabViewType) {
    let button: NSButton
    switch tab {
    case .video:
      button = videoTabBtn
    case .audio:
      button = audioTabBtn
    case .sub:
      button = subTabBtn
    default:
      return
    }
    tabBtnAction(button)
  }

  // MARK: - NSTableView delegate

  func numberOfRows(in tableView: NSTableView) -> Int {
    if tableView == videoTableView {
      return player.info.videoTracks.count + 1
    } else if tableView == audioTableView {
      return player.info.audioTracks.count + 1
    } else if tableView == subTableView || tableView == secSubTableView {
      return player.info.subTracks.count + 1
    } else {
      return 0
    }
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    // get track according to tableview
    // row=0: <None> row=1~: tracks[row-1]
    let track: MPVTrack?
    let activeId: Int
    let columnName = tableColumn?.identifier
    if tableView == videoTableView {
      track = row == 0 ? nil : player.info.videoTracks[at: row-1]
      activeId = player.info.vid!
    } else if tableView == audioTableView {
      track = row == 0 ? nil : player.info.audioTracks[at: row-1]
      activeId = player.info.aid!
    } else if tableView == subTableView {
      track = row == 0 ? nil : player.info.subTracks[at: row-1]
      activeId = player.info.sid!
    } else if tableView == secSubTableView {
      track = row == 0 ? nil : player.info.subTracks[at: row-1]
      activeId = player.info.secondSid!
    } else {
      return nil
    }
    // return track data
    if columnName == .isChosen {
      let isChosen = track == nil ? (activeId == 0) : (track!.id == activeId)
      return isChosen ? Constants.String.dot : ""
    } else if columnName == .trackName {
      return track?.infoString ?? Constants.String.trackNone
    } else if columnName == .trackId {
      return track?.idString
    }
    return nil
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    withAllTableViews { (view, type) in
      if view.numberOfSelectedRows > 0 {
        // note that track ids start from 1
        let subId = view.selectedRow > 0 ? player.info.trackList(type)[view.selectedRow-1].id : 0
        self.player.setTrack(subId, forType: type)
        view.deselectAll(self)
      }
    }
    // Revalidate layout and controls
    updateControlsState()
  }

  private func updateTabActiveStatus(withCurrentButton sender: NSButton) {
    [videoTabBtn, audioTabBtn, subTabBtn].forEach { btn in
      if #available(OSX 10.14, *) {
        btn!.contentTintColor = btn == sender ? .sidebarTabTintActive : .sidebarTabTint
      } else {
        Utility.setBoldTitle(for: btn!, btn == sender)
      }
    }
  }

  private func withAllTableViews(_ block: (NSTableView, MPVTrack.TrackType) -> Void) {
    block(audioTableView, .audio)
    block(subTableView, .sub)
    block(secSubTableView, .secondSub)
    block(videoTableView, .video)
  }

  private func withAllAudioEqSliders(_ block: (NSSlider) -> Void) {
    [audioEqSlider1, audioEqSlider2, audioEqSlider3, audioEqSlider4, audioEqSlider5,
     audioEqSlider6, audioEqSlider7, audioEqSlider8, audioEqSlider9, audioEqSlider10].forEach {
      block($0)
    }
  }

  // MARK: - Actions

  // MARK: Tab buttons

  @IBAction func tabBtnAction(_ sender: NSButton) {
    tabView.selectTabViewItem(at: sender.tag)
    updateTabActiveStatus(withCurrentButton: sender)
    currentTab = .init(buttonTag: sender.tag)
    reload()
  }

  // MARK: Synchronize subtitles
  
  @IBAction func subSyncBtnAction(_ sender: AnyObject) {
    player.subSync.sync()
  }
  
  @IBAction func subSyncCancelBtnAction(_ sender: AnyObject) {
    player.subSync.cancel()
  }
  
  class QuickSettingViewSubSyncHandler: SubSyncTaskHandler, SubSyncControllerHandler {
    
    let ctrl: QuickSettingViewController
        
    init(_ ctrl: QuickSettingViewController) {
      self.ctrl = ctrl
    }
    
    func handle(_ status: SubSyncTaskStatus) {
      switch status {
        
        case .starting:
          subSyncState(inProgress: true)
          ctrl.subSyncProgress.startAnimation(self)

        case .finished:
          subSyncState(inProgress: false)
          ctrl.subSyncProgress.stopAnimation(self)
        
        default: break
      }
    }
    
    func handle(_ event: SubSyncPlayerEvent) {
      switch event {
        case .currentSubTrack(_, let canSync):
          ctrl.subSyncBtn.isEnabled = canSync
      }
    }
    
    private func subSyncState(inProgress: Bool) {
      ctrl.subSyncBtn.isHidden = inProgress
      ctrl.subSyncCancelBtn.isHidden = !inProgress
      ctrl.subSyncProgress.isHidden = !inProgress
    }
  }

  
  // MARK: Video tab

  @IBAction func aspectChangedAction(_ sender: NSSegmentedControl) {
    let aspect = AppData.aspectsInPanel[sender.selectedSegment]
    player.setVideoAspect(aspect)
    player.sendOSD(.aspect(aspect))
  }

  @IBAction func cropChangedAction(_ sender: NSSegmentedControl) {
    let cropStr = AppData.cropsInPanel[sender.selectedSegment]
    player.setCrop(fromString: cropStr)
    player.sendOSD(.crop(cropStr))
  }

  @IBAction func rotationChangedAction(_ sender: NSSegmentedControl) {
    let value = AppData.rotations[sender.selectedSegment]
    player.setVideoRotate(value)
    player.sendOSD(.rotate(value))
  }

  @IBAction func customAspectEditFinishedAction(_ sender: AnyObject?) {
    let value = customAspectTextField.stringValue
    if value != "" {
      aspectSegment.setSelected(false, forSegment: aspectSegment.selectedSegment)
      player.setVideoAspect(value)
      player.sendOSD(.aspect(value))
    }
  }

  private func redraw(indicator: NSTextField, constraint: NSLayoutConstraint, slider: NSSlider, value: String) {
    indicator.stringValue = value
    let offset: CGFloat = 6
    let sliderInnerWidth = slider.frame.width - offset * 2
    constraint.constant = offset + sliderInnerWidth * CGFloat((slider.doubleValue - slider.minValue) / (slider.maxValue - slider.minValue))
    view.layout()
  }

  @IBAction func speedChangedAction(_ sender: NSSlider) {
    // Each step is 64^(1/24)
    //   0       1   ..    7      8      9   ..   24
    // 0.250x 0.297x .. 0.841x 1.000x 1.189x .. 16.00x
    let eventType = NSApp.currentEvent!.type
    if eventType == .leftMouseDown {
      sender.allowsTickMarkValuesOnly = true
    }
    if eventType == .leftMouseUp {
      sender.allowsTickMarkValuesOnly = false
    }
    let sliderValue = sender.doubleValue
    let value = AppData.minSpeed * pow(AppData.maxSpeed / AppData.minSpeed, sliderValue / sliderSteps)
    customSpeedTextField.doubleValue = value
    player.setSpeed(value)
    redraw(indicator: speedSliderIndicator, constraint: speedSliderConstraint, slider: speedSlider, value: "\(customSpeedTextField.stringValue)x")
  }

  @IBAction func customSpeedEditFinishedAction(_ sender: NSTextField) {
    if sender.stringValue.isEmpty {
      sender.stringValue = "1"
    }
    let value = customSpeedTextField.doubleValue
    let sliderValue = log(value / AppData.minSpeed) / log(AppData.maxSpeed / AppData.minSpeed) * sliderSteps
    speedSlider.doubleValue = sliderValue
    if player.info.playSpeed != value {
      player.setSpeed(value)
    }
    redraw(indicator: speedSliderIndicator, constraint: speedSliderConstraint, slider: speedSlider, value: "\(sender.stringValue)x")
    if let window = sender.window {
      window.makeFirstResponder(window.contentView)
    }
  }

  @IBAction func equalizerSliderAction(_ sender: NSSlider) {
    let type: PlayerCore.VideoEqualizerType
    switch sender {
    case brightnessSlider:
      type = .brightness
    case contrastSlider:
      type = .contrast
    case saturationSlider:
      type = .saturation
    case gammaSlider:
      type = .gamma
    case hueSlider:
      type = .hue
    default:
      return
    }
    player.setVideoEqualizer(forOption: type, value: Int(sender.intValue))
  }

  // use tag for buttons
  @IBAction func resetEqualizerBtnAction(_ sender: NSButton) {
    let type: PlayerCore.VideoEqualizerType
    let slider: NSSlider?
    switch sender.tag {
    case 0:
      type = .brightness
      slider = brightnessSlider
    case 1:
      type = .contrast
      slider = contrastSlider
    case 2:
      type = .saturation
      slider = saturationSlider
    case 3:
      type = .gamma
      slider = gammaSlider
    case 4:
      type = .hue
      slider = hueSlider
    default:
      return
    }
    player.setVideoEqualizer(forOption: type, value: 0)
    slider?.intValue = 0
  }

  @IBAction func cropBtnAction(_ sender: AnyObject) {
    mainWindow.hideSideBar {
      self.mainWindow.enterInteractiveMode(.crop, selectWholeVideoByDefault: true)
    }
  }

  // MARK: Audio tab

  @IBAction func loadExternalAudioAction(_ sender: NSButton) {
    let currentDir = player.info.currentURL?.deletingLastPathComponent()
    Utility.quickOpenPanel(title: "Load external audio file", chooseDir: false, dir: currentDir, allowedFileTypes: Utility.supportedFileExt[.audio]) { url in
      self.player.loadExternalAudioFile(url)
      self.audioTableView.reloadData()
    }
  }

  @IBAction func audioDelayChangedAction(_ sender: NSSlider) {
    let eventType = NSApp.currentEvent!.type
    if eventType == .leftMouseDown {
      sender.allowsTickMarkValuesOnly = true
    }
    if eventType == .leftMouseUp {
      sender.allowsTickMarkValuesOnly = false
    }
    let sliderValue = sender.doubleValue
    customAudioDelayTextField.doubleValue = sliderValue
    redraw(indicator: audioDelaySliderIndicator, constraint: audioDelaySliderConstraint, slider: audioDelaySlider, value: "\(customAudioDelayTextField.stringValue)s")
    if let event = NSApp.currentEvent {
      if event.type == .leftMouseUp {
        player.setAudioDelay(sliderValue)
      }
    }
  }

  @IBAction func customAudioDelayEditFinishedAction(_ sender: NSTextField) {
    if sender.stringValue.isEmpty {
      sender.stringValue = "0"
    }
    let value = sender.doubleValue
    player.setAudioDelay(value)
    audioDelaySlider.doubleValue = value
    redraw(indicator: audioDelaySliderIndicator, constraint: audioDelaySliderConstraint, slider: audioDelaySlider, value: "\(sender.stringValue)s")
  }

  @IBAction func audioEqSliderAction(_ sender: NSSlider) {
    player.setAudioEq(fromGains: [
      audioEqSlider1.doubleValue,
      audioEqSlider2.doubleValue,
      audioEqSlider3.doubleValue,
      audioEqSlider4.doubleValue,
      audioEqSlider5.doubleValue,
      audioEqSlider6.doubleValue,
      audioEqSlider7.doubleValue,
      audioEqSlider8.doubleValue,
      audioEqSlider9.doubleValue,
      audioEqSlider10.doubleValue,
      ])
  }

  @IBAction func resetAudioEqAction(_ sender: AnyObject) {
    player.removeAudioEqFilter()
    updateAudioEqState()
  }


  // MARK: Sub tab

  @IBAction func loadExternalSubAction(_ sender: NSSegmentedControl) {
    if sender.selectedSegment == 0 {
      let currentDir = player.info.currentURL?.deletingLastPathComponent()
      Utility.quickOpenPanel(title: "Load external subtitle", chooseDir: false, dir: currentDir, allowedFileTypes: Utility.supportedFileExt[.sub]) { url in
        // set a delay
        self.player.loadExternalSubFile(url, delay: true)
        self.subTableView.reloadData()
        self.secSubTableView.reloadData()
      }
    } else if sender.selectedSegment == 1 {
      showSubChooseMenu(forView: sender)
    }
  }

  func showSubChooseMenu(forView view: NSView, showLoadedSubs: Bool = false) {
    let activeSubs = player.info.trackList(.sub) + player.info.trackList(.secondSub)
    let menu = NSMenu()
    menu.autoenablesItems = false
    // loaded subtitles
    if showLoadedSubs {
      if player.info.subTracks.isEmpty {
        menu.addItem(withTitle: NSLocalizedString("subtrack.no_loaded", comment: "No subtitles loaded"), enabled: false)
      } else {
        menu.addItem(withTitle: NSLocalizedString("track.none", comment: "<None>"),
                     action: #selector(self.chosenSubFromMenu(_:)), target: self,
                     stateOn: player.info.sid == 0 ? true : false)

        for sub in player.info.subTracks {
          menu.addItem(withTitle: sub.readableTitle,
                       action: #selector(self.chosenSubFromMenu(_:)),
                       target: self,
                       obj: sub,
                       stateOn: sub.id == player.info.sid ? true : false)
        }
      }
      menu.addItem(NSMenuItem.separator())
    }
    // external subtitles
    let addMenuItem = { (sub: FileInfo) -> Void in
      let isActive = !showLoadedSubs && activeSubs.contains { $0.externalFilename == sub.path }
      menu.addItem(withTitle: "\(sub.filename).\(sub.ext)",
                   action: #selector(self.chosenSubFromMenu(_:)),
                   target: self,
                   obj: sub,
                   stateOn: isActive ? true : false)

    }
    if player.info.currentSubsInfo.isEmpty {
      menu.addItem(withTitle: NSLocalizedString("subtrack.no_external", comment: "No external subtitles found"),
                   enabled: false)
    } else {
      if let videoInfo = player.info.currentVideosInfo.first(where: { $0.url == player.info.currentURL }),
        !videoInfo.relatedSubs.isEmpty {
        videoInfo.relatedSubs.forEach(addMenuItem)
        menu.addItem(NSMenuItem.separator())
      }
      player.info.currentSubsInfo.sorted { (f1, f2) in
        return f1.filename.localizedStandardCompare(f2.filename) == .orderedAscending
      }.forEach(addMenuItem)
    }
    NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: view)
  }

  @objc func chosenSubFromMenu(_ sender: NSMenuItem) {
    if let fileInfo = sender.representedObject as? FileInfo {
      player.loadExternalSubFile(fileInfo.url)
    } else if let sub = sender.representedObject as? MPVTrack {
      player.setTrack(sub.id, forType: .sub)
    } else {
      player.setTrack(0, forType: .sub)
    }
  }

  @IBAction func searchOnlineAction(_ sender: AnyObject) {
    mainWindow.menuActionHandler.menuFindOnlineSub(.dummy)
  }

  @IBAction func subDelayChangedAction(_ sender: NSSlider) {
    let eventType = NSApp.currentEvent!.type
    if eventType == .leftMouseDown {
      sender.allowsTickMarkValuesOnly = true
    }
    if eventType == .leftMouseUp {
      sender.allowsTickMarkValuesOnly = false
    }
    let sliderValue = sender.doubleValue
    customSubDelayTextField.doubleValue = sliderValue
    redraw(indicator: subDelaySliderIndicator, constraint: subDelaySliderConstraint, slider: subDelaySlider, value: "\(customSubDelayTextField.stringValue)s")
    if let event = NSApp.currentEvent {
      if event.type == .leftMouseUp {
        player.setSubDelay(sliderValue)
      }
    }
  }

  @IBAction func customSubDelayEditFinishedAction(_ sender: NSTextField) {
    if sender.stringValue.isEmpty {
      sender.stringValue = "0"
    }
    let value = sender.doubleValue
    player.setSubDelay(value)
    subDelaySlider.doubleValue = value
    redraw(indicator: subDelaySliderIndicator, constraint: subDelaySliderConstraint, slider: subDelaySlider, value: "\(sender.stringValue)s")
  }

  @IBAction func subScaleReset(_ sender: AnyObject) {
    player.setSubScale(1)
    subScaleSlider.doubleValue = 0
  }

  @IBAction func subPosSliderAction(_ sender: NSSlider) {
    player.setSubPos(Int(sender.intValue))
  }

  @IBAction func subScaleSliderAction(_ sender: NSSlider) {
    let value = sender.doubleValue
    let mappedValue: Double, realValue: Double
    // map [-10, -1], [1, 10] to [-9, 9], bounds may change in future
    if value > 0 {
      mappedValue = round((value + 1) * 20) / 20
      realValue = mappedValue
    } else {
      mappedValue = round((value - 1) * 20) / 20
      realValue = 1 / mappedValue
    }
    player.setSubScale(realValue)
  }

  @IBAction func subTextColorAction(_ sender: AnyObject) {
    player.setSubTextColor(subTextColorWell.color.mpvColorString)
  }

  @IBAction func subTextSizeAction(_ sender: AnyObject) {
    if let selectedItem = subTextSizePopUp.selectedItem, let value = Double(selectedItem.title) {
      player.setSubTextSize(value)
    }
  }

  @IBAction func subTextBorderColorAction(_ sender: AnyObject) {
    player.setSubTextBorderColor(subTextBorderColorWell.color.mpvColorString)
  }

  @IBAction func subTextBorderWidthAction(_ sender: AnyObject) {
    if let selectedItem = subTextBorderWidthPopUp.selectedItem, let value = Double(selectedItem.title) {
      player.setSubTextBorderSize(value)
    }
  }

  @IBAction func subTextBgColorAction(_ sender: AnyObject) {
    player.setSubTextBgColor(subTextBgColorWell.color.mpvColorString)
  }

  @IBAction func subFontAction(_ sender: AnyObject) {
    Utility.quickFontPickerWindow() {
      self.player.setSubFont($0 ?? "")
    }
  }


}

class QuickSettingView: NSView {

  override func mouseDown(with event: NSEvent) {}

}

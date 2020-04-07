//
//  ViewController.swift
//  AudioDeviceExample
//
//  Copyright © 2020 Twilio, Inc. All rights reserved.
//

import CallKit
import UIKit

let twimlParamTo = "to"

class ViewController: UIViewController {
    
    var accessToken: String? = <#Replace with Access Token string#>
    var activeCall: TVOCall?
    var audioDevice: ExampleAVAudioEngineDevice = ExampleAVAudioEngineDevice()
    
    var callKitProvider: CXProvider
    var callKitCallController: CXCallController
    var userInitiatedDisconnect: Bool = false
    var callKitCompletionCallback: ((Bool) -> Void)? = nil

    @IBOutlet weak var outgoingTextField: UITextField!
    @IBOutlet weak var callButton: UIButton!
    @IBOutlet weak var callControlView: UIView!
    @IBOutlet weak var muteSwitch: UISwitch!
    @IBOutlet weak var speakerSwitch: UISwitch!
    @IBOutlet weak var playMusicButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
    }

    required init?(coder aDecoder: NSCoder) {
        let configuration = CXProviderConfiguration(localizedName: "AudioDeviceExample")
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1

        callKitProvider = CXProvider(configuration: configuration)
        callKitCallController = CXCallController()

        super.init(coder: aDecoder)

        callKitProvider.setDelegate(self, queue: nil)
    }
    
    deinit {
        // CallKit has an odd API contract where the developer must call invalidate or the CXProvider is leaked.
        callKitProvider.invalidate()
    }
    
    func toggleUIState(isEnabled: Bool, showCallControl: Bool) {
        callButton.isEnabled = isEnabled
        callControlView.isHidden = !showCallControl;
        muteSwitch.isOn = !showCallControl;
        speakerSwitch.isOn = showCallControl;
    }
    
    // MARK: AVAudioSession
    
    func toggleAudioRoute(toSpeaker: Bool) {
        // The mode set by the Voice SDK is "VoiceChat" so the default audio route is the built-in receiver. Use port override to switch the route.
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(toSpeaker ? .speaker : .none)
        } catch {
            NSLog(error.localizedDescription)
        }
    }
}

// MARK: - TVOCallDelegate

extension ViewController: TVOCallDelegate {
    func callDidStartRinging(_ call: TVOCall) {
        NSLog("callDidStartRinging:")
        
        callButton.setTitle("Ringing", for: .normal)
    }
    
    func callDidConnect(_ call: TVOCall) {
        NSLog("callDidConnect:")
        
        if let callKitCompletionCallback = callKitCompletionCallback {
            callKitCompletionCallback(true)
        }
        
        callButton.setTitle("Hang Up", for: .normal)
        toggleUIState(isEnabled: true, showCallControl: true)
        toggleAudioRoute(toSpeaker: true)
    }
    
    func call(_ call: TVOCall, isReconnectingWithError error: Error) {
        NSLog("call:isReconnectingWithError:")
        
        callButton.setTitle("Reconnecting", for: .normal)
        toggleUIState(isEnabled: false, showCallControl: false)
    }
    
    func callDidReconnect(_ call: TVOCall) {
        NSLog("callDidReconnect:")
        
        callButton.setTitle("Hang Up", for: .normal)
        toggleUIState(isEnabled: true, showCallControl: true)
    }
    
    func call(_ call: TVOCall, didFailToConnectWithError error: Error) {
        NSLog("Call failed to connect: \(error.localizedDescription)")
        
        if let completion = callKitCompletionCallback {
            completion(false)
        }

        performEndCallAction(uuid: call.uuid)
        callDisconnected(call)
    }
    
    func call(_ call: TVOCall, didDisconnectWithError error: Error?) {
        if let error = error {
            NSLog("Call failed: \(error.localizedDescription)")
        } else {
            NSLog("Call disconnected")
        }
        
        if !userInitiatedDisconnect {
            var reason = CXCallEndedReason.remoteEnded
            
            if error != nil {
                reason = .failed
            }
            
            callKitProvider.reportCall(with: call.uuid, endedAt: Date(), reason: reason)
        }

        callDisconnected(call)
    }
    
    func callDisconnected(_ call: TVOCall) {
        if call == activeCall {
            activeCall = nil
        }
        
        userInitiatedDisconnect = false

        toggleUIState(isEnabled: true, showCallControl: false)
        callButton.setTitle("Call", for: .normal)
    }
}

// MARK: - CXProviderDelegate

extension ViewController: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        NSLog("providerDidReset:")
        audioDevice.isEnabled = true
    }

    func providerDidBegin(_ provider: CXProvider) {
        NSLog("providerDidBegin")
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        NSLog("provider:didActivateAudioSession:")
        audioDevice.isEnabled = true
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        NSLog("provider:didDeactivateAudioSession:")
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        NSLog("provider:timedOutPerformingAction:")
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        NSLog("provider:performStartCallAction:")

        audioDevice.isEnabled = false
        
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        
        performVoiceCall(uuid: action.callUUID, client: "") { success in
            if success {
                provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
                action.fulfill()
            } else {
                action.fail()
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        NSLog("provider:performEndCallAction:")
        
        if let call = activeCall {
            call.disconnect()
        }

        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        NSLog("provider:performSetHeldAction:")
        
        if let call = activeCall {
            call.isOnHold = action.isOnHold
            action.fulfill()
        } else {
            action.fail()
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        NSLog("provider:performSetMutedAction:")

        if let call = activeCall {
            call.isMuted = action.isMuted
            action.fulfill()
        } else {
            action.fail()
        }
    }

    
    // MARK: Call Kit Actions
    func performStartCallAction(uuid: UUID, handle: String) {
        let callHandle = CXHandle(type: .generic, value: handle)
        let startCallAction = CXStartCallAction(call: uuid, handle: callHandle)
        let transaction = CXTransaction(action: startCallAction)

        callKitCallController.request(transaction) { error in
            if let error = error {
                NSLog("StartCallAction transaction request failed: \(error.localizedDescription)")
                return
            }

            NSLog("StartCallAction transaction request successful")

            let callUpdate = CXCallUpdate()
            
            callUpdate.remoteHandle = callHandle
            callUpdate.supportsDTMF = true
            callUpdate.supportsHolding = true
            callUpdate.supportsGrouping = false
            callUpdate.supportsUngrouping = false
            callUpdate.hasVideo = false

            self.callKitProvider.reportCall(with: uuid, updated: callUpdate)
        }
    }

    func reportIncomingCall(from: String, uuid: UUID) {
        let callHandle = CXHandle(type: .generic, value: from)

        let callUpdate = CXCallUpdate()
        
        callUpdate.remoteHandle = callHandle
        callUpdate.supportsDTMF = true
        callUpdate.supportsHolding = true
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false

        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if let error = error {
                NSLog("Failed to report incoming call successfully: \(error.localizedDescription).")
            } else {
                NSLog("Incoming call successfully reported.")
            }
        }
    }

    func performEndCallAction(uuid: UUID) {

        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)

        callKitCallController.request(transaction) { error in
            if let error = error {
                NSLog("EndCallAction transaction request failed: \(error.localizedDescription).")
            } else {
                NSLog("EndCallAction transaction request successful")
            }
        }
    }
    
    func performVoiceCall(uuid: UUID, client: String?, completionHandler: @escaping (Bool) -> Void) {
        guard let token = accessToken, token.count > 0 else {
            completionHandler(false)
            return
        }
        
        let connectOptions = TVOConnectOptions(accessToken: token) { builder in
            builder.params = [twimlParamTo: self.outgoingTextField.text ?? ""]
            builder.uuid = uuid
        }
        
        let call = TwilioVoice.connect(with: connectOptions, delegate: self)
        activeCall = call
        callKitCompletionCallback = completionHandler
    }
}


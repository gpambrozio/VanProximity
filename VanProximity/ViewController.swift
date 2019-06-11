//
//  ViewController.swift
//  VanProximity
//
//  Created by Gustavo Ambrozio on 8/30/18.
//  Copyright © 2018 Gustavo Ambrozio. All rights reserved.
//

import UIKit

class ViewController: UIViewController {

    @IBOutlet var connectedLabel: UILabel!
    @IBOutlet var rangingLabel: UILabel!
    @IBOutlet var updatingLocationLabel: UILabel!
    @IBOutlet var locationUpdateLabel: UILabel!
    @IBOutlet var stateButton: UIButton!
    @IBOutlet var locationUpdateStateLabel: UILabel!

    @IBOutlet weak var eventsTextView: UITextView!
    override func viewDidLoad() {
        super.viewDidLoad()

        BTManager.shared.statusStream.onSuccess { [unowned self] message in
            let now = DateFormatter.init()
            now.dateStyle = .none
            now.timeStyle = .long
            self.eventsTextView.text = "\(now.string(from: Date())) \(message)\n\(self.eventsTextView.text ?? "")"
        }

        BTManager.shared.stateStream.onSuccess { [unowned self] state in
            self.connectedLabel.text = state.isConnected ? "Connected !!" : "Disconnected"
            self.rangingLabel.text = state.isRanging ? "Ranging" : "Not Ranging"
        }

        LocationManager.shared.locationStream.onSuccess { [unowned self] location in
            guard let location = location else {
                self.locationUpdateLabel.text = "?"
                return
            }

            let now = DateFormatter.init()
            now.dateStyle = .none
            now.timeStyle = .long
            self.locationUpdateLabel.text = String(format: "%.1f mph, \(now.string(from: location.timestamp))", location.speed * 3600 / 1609.344)
        }

        LocationManager.shared.updateLocationState.onSuccess { [unowned self] isCharging, batteryLevel, isConnected in
            self.locationUpdateStateLabel.text = "charg: \(isCharging), battery: \(batteryLevel), conn: \(isConnected)"
        }

        LocationManager.shared.updatingStream.onSuccess { [unowned self] (updating) in
            self.updatingLocationLabel.text = updating ? "Updating location" : "NOT updating location"
        }
    }

    @IBAction func clearTapped(_ sender: Any) {
        self.eventsTextView.text = ""
    }

    @IBAction func stateTapped(_ sender: Any) {
        stateButton.setTitle("State: \(BTManager.shared.state)", for: .normal)
    }

    @IBAction func restartTapped(_ sender: Any) {
        BTManager.shared.restart()
    }
}


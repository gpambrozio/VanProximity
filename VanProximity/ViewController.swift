//
//  ViewController.swift
//  VanProximity
//
//  Created by Gustavo Ambrozio on 8/30/18.
//  Copyright © 2018 Gustavo Ambrozio. All rights reserved.
//

import UIKit
import RxSwift

class ViewController: UIViewController {

    @IBOutlet var connectedLabel: UILabel!
    @IBOutlet var rangingLabel: UILabel!
    @IBOutlet var updatingLocationLabel: UILabel!
    @IBOutlet var locationUpdateLabel: UILabel!
    @IBOutlet var locationUpdateStateLabel: UILabel!

    @IBOutlet weak var eventsTextView: UITextView!

    private let disposeBag = DisposeBag()

    override func viewDidLoad() {
        super.viewDidLoad()

        let statusStreams = PublishSubject.merge([
            BTManager.shared.statusStream,
            NotificationManager.shared.statusStream
        ])

        statusStreams
            .subscribe(onNext: { [unowned self] message in
                let now = DateFormatter.init()
                now.dateStyle = .none
                now.timeStyle = .long
                self.eventsTextView.text = "\(now.string(from: Date())) \(message)\n\(self.eventsTextView.text ?? "")"
            })
            .disposed(by: self.disposeBag)

        BTManager.shared
            .stateStream
            .subscribe(onNext: { [unowned self] state in
                self.connectedLabel.text = state.isConnected ? "Connected !!" : "Disconnected"
                self.rangingLabel.text = state.isRanging ? "Ranging" : "Not Ranging"
            })
            .disposed(by: self.disposeBag)

        LocationManager.shared
            .locationStream
            .subscribe(onNext: { [unowned self] location in
                guard let location = location else {
                    self.locationUpdateLabel.text = "?"
                    return
                }

                let now = DateFormatter.init()
                now.dateStyle = .none
                now.timeStyle = .long
                self.locationUpdateLabel.text = String(format: "%.1f mph, \(now.string(from: location.timestamp))", location.speed * 3600 / 1609.344)
            })
            .disposed(by: self.disposeBag)

        LocationManager.shared
            .updateLocationState
            .subscribe(onNext: { [unowned self] isCharging, batteryLevel, isConnected in
                self.locationUpdateStateLabel.text = "charg: \(isCharging), battery: \(batteryLevel), conn: \(isConnected)"
            })
            .disposed(by: self.disposeBag)

        LocationManager.shared
            .updatingStream
            .subscribe(onNext: { [unowned self] (updating) in
                self.updatingLocationLabel.text = updating ? "Updating location" : "NOT updating location"
            })
            .disposed(by: self.disposeBag)
    }

    @IBAction func clearTapped(_ sender: Any) {
        self.eventsTextView.text = ""
    }

    @IBAction func lockTapped(_ sender: Any) {
        BTManager.shared.lock(true)
    }

    @IBAction func unlockTapped(_ sender: Any) {
        BTManager.shared.lock(false)
    }

    @IBAction func restartTapped(_ sender: Any) {
        BTManager.shared.restart()
    }
}


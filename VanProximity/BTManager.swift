//
//  BTManager.swift
//  VanProximity
//
//  Created by Gustavo Ambrozio on 8/30/18.
//  Copyright © 2018 Gustavo Ambrozio. All rights reserved.
//

import Foundation
import CoreLocation
import CoreBluetooth

import RxBluetoothKit
import RxCoreLocation
import RxSwift

class BTManager {

    static let shared = BTManager()

    public let statusStream = PublishSubject<String>()

    typealias State = (isRanging: Bool, isConnected: Bool)
    public let stateStream = PublishSubject<State>()
    private let proximityState = PublishSubject<Bool>()

    private func updateState() {
        stateStream.onNext((isRanging: isRanging, isConnected: isConnected))
    }

    var isRanging = false {
        didSet {
            updateState()
        }
    }
    var isConnected = false {
        didSet {
            updateState()
        }
    }

    var state: String {
        return "\(manager.state)"
    }

    private let locationManager = CLLocationManager()
    private let beaconRegion: CLBeaconRegion
    private let beaconUUID = UUID(uuidString: "A495DEAD-C5B1-4B44-B512-1370F02D74DE")!

    private let manager = CentralManager(options: [CBCentralManagerOptionRestoreIdentifierKey : "us.gnos.BlueCap.central-manager-example" as NSString])

    private var peripheral: Peripheral?
    private var accelerometerDataCharacteristic: Characteristic?

    private let disposeBag = DisposeBag()

    private init() {
        beaconRegion = CLBeaconRegion(proximityUUID: beaconUUID, identifier: "Example Beacon")
        proximityState
            .debounce(.seconds(10), scheduler: MainScheduler())
            .distinctUntilChanged()
            .subscribe(onNext: { proximity in
                NotificationManager.shared.notify("Van is \(proximity ? "near" : "far")")
            })
            .disposed(by: disposeBag)
    }

    func start() {
        startMonitoring()
        startCentral()
    }

    func restart() {
        startCentral()
    }

    private func startMonitoring() {
        let beaconRangingFuture = locationManager.rx.isRangingAvailable.flatMapLatest { [locationManager, beaconRegion] available -> Observable<CLRegionEvent> in
            locationManager.startMonitoring(for: beaconRegion)
            return locationManager.rx.didReceiveRegion.asObservable()
        }.flatMapLatest { [unowned self]  (manager: CLLocationManager, region: CLRegion, state: CLRegionEventState) -> Observable<CLBeaconsEvent> in
            manager.startRangingBeacons(in: self.beaconRegion)
            self.isRanging = true
            return manager.rx.didRangeBeacons.asObservable()
        }

        var lastProximity = false
        beaconRangingFuture.subscribe(
            onNext: { [unowned self] (manager: CLLocationManager, beacons: [CLBeacon], region: CLBeaconRegion) in
                guard self.isRanging,
                    let beacon = beacons.first else {
                        return
                }
                if case .unknown = beacon.proximity { return }
                let near = { () -> Bool in
                    switch beacon.proximity {
                    case .unknown, .far:
                        return false
                    case .immediate, .near:
                        return true
                    @unknown default:
                        return false
                    }
                }()
                self.proximityState.onNext(near)
                if lastProximity != near {
                    lastProximity = near
                    self.present("Van might be \(near ? "near" : "far")")
                }
            },
            onError: { (error) in

            }
        )
        .disposed(by: disposeBag)
    }

    private func present(_ message: String) {
        statusStream.onNext(message)
    }

    private var centralDisposeBag = DisposeBag()
    private func startCentral() {
        let serviceUUID = CBUUID(string: "ec00")
        let dataUUID = CBUUID(string: "ec0e")

        centralDisposeBag = DisposeBag()
        manager.observeState()
            .startWith(manager.state)
            .filter { $0 == .poweredOn }
            .flatMapLatest { [manager] _ -> Observable<Peripheral> in
                let connected = manager.retrieveConnectedPeripherals(withServices: [serviceUUID])
                if let peripheral = connected.first {
                    return Observable.just(peripheral)
                }
                return manager.scanForPeripherals(withServices: [serviceUUID])
                    .flatMapLatest { [weak self] scanned -> Observable<Peripheral> in
                        self?.peripheral = scanned.peripheral
                        return scanned.peripheral.establishConnection()
                    }
            }
            .flatMapLatest {
                $0.discoverServices([serviceUUID])
            }
            .flatMapLatest {
                $0[0].discoverCharacteristics([dataUUID])
            }
            .subscribe(
                onNext: { [weak self] characteristics in
                    guard let self = self else { return }

                    self.accelerometerDataCharacteristic = characteristics[0]
                    if !self.isConnected {
                        self.isConnected = true
                        self.updateTime()
                        NotificationManager.shared.notify("Connected to van", category: .connected)
                    }
                },
                onError: { [weak self] error in
                    guard let self = self else { return }

                    self.present("disconnected: \(error)")
                    NotificationManager.shared.notify("Disconnected from van: \(error)", category: .disconnected)
                    if let peripheral = self.peripheral?.peripheral {
                        self.manager.manager.cancelPeripheralConnection(peripheral)
                    }
                    self.isConnected = false
                    self.peripheral = nil
                    self.accelerometerDataCharacteristic = nil
                    self.restart()
                }
            )
            .disposed(by: centralDisposeBag)
    }

    @discardableResult
    private func writeToDevice(_ command: String) -> Bool {
        guard let accelerometerDataCharacteristic = accelerometerDataCharacteristic else {
            restart()
            return false
        }
        _ = accelerometerDataCharacteristic
            .writeValue(command.data(using: .utf8)!, type: .withResponse)
            .subscribe(
                onSuccess: { characteristic in
                    
                },
                onError: { error in

                }
            )
            .disposed(by: disposeBag)

        return true
    }

    private var inRegion = false
    private func setInsideRegion() {
        if !inRegion {
            inRegion = true
            NotificationManager.shared.notify("Entered region.", category: .enteredRegion)
        }
        startBackgroundHandler()
    }

    private func startBackgroundHandler() {
        var backgroundHandler = UIBackgroundTaskIdentifier.invalid
        backgroundHandler = UIApplication.shared.beginBackgroundTask {
            guard backgroundHandler != UIBackgroundTaskIdentifier.invalid else { return }
            UIApplication.shared.endBackgroundTask(convertToUIBackgroundTaskIdentifier(backgroundHandler.rawValue))
            backgroundHandler = UIBackgroundTaskIdentifier.invalid
        }
    }

    private func setOutsideRegion() {
        if inRegion {
            inRegion = false
            NotificationManager.shared.notify("Exited region.", category: .leftRegion)
        }
    }

    private var lastCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    private var lastAltitude: CLLocationDistance = -1000
    private var lastSpeed: CLLocationSpeed = -1000
    private var lastHeading: CLLocationDirection = -1

    public func updateLocation(_ location: CLLocation, heading: CLLocationDirection, force: Bool) {
        if force || abs(lastCoordinate.latitude - location.coordinate.latitude) >= 0.0001 || abs(lastCoordinate.longitude - location.coordinate.longitude) > 0.0001 {
            lastCoordinate = location.coordinate
            writeToDevice(String(format: "L%.0f,%.0f", 10000 * location.coordinate.latitude, 10000 * location.coordinate.longitude))
        }

        if force || abs(lastAltitude - location.altitude) >= 1 || abs(lastSpeed - location.speed) >= 1 || (abs(lastHeading - heading) >= 1 && location.speed > 4) {
            lastAltitude = location.altitude
            lastSpeed = location.speed
            lastHeading = heading
            writeToDevice(String(format: "A%.0f,%.0f,%.0f", location.altitude, location.speed * 3600 / 1609.344, heading))
        }
    }

    public func lock(_ lock: Bool) {
        writeToDevice("l\((lock ? "L" : "U"))")
    }

    private func updateTime() {
        let dateFormat = DateFormatter()
        dateFormat.dateFormat = "MMddHHmmyy.ss"
        dateFormat.timeZone = TimeZone.current
        writeToDevice(String(format: "T%@;%@", dateFormat.string(from: Date()), dateFormat.timeZone.identifier))
    }
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertToUIBackgroundTaskIdentifier(_ input: Int) -> UIBackgroundTaskIdentifier {
	return UIBackgroundTaskIdentifier(rawValue: input)
}

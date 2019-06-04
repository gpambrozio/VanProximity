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
import BlueCapKit
import UserNotifications

enum AppError : Swift.Error {
    case rangingBeacon
    case started
    case outside
    case inside
    case unknownState
}
public enum CentraError : Error {
    case dataCharactertisticNotFound
    case serviceNotFound
    case invalidState
    case resetting
    case poweredOff
    case unknown
    case unlikley
}

class Debouncer<T> where T: Equatable {
    private var currentState: T
    private var lastState: T
    private var lastStateTime: TimeInterval
    private let debounceTime: TimeInterval

    private let statePromise = StreamPromise<T>(capacity: 10)
    public var stateStream: FutureStream<T> {
        return statePromise.stream
    }

    required init(_ state: T, debounce: TimeInterval = 15) {
        currentState = state
        lastState = state
        lastStateTime = Date.timeIntervalSinceReferenceDate
        debounceTime = debounce
    }

    private func checkLastState() {
        if currentState != lastState && Date.timeIntervalSinceReferenceDate - lastStateTime >= debounceTime {
            currentState = lastState
            statePromise.success(currentState)
        }
    }

    var state: T {
        get {
            return currentState
        }
        set {
            guard lastState != newValue else { return }
            lastState = newValue
            lastStateTime = Date.timeIntervalSinceReferenceDate
            Timer.scheduledTimer(withTimeInterval: debounceTime, repeats: false) { [weak self] _ in
                self?.checkLastState()
            }
        }
    }
}

class BTManager {

    static let shared = BTManager()

    private let statusPromise = StreamPromise<String>(capacity: 10)
    public var statusStream: FutureStream<String> {
        return statusPromise.stream
    }
    typealias State = (isRanging: Bool, isConnected: Bool)
    private let statePromise = StreamPromise<State>(capacity: 10)
    public var stateStream: FutureStream<State> {
        return statePromise.stream
    }

    private var beaconRegion: BeaconRegion
    private var beaconRangingFuture: FutureStream<[Beacon]>?

    private func updateState() {
        statePromise.success((isRanging: isRanging, isConnected: isConnected))
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
        return "\(manager.state.description)"
    }

    let proximityState = Debouncer(false)

    private let beaconManager = BeaconManager()
    private let beaconUUID = UUID(uuidString: "A495DEAD-C5B1-4B44-B512-1370F02D74DE")!

    private var peripheral: Peripheral?
    private var accelerometerDataCharacteristic: Characteristic?

    private let manager = CentralManager(options: [CBCentralManagerOptionRestoreIdentifierKey : "us.gnos.BlueCap.central-manager-example" as NSString])

    private init() {
        beaconRegion = BeaconRegion(proximityUUID: beaconUUID, identifier: "Example Beacon")
        proximityState.stateStream.onSuccess { (proximity) in
            self.notify("Van is \(proximity ? "near" : "far")")
        }
    }

    func start() {
        startMonitoring()
        startCentral()
    }

    func restart() {
        manager.reset()
    }

    private func startMonitoring() {
        guard beaconManager.isRangingAvailable(), !beaconManager.isMonitoring else {
            return
        }
        beaconRangingFuture = beaconManager.startMonitoring(for: beaconRegion, authorization: .authorizedAlways).flatMap { [unowned self] state -> FutureStream<[Beacon]> in
            switch state {
            case .start:
                self.isRanging = false
                throw AppError.started
            case .inside:
                self.setInsideRegion()
                self.isRanging = true
                return self.beaconManager.startRangingBeacons(in: self.beaconRegion, authorization: .authorizedAlways)
            case .outside:
                self.setOutsideRegion()
                self.beaconManager.stopRangingBeacons(in: self.beaconRegion)
                self.isRanging = false
                throw AppError.outside
            case .unknown:
                throw AppError.unknownState
            }
        }
        var lastProximity = false
        beaconRangingFuture?.onSuccess { [unowned self] beacons in
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
                }
            }()
            self.proximityState.state = near
            if lastProximity != near {
                lastProximity = near
                self.present("Van might be \(near ? "near" : "far")")
            }
        }
        beaconRangingFuture?.onFailure { error in
            if error is AppError {
                return
            }
        }
    }

    private func addNotification(_ message: String, delay: TimeInterval, identifier: String?) {
        let content = UNMutableNotificationContent()
        content.title = ""
        content.body = message
        content.sound = UNNotificationSound.default()
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: identifier ?? UUID().uuidString, content: content, trigger: trigger)
        let center = UNUserNotificationCenter.current()
        center.add(request)
        center.getDeliveredNotifications { (notifications) in
            let idsToRemove = notifications.sorted(by: { (n1, n2) -> Bool in
                n2.date < n1.date
            }).map { $0.request.identifier }
            guard idsToRemove.count > 10 else { return }
            DispatchQueue.main.async {
                center.removeDeliveredNotifications(withIdentifiers: [] + idsToRemove[10...])
            }
        }
    }

    private func notify(_ message: String, delay: TimeInterval = 0.1, identifier: String? = nil, cancelsIdentifier: String? = nil) {
        statusPromise.success(message)

        if let cancelsIdentifier = cancelsIdentifier {
            let center = UNUserNotificationCenter.current()
            center.getPendingNotificationRequests { [weak self] (notifications) in
                if notifications.first(where: { n -> Bool in n.identifier == cancelsIdentifier }) != nil {
                    center.removePendingNotificationRequests(withIdentifiers: [cancelsIdentifier])
                } else {
                    self?.addNotification(message, delay: delay, identifier: identifier)
                }
            }
        } else {
            addNotification(message, delay: delay, identifier: identifier)
        }
    }

    private func present(_ message: String) {
        statusPromise.success(message)
    }

    private func startCentral() {
        let serviceUUID = CBUUID(string: "ec00")
        let dataUUID = CBUUID(string: "ec0e")

        // on power, start scanning. when peripheral is discovered connect and stop scanning
        let dataUpdateFuture = manager.whenStateChanges().flatMap { [unowned self] state -> FutureStream<Peripheral> in
            switch state {
            case .poweredOn:
                self.manager.disconnectAllPeripherals()
                return self.manager.startScanning(forServiceUUIDs: [serviceUUID], capacity: 10)
            case .poweredOff:
                throw CentraError.poweredOff
            case .unauthorized, .unsupported:
                throw CentraError.invalidState
            case .resetting:
                throw CentraError.resetting
            case .unknown:
                throw CentraError.unknown
            }
        }.flatMap { [unowned self] peripheral -> FutureStream<Void> in
            self.manager.stopScanning()
            self.peripheral = peripheral
            return peripheral.connect(connectionTimeout: 10.0)
        }.flatMap { [unowned self] () -> Future<Void> in
            guard let peripheral = self.peripheral else {
                throw CentraError.unlikley
            }
            return peripheral.discoverServices([serviceUUID])
        }.flatMap { [unowned self] () -> Future<Void> in
            guard let peripheral = self.peripheral else {
                throw CentraError.unlikley
            }
            guard let service = peripheral.services(withUUID: serviceUUID)?.first else {
                print("\(peripheral.services)")
                throw CentraError.serviceNotFound
            }
            return service.discoverCharacteristics([dataUUID])
        }.flatMap { [unowned self] () -> Future<Void> in
            guard let peripheral = self.peripheral, let service = peripheral.services(withUUID: serviceUUID)?.first else {
                throw CentraError.serviceNotFound
            }
            guard let dataCharacteristic = service.characteristics(withUUID: dataUUID)?.first else {
                throw CentraError.dataCharactertisticNotFound
            }
            self.accelerometerDataCharacteristic = dataCharacteristic
            LocationManager.shared.startUpdatingLocation()
            return dataCharacteristic.startNotifying()
        }.flatMap { [unowned self] () -> FutureStream<Data?> in
            guard let accelerometerDataCharacteristic = self.accelerometerDataCharacteristic else {
                throw CentraError.dataCharactertisticNotFound
            }
            if !self.isConnected {
                self.isConnected = true
                self.updateTime()
                self.notify("Connected to van", delay: 1, identifier: "connected", cancelsIdentifier: "disconnected")
            }

            return accelerometerDataCharacteristic.receiveNotificationUpdates(capacity: 10)
        }

        dataUpdateFuture.onFailure { [unowned self] error in
            self.present("disconnected: \(error)")
            if self.isConnected {
                self.isConnected = false
                self.notify("Disconnected from van: \(error)", delay: 20, identifier: "disconnected", cancelsIdentifier: "connected")
            }
            self.peripheral?.disconnect()
            self.manager.reset()
            LocationManager.shared.stopUpdatingLocation()
        }

        dataUpdateFuture.onSuccess { data in
            print("Got data \(data ?? Data())")
        }
    }

    @discardableResult
    private func writeToDevice(_ command: String) -> Bool {
        guard let accelerometerDataCharacteristic = self.accelerometerDataCharacteristic else {
            manager.reset()
            return false
        }
        _ = accelerometerDataCharacteristic.write(data: command.data(using: .utf8)!).result
        return true
    }

    private var inRegion = false
    private func setInsideRegion() {
        if !inRegion {
            inRegion = true
            notify("Entered region.", delay: 1, identifier: "enteredRegion", cancelsIdentifier: "leftRegion")
        }
        startBackgroundHandler()
    }

    private func startBackgroundHandler() {
        var backgroundHandler = UIBackgroundTaskInvalid
        backgroundHandler = UIApplication.shared.beginBackgroundTask {
            guard backgroundHandler != UIBackgroundTaskInvalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundHandler)
            backgroundHandler = UIBackgroundTaskInvalid
        }
    }

    private func setOutsideRegion() {
        if inRegion {
            inRegion = false
            notify("Exited region.", delay: 30, identifier: "leftRegion", cancelsIdentifier: "enteredRegion")
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

    private func updateTime() {
        let dateFormat = DateFormatter()
        dateFormat.dateFormat = "MMddHHmmyy.ss"
        dateFormat.timeZone = TimeZone.current
        writeToDevice(String(format: "T%@;%@", dateFormat.string(from: Date()), dateFormat.timeZone.identifier))
    }
}

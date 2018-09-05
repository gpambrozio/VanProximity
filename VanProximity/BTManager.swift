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

class BTManager {

    static let shared = BTManager()

    private let statusPromise = StreamPromise<String>(capacity: 10)
    public var statusStream: FutureStream<String> {
        return statusPromise.stream
    }

    private var beaconRegion: BeaconRegion
    private var beaconRangingFuture: FutureStream<RegionState>?

    var isRanging = false
    var isConnected = false

    private let beaconManager = BeaconManager()
    private let beaconUUID = UUID(uuidString: "A495DEAD-C5B1-4B44-B512-1370F02D74DE")!

    private var peripheral: Peripheral?
    private var accelerometerDataCharacteristic: Characteristic?

    private let manager = CentralManager(options: [CBCentralManagerOptionRestoreIdentifierKey : "us.gnos.BlueCap.central-manager-example" as NSString])

    private init() {
        beaconRegion = BeaconRegion(proximityUUID: beaconUUID, identifier: "Example Beacon")
    }

    @discardableResult
    func startMonitoring() -> Bool {
        guard beaconManager.isRangingAvailable() else {
            return false
        }
        guard !beaconManager.isMonitoring else {
            return true
        }
        beaconRangingFuture = beaconManager.startMonitoring(for: beaconRegion, authorization: .authorizedAlways)
        beaconRangingFuture?.onSuccess { [unowned self] state in
            switch state {
            case .start:
                self.isRanging = false
            case .inside:
                self.setInsideRegion()
                self.isRanging = true
            case .outside:
                self.setOutsideRegion()
            case .unknown:
                break
            }
        }
        startCentral()
        return true
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
                self.writeToDevice("C")
                guard let accelerometerDataCharacteristic = self.accelerometerDataCharacteristic else {
                    throw CentraError.dataCharactertisticNotFound
                }
                if !self.isConnected {
                    self.isConnected = true
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
        _ = accelerometerDataCharacteristic.write(data: command.data(using: .utf8)!)
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

    public func updateLocation(_ location: CLLocation, heading: CLLocationDirection) {
        writeToDevice(String(format: "L%.0f,%.0f", 10000 * location.coordinate.latitude, 10000 * location.coordinate.longitude))
        writeToDevice(String(format: "A%.0f,%.0f,%.0f", location.altitude, location.speed * 3600 / 1609.344, heading))
    }
}

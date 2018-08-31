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

enum AppError : Swift.Error {
    case rangingBeacon
    case started
    case outside
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

    var beaconRegion: BeaconRegion
    var beaconRangingFuture: FutureStream<[Beacon]>?

    var isRanging = false

    let beaconManager = BeaconManager()
    let beaconUUID = UUID(uuidString: "A495DEAD-C5B1-4B44-B512-1370F02D74DE")!

    var peripheral: Peripheral?
    var accelerometerDataCharacteristic: Characteristic?

    let manager = CentralManager(options: [CBCentralManagerOptionRestoreIdentifierKey : "us.gnos.BlueCap.central-manager-example" as NSString])

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
        beaconRangingFuture = beaconManager.startMonitoring(for: beaconRegion, authorization: .authorizedAlways).flatMap{ [unowned self] state -> FutureStream<[Beacon]> in
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
                throw AppError.outside
            case .unknown:
                throw AppError.unknownState
            }
        }
        beaconRangingFuture?.onSuccess { [unowned self] beacons in
            guard self.isRanging else {
                return
            }
        }
        beaconRangingFuture?.onFailure { [unowned self] error in
            if error is AppError {
                return
            }
            self.notify("Error: '\(error.localizedDescription)'")
        }
        return true
    }

    private func notify(_ message: String) {
        print("Notify: \(message)")
    }

    private func present(_ message: String) {
        print("Present: \(message)")
    }

    private func startCentral() {
        let serviceUUID = CBUUID(string: "ec00")
        let dataUUID = CBUUID(string: "ec0e")

        // on power, start scanning. when peripheral is discovered connect and stop scanning
        let dataUpdateFuture = manager.whenStateChanges().flatMap { [unowned self] state -> FutureStream<Peripheral> in
            switch state {
            case .poweredOn:
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
                return accelerometerDataCharacteristic.receiveNotificationUpdates(capacity: 10)
            }

        dataUpdateFuture.onFailure { [unowned self] error in
            switch error {
            case CentraError.dataCharactertisticNotFound:
                break
            case CentraError.serviceNotFound:
                self.peripheral?.disconnect()
                self.present("error: \(error)")
            case CentraError.invalidState:
                self.present("Invalid state")
            case CentraError.resetting:
                self.present("Bluetooth service resetting")
            case CentraError.poweredOff:
                self.present("Bluetooth powered off")
            case CentraError.unknown:
                break
            case PeripheralError.disconnected:
                break
            case PeripheralError.forcedDisconnect:
                break
            default:
                self.present("error: \(error)")
            }
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
            return false
        }
        _ = accelerometerDataCharacteristic.write(data: command.data(using: .utf8)!)
        return true
    }

    private func setInsideRegion() {
        notify("Entered region '\(self.beaconRegion.identifier)'. Started ranging beacons.")
        var backgroundHandler = UIBackgroundTaskInvalid
        backgroundHandler = UIApplication.shared.beginBackgroundTask {
            guard backgroundHandler != UIBackgroundTaskInvalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundHandler)
            backgroundHandler = UIBackgroundTaskInvalid
        }
        startCentral()
    }

    private func setOutsideRegion() {
        notify("Exited region '\(self.beaconRegion.identifier). Stopped ranging beacons.'")
    }

    public func updateLocation(_ location: CLLocation, heading: CLLocationDirection) {
        writeToDevice(String(format: "L:%.1f,%.1f", location.coordinate.latitude, location.coordinate.longitude))
        writeToDevice(String(format: "A:%.0f;S:%.1f;H:%.0f", 3.281 * location.altitude, location.speed * 3600 / 1609.344, heading))
    }
}

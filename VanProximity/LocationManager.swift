//
//  LocationManager.swift
//  VanProximity
//
//  Created by Gustavo Ambrozio on 8/30/18.
//  Copyright © 2018 Gustavo Ambrozio. All rights reserved.
//

import Foundation
import CoreLocation
import BlueCapKit

private extension UIDevice.BatteryState {
    var isCharging: Bool {
        switch self {
        case .unknown, .unplugged:
            return false
        case .charging, .full:
            return true
        }
    }
}

class LocationManager: NSObject {

    static let shared = LocationManager()
    private let locationManager = CLLocationManager()
    private let device = UIDevice.current

    private let locationPromise = StreamPromise<CLLocation?>(capacity: 1)
    public var locationStream: FutureStream<CLLocation?> {
        return locationPromise.stream
    }
    private let updatingPromise = StreamPromise<Bool>(capacity: 1)
    public var updatingStream: FutureStream<Bool> {
        return updatingPromise.stream
    }
    private let batteryStatePromise = StreamPromise<UIDevice.BatteryState>(capacity: 1)
    private let batteryLevelPromise = StreamPromise<Float>(capacity: 1)

    private var lastHeading: CLLocationDirection?
    private var lastLocation: CLLocation? {
        didSet {
            locationPromise.success(lastLocation)
        }
    }

    public let updateLocationState: FutureStream<(Bool, Float, Bool)>

    private override init() {
        device.isBatteryMonitoringEnabled = true

        NotificationCenter.default.addObserver(
            forName: .UIDeviceBatteryStateDidChange,
            object: nil,
            queue: OperationQueue.main) { [batteryStatePromise, device] _ in
                batteryStatePromise.success(device.batteryState)
            }

        NotificationCenter.default.addObserver(
            forName: .UIDeviceBatteryLevelDidChange,
            object: nil,
            queue: OperationQueue.main) { [batteryLevelPromise, device] _ in
                batteryLevelPromise.success(device.batteryLevel)
            }

        let combinedBattery = batteryStatePromise.stream.flatMap { [batteryLevelPromise] batteryState in
            batteryLevelPromise.stream.map { (batteryState, $0) }
        }

        updateLocationState = combinedBattery.flatMap { batteryState, batteryLevel in
            BTManager.shared.stateStream.map { btManagerState -> (Bool, Float, Bool) in
                (batteryState.isCharging, batteryLevel, btManagerState.isConnected)
            }
        }
        super.init()

        locationManager.delegate = self

        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.activityType = .other
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()

        let shouldUpdateLocation = updateLocationState.map { isCharging, batteryLevel, isConnected in
            return isConnected && (isCharging || batteryLevel >= 0.85)
        }

        shouldUpdateLocation.onSuccess { [weak self] (shouldUpdateLocation) in
            print("shouldUpdateLocation: \(shouldUpdateLocation)")
            if shouldUpdateLocation {
                self?.startUpdatingLocation()
            } else {
                self?.stopUpdatingLocation()
            }
        }

        // Send current as notification only fires when changed
        batteryStatePromise.success(device.batteryState)
        batteryLevelPromise.success(device.batteryLevel)
    }

    private var isUpdatingLocation = false
    private func startUpdatingLocation() {
        guard !isUpdatingLocation else { return }
        isUpdatingLocation = true
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5
        locationManager.activityType = .automotiveNavigation
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
        updateBTManager(force: true)
        updatingPromise.success(true)
    }

    private func stopUpdatingLocation() {
        guard isUpdatingLocation else { return }
        isUpdatingLocation = false
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.activityType = .other
        locationManager.showsBackgroundLocationIndicator = false
        locationManager.stopUpdatingHeading()
        updatingPromise.success(false)
    }

    private func updateBTManager(force: Bool = false) {
        guard let lastLocation = lastLocation, let lastHeading = lastHeading else {
            return
        }
        BTManager.shared.updateLocation(lastLocation, heading: lastHeading, force: force)
    }
}

extension LocationManager: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        lastLocation = location
        updateBTManager()
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        lastHeading = newHeading.trueHeading
        updateBTManager()
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Error: \(error)")
    }
}

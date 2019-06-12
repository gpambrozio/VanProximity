//
//  LocationManager.swift
//  VanProximity
//
//  Created by Gustavo Ambrozio on 8/30/18.
//  Copyright © 2018 Gustavo Ambrozio. All rights reserved.
//

import Foundation
import CoreLocation
import RxCoreLocation
import RxSwift

private extension UIDevice.BatteryState {
    var isCharging: Bool {
        switch self {
        case .unknown, .unplugged:
            return false
        case .charging, .full:
            return true
        @unknown default:
            return false
        }
    }
}

class LocationManager: NSObject {

    static let shared = LocationManager()
    private let locationManager = CLLocationManager()
    private let device = UIDevice.current

    public let locationStream = PublishSubject<CLLocation?>()
    public let updatingStream = PublishSubject<Bool>()

    public let updateLocationState: Observable<(Bool, Float, Bool)>

    private var lastHeading: CLLocationDirection?
    private var lastLocation: CLLocation? {
        didSet {
            locationStream.onNext(lastLocation)
        }
    }

    private let disposeBag = DisposeBag()

    private override init() {
        device.isBatteryMonitoringEnabled = true

        let batteryStatePromise = PublishSubject<UIDevice.BatteryState>()
        let batteryLevelPromise = PublishSubject<Float>()

        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: OperationQueue.main) { [batteryStatePromise, device] _ in
                batteryStatePromise.onNext(device.batteryState)
            }

        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: OperationQueue.main) { [batteryLevelPromise, device] _ in
                batteryLevelPromise.onNext(device.batteryLevel)
            }

        let combined = PublishSubject.combineLatest(batteryStatePromise, batteryLevelPromise, BTManager.shared.stateStream)
        updateLocationState = combined.map { (batteryState, batteryLevel, btManagerState) -> (Bool, Float, Bool) in
            (batteryState.isCharging, batteryLevel, btManagerState.isConnected)
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
            return isConnected && (isCharging || batteryLevel >= 8)
        }

        shouldUpdateLocation
            .distinctUntilChanged()
            .subscribe(onNext: { [weak self] shouldUpdateLocation in
                print("shouldUpdateLocation: \(shouldUpdateLocation)")
                if shouldUpdateLocation {
                    self?.startUpdatingLocation()
                } else {
                    self?.stopUpdatingLocation()
                }
            })
            .disposed(by: disposeBag)

        // Send current as notification only fires when changed
        batteryStatePromise.onNext(device.batteryState)
        batteryLevelPromise.onNext(device.batteryLevel)
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
        updatingStream.onNext(true)
    }

    private func stopUpdatingLocation() {
        guard isUpdatingLocation else { return }
        isUpdatingLocation = false
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.activityType = .other
        locationManager.showsBackgroundLocationIndicator = false
        locationManager.stopUpdatingHeading()
        updatingStream.onNext(false)
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

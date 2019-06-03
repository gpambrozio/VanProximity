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

class LocationManager: NSObject {

    static let shared = LocationManager()
    private let locationManager = CLLocationManager()

    private let locationPromise = StreamPromise<CLLocation?>(capacity: 10)
    public var locationStream: FutureStream<CLLocation?> {
        return locationPromise.stream
    }
    private let updatingPromise = StreamPromise<Bool>(capacity: 10)
    public var updatingStream: FutureStream<Bool> {
        return updatingPromise.stream
    }

    private var lastHeading: CLLocationDirection?
    private var lastLocation: CLLocation? {
        didSet {
            locationPromise.success(lastLocation)
        }
    }

    private override init() {
        super.init()
        locationManager.delegate = self

        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.activityType = .other
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
    }

    func startUpdatingLocation() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5
        locationManager.activityType = .automotiveNavigation
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
        updateBTManager(force: true)
        updatingPromise.success(true)
    }

    func stopUpdatingLocation() {
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.activityType = .other
        locationManager.showsBackgroundLocationIndicator = false
        locationManager.stopUpdatingHeading()
        updatingPromise.success(false)
    }

    func updateBTManager(force: Bool = false) {
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

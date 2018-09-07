//
//  LocationManager.swift
//  VanProximity
//
//  Created by Gustavo Ambrozio on 8/30/18.
//  Copyright © 2018 Gustavo Ambrozio. All rights reserved.
//

import Foundation
import CoreLocation

class LocationManager: NSObject {

    static let shared = LocationManager()
    private let locationManager = CLLocationManager()

    private var lastHeading: CLLocationDirection?
    private var lastLocation: CLLocation?

    private override init() {
        super.init()
        locationManager.delegate = self

        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5
        locationManager.activityType = .automotiveNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.requestAlwaysAuthorization()
    }

    func startUpdatingLocation() {
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
        updateBTManager(force: true)
    }

    func stopUpdatingLocation() {
        locationManager.showsBackgroundLocationIndicator = false
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
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

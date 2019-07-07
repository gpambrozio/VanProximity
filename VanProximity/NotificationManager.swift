//
//  NotificationManager.swift
//  VanProximity
//
//  Created by Gustavo Ambrozio on 6/21/19.
//  Copyright © 2019 Gustavo Ambrozio. All rights reserved.
//

import Foundation
import UserNotifications
import RxSwift

class NotificationManager: NSObject {
    enum Action: String {
        case unlock = "Unlock"
    }

    enum Category: String {
        case connected
        case disconnected
        case leftRegion
        case enteredRegion

        var cancelsCategory: Category {
            switch self {
            case .connected: return .disconnected
            case .disconnected: return .connected
            case .leftRegion: return .enteredRegion
            case .enteredRegion: return .leftRegion
            }
        }

        var delay: TimeInterval {
            switch self {
            case .connected: return 1
            case .disconnected: return 20
            case .leftRegion: return 1
            case .enteredRegion: return 30
            }
        }

        var hasSound: Bool {
            switch self {
            case .connected: return true
            case .disconnected: return false
            case .leftRegion: return false
            case .enteredRegion: return false
            }
        }
    }
    static let shared = NotificationManager()
    public let statusStream = PublishSubject<String>()

    private override init() {
        super.init()

        // Define the custom actions.
        let unlockAction = UNNotificationAction(identifier: Action.unlock.rawValue,
                                                title: Action.unlock.rawValue,
                                                options: [])

        // Define the notification type
        let connectedCategory =
            UNNotificationCategory(identifier: Category.connected.rawValue,
                                   actions: [unlockAction],
                                   intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: "",
                                   options: .customDismissAction)

        // Register the notification type.
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.setNotificationCategories([connectedCategory])
        notificationCenter.delegate = self
    }

    private func addNotification(_ message: String, delay: TimeInterval, category: Category?) {
        let content = UNMutableNotificationContent()
        content.title = ""
        content.body = message
        if let category = category {
            content.categoryIdentifier = category.rawValue
            content.sound = category.hasSound ? .default : .none
        } else {
            content.sound = .none
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: category?.rawValue ?? UUID().uuidString, content: content, trigger: trigger)
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

    public func notify(_ message: String, category: Category? = nil) {
        statusStream.onNext(message)

        let delay = category?.delay ?? 0.1
        if let cancelsCategory = category?.cancelsCategory {
            let center = UNUserNotificationCenter.current()
            center.getPendingNotificationRequests { [weak self] (notifications) in
                if notifications.first(where: { n -> Bool in n.identifier == cancelsCategory.rawValue }) != nil {
                    center.removePendingNotificationRequests(withIdentifiers: [cancelsCategory.rawValue])
                } else {
                    self?.addNotification(message, delay: delay, category: category)
                }
            }
        } else {
            addNotification(message, delay: delay, category: category)
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let action = Action(rawValue: response.actionIdentifier) {
            switch action {
            case .unlock:
                BTManager.shared.lock(false)
            }
        }
        completionHandler()
    }
}

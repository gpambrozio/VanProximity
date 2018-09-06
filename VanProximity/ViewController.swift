//
//  ViewController.swift
//  VanProximity
//
//  Created by Gustavo Ambrozio on 8/30/18.
//  Copyright © 2018 Gustavo Ambrozio. All rights reserved.
//

import UIKit

class ViewController: UIViewController {

    @IBOutlet weak var eventsTextView: UITextView!
    override func viewDidLoad() {
        super.viewDidLoad()

        BTManager.shared.statusStream.onSuccess { [unowned self] (message) in
            let now = DateFormatter.init()
            now.dateStyle = .none
            now.timeStyle = .long
            self.eventsTextView.text = "\(now.string(from: Date())) \(message)\n\(self.eventsTextView.text ?? "")"
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    @IBAction func clearTapped(_ sender: Any) {
        self.eventsTextView.text = ""
    }

}


//
//  ViewController.swift
//  ArtemisExample
//
//  Created by Pagidimarri Kartheek on 06/10/26.
//

import ArtemisUISDK
import UIKit

class ViewController: UIViewController {

    // Uses the same runtime configuration as the SwiftUI example.
    private let configuration = SDKConfiguration(
        environment: "dev",
        connection: ConnectionConfig(
            projectId: "your-project-id", endpoint: "https://runtime.example.com", apiKey: "pk_your_public_key"),
        channel: ChannelConfig(channelId: "your-channel-id")
    )

    private lazy var chatHandle = AgentChatUI.initialize(configuration: configuration)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Artemis Example"
    }

    @IBAction func tapsOnConnectBtnAction(_ sender: Any) {
        guard presentedViewController == nil else { return }

        // Keep the handle to preserve the connection and drafts through minimize/reopen.
        // Close releases the current conversation; the handle can open a new one.
        AgentChatUI.show(
            in: self,
            handle: chatHandle,
            title: "Agent Chat"
        )
    }
}

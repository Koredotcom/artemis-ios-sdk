# ArtemisUIExample

This is the native iOS host example corresponding to the Flutter SDK's `example/` app.

The included Xcode project uses CocoaPods. Open `ArtemisUIExample.xcworkspace` after running `pod install`. Do not also add the Artemis Swift package products to this target: doing so loads duplicate SDK classes.

## Swift Package Manager (separate host app)

Create an iOS App target in Xcode, add the package at this repository root with **File → Add Package Dependencies → Add Local…**, and add the `ArtemisUISDK` product to the app target. This package also builds its bundled `ArtemisSocketSDK` target, so a sibling socket checkout is not needed for SwiftPM.

Add `ArtemisUIExampleApp.swift` and `Info.plist` to the target, replace the sample credentials, and run on an iOS 15+ simulator or device.

The example also demonstrates parent-app injection. `ExampleChatHeader` and
`ExampleChatFooter` are passed through `headerBuilder` and `footerBuilder`,
matching the Flutter UI SDK integration pattern.

The example also registers `order_card` in `exampleTemplateRegistry` and passes
it through `templateRegistry`. A matching message can provide
`metadata.template = "order_card"`; the sample template renders its own UI and
submits an action through `RichTemplateContext.submitAction`.

## CocoaPods

From this directory:

```sh
pod install
open ArtemisUIExample.xcworkspace
```

The Podfile links the UI SDK from this repository and `ArtemisSocketSDK` from
the separate sibling repository:

```ruby
pod 'ArtemisSocketSDK', :path => '../../artemis_ios_socket_sdk'
pod 'ArtemisUISDK', :path => '..'
```

Run `pod install` again after updating either checkout. The example retains an
`AgentChatHandle` for minimize/reopen and opts
in to attachments and transferred-agent chat; Runtime branding and permissions
still control whether the attachment button appears.

If switching from Swift Package Manager produces `Unable to find module dependency: CYaml`, remove this example's stale build products from its Derived Data folder, then rebuild the workspace. Old `Yams.swiftmodule`, `ArtemisSocketSDK.swiftmodule`, and `ArtemisUISDK.swiftmodule` files can shadow the CocoaPods frameworks. Do not add a separate CYaml dependency to the CocoaPods target.

## Bundle YAML

`Resources/sdk_configurations.yaml` demonstrates the bundle configuration contract. To use it instead of inline configuration, call:

```swift
AgentChatUI.view(configuration: nil, title: "Agent Chat")
```

Ensure the YAML file is included in the app target's Copy Bundle Resources phase.

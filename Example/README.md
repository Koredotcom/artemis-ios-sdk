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

## Customer session bootstrap

The sample screen follows Android's single **Open chat** action. Authentication
is selected from the configured credentials: a non-empty
`ARTEMIS_SAMPLE_CHANNEL_SECRET` selects hosted bootstrap; otherwise the sample
uses `ARTEMIS_SAMPLE_API_KEY`. The API-key path does not read or require
bootstrap settings. Bootstrap generation is implemented in
`CustomerSessionBootstrapProvider.swift`.

The sample's `CustomerSessionBootstrapProvider` follows the Android sample: it
POSTs to `/api/v1/sdk/customer-sessions`, sends `X-SDK-Channel-Secret`, and
accepts `bootstrapToken` or `token` at the top level or under `data`. It mints
the initial token before opening chat, gives that token to the first iOS SDK
init, and requests a fresh token for every later init or retry. The provider
does not cache minted tokens or log request/response bodies, channel secrets, or
bootstrap tokens.

Set these variables in the Xcode Run scheme's Environment Variables:

| Variable | Purpose |
| --- | --- |
| `ARTEMIS_SAMPLE_API_KEY` | API key used when `ARTEMIS_SAMPLE_CHANNEL_SECRET` is empty. |
| `ARTEMIS_SAMPLE_ENDPOINT` | Runtime base URL; defaults to the sample development endpoint. Bootstrap login also accepts `ws(s)` and converts it to `http(s)`; API-key login requires `http(s)`. |
| `ARTEMIS_SAMPLE_PROJECT_ID` | Project ID, required by either login method. |
| `ARTEMIS_SAMPLE_CHANNEL_ID` | Optional channel ID; used by either method and takes precedence over channel name. Set it empty to use channel name. |
| `ARTEMIS_SAMPLE_CHANNEL_NAME` | Channel name; used when channel ID is empty. |
| `ARTEMIS_SAMPLE_TENANT_ID` | Tenant ID, required only for bootstrap login. |
| `ARTEMIS_SAMPLE_VERIFIED_USER_ID` | Verified customer user ID, required only for bootstrap login. |
| `ARTEMIS_SAMPLE_CUSTOM_ATTRIBUTES_JSON` | Optional JSON object of custom attributes for bootstrap login. |
| `ARTEMIS_SAMPLE_CHANNEL_SECRET` | Optional channel secret; when set, selects bootstrap login and is sent only in the `X-SDK-Channel-Secret` request header. Leave it empty to use API-key login. |

Keep the channel secret in a local, unshared Run scheme. The sample sends it
from the app to Runtime to demonstrate the flow; production apps should call
their own backend so the channel secret is never shipped in the app.

## CocoaPods

From this directory:

```sh
pod install
open ArtemisUIExample.xcworkspace
```

The Podfile links the combined UI/socket SDK from this repository:

```ruby
pod 'ArtemisUISDK', :path => '..'
```

Run `pod install` again after updating the checkout. The example retains an
`AgentChatHandle` for minimize/reopen. Runtime's `attachmentLimits.enabled`
and the session's `attachment:write` permission control whether the attachment
button appears; no local attachment feature flag is required.

If switching from Swift Package Manager produces `Unable to find module dependency: CYaml`, remove this example's stale build products from its Derived Data folder, then rebuild the workspace. Old `Yams.swiftmodule`, `ArtemisSocketSDK.swiftmodule`, and `ArtemisUISDK.swiftmodule` files can shadow the CocoaPods frameworks. Do not add a separate CYaml dependency to the CocoaPods target.

## Bundle YAML

`Resources/sdk_configurations.yaml` demonstrates the bundle configuration contract. To use it instead of inline configuration, call:

```swift
AgentChatUI.view(configuration: nil, title: "Agent Chat")
```

Ensure the YAML file is included in the app target's Copy Bundle Resources phase.

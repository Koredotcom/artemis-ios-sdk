# Artemis Native iOS UI SDK

SwiftUI-based Artemis chat UI SDK for native iOS apps.

## Integration

### Swift Package Manager

Add this package dependency to your app's `Package.swift`, then add the `ArtemisUISDK` product to the app target in Xcode:

```swift
dependencies: [
    .package(
        url: "https://github.com/Koredotcom/artemis-ios-sdk", exact: "1.0.4"
    )
]
```

### UIKit project

Import only `ArtemisUISDK` in the view controller that opens chat. It exposes `SDKConfiguration`, `ConnectionConfig`, and `ChannelConfig` for the parent app:

```swift
import UIKit
import ArtemisUISDK

final class ViewController: UIViewController {
    private let configuration = SDKConfiguration(
        environment: "dev",
        connection: ConnectionConfig(
            projectId: "your-project-id",
            endpoint: "https://runtime.example.com",
            apiKey: "pk_your_public_key"
        ),
        channel: ChannelConfig(channelId: "your-channel-id")
    )

    @IBAction func tapsOnConnectBtnAction(_ sender: Any) {
         // Use the presentation method required by your integration.
        //AgentChatUI.show(in: self, configuration: configuration, title: "Support")
        AgentChatUI.present(from: self, configuration: configuration, title: "Support")
    }
}
```

Connect the action to a button and place the view controller in a `UINavigationController`. For a storyboard app, embed the initial view controller in a navigation controller; the [UIKit example](UIKitExample/ArtemisExample/ArtemisExample/ViewController.swift) wraps its root controller in `SceneDelegate.swift` instead. Replace the placeholder configuration with your project's values.

`show(in:)` pushes chat onto that navigation stack, including a tab's navigation controller. It returns `false` if there is no navigation stack or chat is already on top. The close button pops back to the previous screen. The SDK hides the navigation bar while chat is visible and restores it afterward. The tab bar is hidden by default; pass `hidesBottomBarWhenPushed: false` to keep it visible. `animated` defaults to `true`.

To open chat modally from any UIKit view controller, use:

```swift
AgentChatUI.present(from: self, configuration: configuration, title: "Support")
```

The SDK starts the chat connection when the screen appears and stops it when the screen closes. Use either Swift Package Manager or CocoaPods for a given app target.

To support **minimize and reopen**, retain a handle in the parent app and use the
handle overload. Minimize preserves the connection, draft text, selected files,
form values and survey state. Close releases those resources. The existing
configuration overloads retain their close-on-disappear behavior and show only
Close; the retained-handle overloads also show Minimize.

```swift
private lazy var chatHandle = AgentChatUI.initialize(configuration: configuration)

// Inside the host's button action:
AgentChatUI.show(in: self, handle: chatHandle, title: "Support")
// Modal: AgentChatUI.present(from: self, handle: chatHandle, title: "Support")
// SwiftUI: AgentChatUI.view(handle: chatHandle, title: "Support")
```

Call `chatHandle.close()` when the host no longer needs a minimized conversation.
`chatHandle.endSession()` explicitly ends the Runtime session. Set
`SessionConfig(endSessionOnClose: true)` to end it whenever chat closes.

For a SwiftUI host:

```swift
NavigationStack { AgentChatUI.view(configuration: configuration) }
```

### Host view and template injection

The parent app can replace the header and footer and register message-specific
rich-content renderers. Import `SwiftUI` in the host file. Builders return
`AnyView`, so they can contain any SwiftUI view hierarchy. Add a registry property
to the host view controller or SwiftUI view:

```swift
private var templates: RichTemplateRegistry {
    var registry = RichTemplateRegistry()
    registry.register(RichTemplateRenderer(
        type: "order_card",
        matches: { message in
            (message.metadata?["template"]?.value as? String) == "order_card" ||
            (message.rawRichContent?["template"] as? String) == "order_card"
        },
        build: { message, context in
            AnyView(VStack(alignment: .leading) {
                Text("Order card")
                Button("Confirm") {
                    context.submitAction("confirm-order", "confirmed", nil, message.id)
                }
            })
        }
    ))
    return registry
}
```

Pass the registry and builders from a SwiftUI host:

```swift
NavigationStack {
    AgentChatUI.view(
        configuration: configuration,
        headerBuilder: { header in
            AnyView(HStack {
                Text(header.title)
                Spacer()
                Button("Close", action: header.onClose)
            }.padding())
        },
        footerBuilder: { footer in
            AnyView(HStack {
                TextField(footer.placeholder, text: footer.text)
                    .disabled(!footer.enabled)
                Button("Send", action: footer.onSend).disabled(!footer.canSend)
            }.padding())
        },
        templateRegistry: templates
    )
}
```

In a UIKit view controller, pass the same registry and builders to `show(in:)`
inside the button action:

```swift
AgentChatUI.show(
    in: self,
    configuration: configuration,
    title: "Support",
    headerBuilder: { header in
        AnyView(HStack {
            Text(header.title)
            Spacer()
            Button("Close", action: header.onClose)
        }.padding())
    },
    footerBuilder: { footer in
        AnyView(HStack {
            if let onAttach = footer.onAttach {
                Button("Attach", action: onAttach).disabled(!footer.enabled)
            }
            TextField(footer.placeholder, text: footer.text)
                .disabled(!footer.enabled)
                .onSubmit(footer.onSend)
            Button("Send", action: footer.onSend).disabled(!footer.canSend)
        }.padding())
    },
    templateRegistry: templates
)
```

The `templates` property is the `RichTemplateRegistry` created above. A matching
`order_card` message renders the parent app's view, and its Confirm button sends
an action through `RichTemplateContext`. `AgentChatUI.present` accepts the same
three customization arguments.

### CocoaPods

Add the published pod to the host app's `Podfile`:

```ruby
pod 'ArtemisUISDK', '1.0.4'
```

Then run `pod install` and open the generated `.xcworkspace`.

The bundle configuration form is also supported with `AgentChatUI.view(configuration: nil)` and `sdk_configurations.yaml`. The native UI includes connection status, reconnect, streaming/typing state, Markdown text, carousel cards from `richContent`, auto-scroll, disabled input while offline, and lifecycle cleanup.

### Built-in rich templates

The native SDK parses and renders the following rich-content keys from
message metadata: `image`, `html`, `video`, `audio`, `file`, `list`, `kpi`,
`table`, `chart`, `form`, `progress`, `feedback`, `actions`,
`quick_replies`, channel fallback payloads, and carousel cards. Interactive
templates call the socket SDK's `submitAction`/`submitFeedback` paths.

Quick replies use content-sized tinted pills with optional circular icons and
wrap onto additional rows. Top-level assistant actions appear below the message
bubble, with wrapping outlined buttons, labeled fields, and a filled submit
button. Pending and submitted groups remain locked, with retry available after
a failed submission. These controls support iOS 15 and later.

WhatsApp, Slack, AG-UI, and Adaptive Card payloads use the WebSDK's channel
preview style: a rounded, tinted card with a channel title and a readable
summary. Structured previews collect up to three text fields, capped at 160
characters; payloads without readable text show a localized fallback description.

Host apps can still pass a `RichTemplateRegistry` for custom payloads. Register
a renderer with the same type as a built-in, for example `RichTemplateTypes.kpi`,
to suppress the default renderer and provide an app-specific one.

## Android commit parity

This implementation follows Android commit
[`b63db190f4c837a5e88cc481bb7f8709ef96769f`](https://github.com/Koredotcom/artemis-android-sdk/commit/b63db190f4c837a5e88cc481bb7f8709ef96769f).
It includes the title/status header, retained-handle minimize/reopen lifecycle,
40-point attachment/send controls, a separate rounded multiline composer,
five-file draft strip, file-type icons and expandable sent-file groups. Reading
older messages pauses automatic following; sending or tapping Latest resumes it.

Runtime controls attachment availability. Incoming human-agent text, typing, and
transfer status are handled automatically, matching the WebSDK. Enable optional
contact-center form links and surveys with `enableContactCenter`:

```swift
let configuration = SDKConfiguration(
    environment: "dev",
    connection: ConnectionConfig(
        projectId: "your-project-id",
        endpoint: "https://runtime.example.com",
        apiKey: "pk_your_public_key"
    ),
    channel: ChannelConfig(channelName: "mobile"),
    features: FeaturesConfig(enableContactCenter: true),
    attachments: AttachmentConfig(maxFileSizeBytes: 20 * 1024 * 1024)
)
```

The attachment button uses `attachmentLimits.enabled` from Runtime's SDK
init/refresh response: `true` shows the button and `false` hides it. The session
must also grant `attachment:write`; missing or null attachment limits hide the
button. Local `features.enableAttachments` and theme `attachmentButtonEnabled`
do not control its visibility. Refresh responses that omit `attachmentLimits`
preserve the last received policy. Disabling attachments or revoking permission
cancels uploads and prevents attachment sends;
text chat remains usable. The stock picker filters allowed MIME types. All
staged files, including failed/cancelled files, count toward the five-file limit.
Uploads are sequential, bounded to at most 20 MiB per nonempty file, and have
individual progress, cancel, retry and remove controls. Failed sends retain the
batch and text. Signed download URLs are resolved only when opening a file; a
server-local storage URL uses the authenticated delivery-URL route instead.

Transferred-agent support includes queue/connection notices, plain-text messages,
typing, safe external forms, scoped attachments, failed-delivery indicators and
NPS/CSAT/like-dislike surveys. Survey success requires its matching transfer-survey
acknowledgment; ordinary feedback acknowledgments cannot complete it. Survey
definitions absent from Runtime history still require server event replay after
an offline close. Agent voice/video calls, screen sharing, co-browsing, AI voice,
OAuth cards, omnichannel continuity and outbound calling are outside this commit's
scope. Generic rich feedback supports thumbs and star ratings with retryable
acknowledgment states; unsupported scale/text templates show an availability
message instead of sending an incorrect rating type.

These are local source changes, not a published release. This repository contains
the matching `ArtemisSocketSDK` source under `Sources/ArtemisSocketSDK`. SwiftPM
builds it as a separate product alongside `ArtemisUISDK`. CocoaPods compiles both
source trees into the single `ArtemisUISDK` module. From `Example`, use:

```ruby
pod 'ArtemisUISDK', :path => '..'
```

Run `pod install` after source or podspec changes so the generated project includes
new files. Import only `ArtemisUISDK` in a CocoaPods host; do not add the separate
socket pod to that target. The existing published version numbers have not been
changed here.

The socket layer now supports server-authored user display/redaction, early and
withheld renders, owned cancellation and late-frame suppression, canonical
envelopes/renderables/citations/provenance, occurrence-aware history merging,
restored action locks and policy-controlled activity. Potentially accepted turns,
uploads and surveys are never silently replayed. Hosted bootstrap can use
an asynchronous `bootstrapTokenProvider` closure on `ConnectionConfig`; omit
public-key channel/user selection for hosted bootstrap. Persistent opaque
client-session identity and unlimited transient retries remain opt-in: pass
`clientSessionIdentifier: true` to `ConnectionConfig` and
`unlimitedTransientRetries: true` to `ReconnectionConfig`. Credentials are not cached.

Equivalent YAML additions live under the existing `artemis_sdk` root:

```yaml
features:
  enable_contact_center: true
  enable_history: true
  enable_citations: true
attachments:
  max_file_size_bytes: 20971520
  allowed_mime_types: [application/pdf, text/plain, image/jpeg, image/png]
session:
  idle_disconnect_timeout_ms: 600000
  end_session_on_idle: false
  stale_session_refresh_ms: 0
  end_session_on_close: false
```

`connection` also accepts `client_session_identifier` and `session_metadata`;
`websocket.reconnection` accepts `unlimited_transient_retries`. Token providers
are programmatic only. Existing YAML keys and public initialization methods
remain available. Live Runtime/provider acceptance is separate from the offline
protocol and native UI tests in this repository.

### UI source organization

Each built-in template has its own SwiftUI `View` struct and file under
`Sources/ArtemisUISDK/Templates/`. `RichTemplateViews.swift` selects the templates
for a message, while `Templates/Shared/` contains reusable cards, styles, and
formatting helpers. The default header and message composer live in
`Components/ChatHeaderView.swift` and `Components/ChatFooterView.swift`.
These implementation types are internal; host apps customize the UI through
the existing header/footer builders and `RichTemplateRegistry`.

## Chat presentation features

The stock UI now supports these additions, using the WebSDK chat and template
behavior as the reference:

| Feature | Native behavior |
| --- | --- |
| Ordinary assistant feedback | Opt-in thumbs, an optional negative-feedback comment, acknowledgment-driven status and retry; template feedback is kept separate. |
| Timestamps | Runtime theme settings or host overrides; show/hide, above/below, interaction visibility, locale/12/24-hour time and date formats. Only committed user/assistant messages receive timestamps. |
| Typed forms | Native date/time pickers, number/email/date/time validation, select validation and field-level errors. Date/time values retain `yyyy-MM-dd` / `HH:mm` wire formats. |
| Markdown | Native headings, nested ordered/unordered lists, fenced code, tables, blockquotes, rules, images and inline formatting. Unsafe link schemes are disabled. |
| UI strings | Host overrides and a host-bundle `ArtemisChat.strings` table, selected using the SDK locale configuration. English is the fallback; authored server prompts remain unchanged. |
| Themes | Runtime font family/base size, density, background image and numeric/named bubble radius; template surfaces and text follow the effective theme. |
| Audio | Inline play/pause, seeking, elapsed/duration display and retry. |
| Video | Embedded native controls, seeking and iOS fullscreen presentation. |
| HTML | Allowlisted formatted HTML in a nonpersistent WebKit view, with content scripts, forms, frames and authored CSS disabled. Links open through the host URL action. |
| Thought summaries | Collapsed-by-default cards with accessible expansion and minimize/reopen state retention; existing local and Runtime visibility gates still apply. |

Configure SwiftUI or UIKit presentation with the same options:

```swift
let options = ChatUIOptions(
    enableMessageFeedback: true,
    feedbackCommentMaxLength: 500,
    timestamps: MessageTimestampSettings(
        visibility: .interaction,
        position: .below,
        timeFormat: .twentyFourHour,
        dateFormat: .dayMonthYear
    ),
    strings: ChatStrings(localeIdentifier: "fr", overrides: [
        "Send message": "Envoyer",
        "Reconnect": "Reconnecter",
        "Open {filename}": "Ouvrir {filename}",
        "validation.required": "Ce champ est obligatoire."
    ])
)

// SwiftUI, including the retained-handle overload:
AgentChatUI.view(configuration: configuration, uiOptions: options)
// UIKit:
AgentChatUI.present(from: self, configuration: configuration, uiOptions: options)
```

SwiftUI hosts can also use `.artemisChatOptions(options)` on an existing SDK
view. An explicit `uiOptions` argument takes precedence over that environment
modifier. Omit `timestamps` to use Runtime `messageTimestampEnabled`,
`messageTimestampVisibility`, `messageTimestampPosition`,
`messageTimestampTimeFormat` and `messageTimestampDateFormat` settings.
Interaction visibility responds to a tap/hover and the accessible Show timestamp
action. Locale and timezone formatting follow the SwiftUI environment.

UI string keys are the English source copy; validation keys use the
`validation.*` namespace. String overrides take precedence over the host's
`<locale>.lproj/ArtemisChat.strings`, then its configured fallback locale and
English defaults. Placeholders such as `{filename}`, `{count}` and `{max}` are
replaced without interpreting user content. Translated catalogs are supplied by
the host, as with WebSDK string overrides.

Runtime `theme` also accepts `baseFontSize` (12–32 points), `fontFamily`,
`density` (`compact`, `comfortable`, `spacious`), `backgroundImage`, and
`messageBubbleRadius` (a number or `xs`, `s`, `m`, `l`, `xl`). Media does not
autoplay; players pause on disappearance or app inactivity. URLs must use HTTP(S)
and contain no embedded credentials. HTML formatting uses a restricted native
allowlist rather than arbitrary browser documents; long HTML remains scrollable.
Thought cards do not request extra diagnostics or enable hidden thoughts. A
reasoning-only fallback requires the Runtime `includeReasonFallback` policy.

These changes are local source additions, not a published release. Live feedback
acceptance, remote media playback, and final device presentation still require
validation against the host app and Runtime.

## Build

From this directory run:

```sh
swift test
```

## Example iOS host

Open `Example/ArtemisUIExample.xcworkspace` for the native SwiftUI host after running `pod install` from `Example/`. It demonstrates a one-button launch flow, inline configuration, bundle YAML, themed chat UI, custom font injection, streaming, reconnect, Markdown, typing state, and carousel cards.

The example uses CocoaPods exclusively. Do not also add the SDK through Swift Package Manager to the same target, because that loads duplicate class implementations.

For a UIKit host, open `UIKitExample/ArtemisExample/ArtemisExample.xcodeproj` in Xcode and select the `ArtemisExample` scheme. This project uses the local Swift package. Replace the placeholder project, endpoint, API key, and channel ID in `ViewController.swift`, then run on an iOS 15+ simulator or device. The storyboard's **Connect to Artemis SDK** button calls `tapsOnConnectBtnAction(_:)`, and `SceneDelegate.swift` puts the root view controller in a navigation controller so `show(in:)` can push chat.

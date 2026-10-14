# LoopSDKExample

A minimal SwiftUI host app for kicking the SDK end-to-end against your
local Phoenix backend.

## One-time setup in Xcode

1. **Create the project.** In Xcode 16+, *File → New → Project → iOS App.*
   - Product Name: `LoopSDKExample`
   - Interface: SwiftUI
   - Language: Swift
   - Save it inside this `Examples/` directory so its folder is
     `Examples/LoopSDKExample/`.

2. **Add the local package.** *File → Add Package Dependencies… → Add
   Local…* and pick the repo root (`loop-sdk-ios`). Tick `LoopSDK`.

3. **Replace the generated `LoopSDKExampleApp.swift` and `ContentView.swift`**
   with the files in this directory. They `import LoopSDK`, call
   `LoopSDK.start(apiKey:apiBase:)`, and present `LoopReporterView` from a
   sheet.

4. **Allow plain HTTP for local dev (Info.plist):**
   ```xml
   <key>NSAppTransportSecurity</key>
   <dict>
     <key>NSAllowsArbitraryLoads</key>
     <true/>
   </dict>
   ```
   Remove this before shipping anything to the App Store.

5. **Set the API key.** Open `LoopSDKExampleApp.swift` and replace
   `loop_pk_pebble_REPLACE_ME` with a value from your dashboard (the
   `/setup` page on the Nuxt frontend has a Reveal/Copy button).

## Smoke test

1. `mix phx.server` in the backend repo (port 4000).
2. Run the example app on an iPhone simulator. Tap "Report a bug…".
3. The bug list and feature list should populate from your seeded data.
4. Vote on an item — the count should change and persist after dismiss/re-open.
5. File a new bug — it should appear in the dashboard at
   `http://localhost:3000/bugs` immediately.
6. Quit and re-launch the app — the same `r_xxx…` reporter id should
   render at the bottom of the settings list (Keychain-backed).

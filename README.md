# NilgiriIM

An iPhone and iPad client for [Nilgiri the Forgotten World](https://nilgiri.net), a MUD (multi-user dungeon) that has been running since the 1990s.

NilgiriIM lets you play Nilgiri from your phone like a chat app. You can log in or create a character, play in a scrolling transcript with ANSI colors, and park your character when you leave the app. While it's parked, you get push notifications for tells, whispers, prayers, combat, death, and link loss.

## How it works

The app doesn't talk to the game over telnet directly. It connects over HTTPS to the Nilgiri IM server at `https://nilgiri.net/im`, which keeps your game session alive and sends Apple push notifications. The IM server is part of the game's server code, which is not public.

## Building

- Xcode 15 or later
- iOS / iPadOS 17.0 or later
- Open `NilgiriIM.xcodeproj`, pick your own development team under Signing & Capabilities, and run.

Push notifications only work in builds signed for the official app, because the server's push key belongs to that app ID.

## Source layout

| File | Purpose |
| --- | --- |
| `NilgiriIMApp.swift` | App entry point and lifecycle (park/unlink on background) |
| `LoginView.swift` | Login screen and saved credentials |
| `CharacterCreateView.swift` | New character creation flow |
| `TranscriptView.swift` | Game transcript and input bar |
| `IMSession.swift` | Session with the IM server |
| `Ansi.swift` | ANSI color rendering |
| `PushRegistration.swift` | Push notification registration |
| `SessionSecrets.swift` | Keychain storage for passwords and session tokens |
| `Theme.swift` | Shared colors and translucent bar styling |
| `Models.swift` | Shared data types |

## Reporting problems

Open an issue here for anything about the app. If you're not sure whether a problem is in the app or the game itself, open it here anyway and it will get routed to the right place.

## Playing without the app

You can also connect with any MUD client. See [connect and start](https://nilgiri.net/doku.php?id=nilgiri:connect) on the wiki.

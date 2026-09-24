# Pointer

Pointer is a menu-bar app for showing your screen to a coding assistant. Press the shortcut, say what's wrong, and drag over the part of the screen you mean. Pointer transcribes what you said and pastes the screenshot and the text into the assistant window you used last.

## Screenshot

1. Press **⌃⌥C** from any app.
2. Talk. The HUD at the bottom of the screen shows the live transcript.
3. Drag over the problem. Press Space during the drag to pick a whole window instead.
4. Keep talking if you need to. Pointer sends once you pause (1.8 s after speech, 3 s if you haven't spoken). Press Return or the shortcut to send now, Esc to cancel.

The capture goes to the last terminal, editor or chat app you had focused:

| App | What gets pasted |
|---|---|
| Terminal, iTerm2, Ghostty, Warp, WezTerm, kitty, Alacritty, Hyper, VS Code, Cursor, Windsurf, Zed | The transcript, then the PNG path. Claude Code turns a pasted image path into an image attachment. |
| Claude desktop, ChatGPT | The transcript, then the image itself. |

## Video

Claude can't take a video file, so Pointer turns a recording into what Claude can read: the frames where the screen changed, in order, with what you clicked, what text appeared, and what you said at each point.

1. Press **⌃⌥V**. Pointer starts recording the whole screen your pointer is on.
2. Reproduce the problem and talk through it. Clicks show as circles in the recording.
3. Press **⌃⌥V** again, or click **Stop** on the HUD, to stop. Recordings stop on their own at 2 minutes.

To record part of the screen, choose **Record an area…** in the menu, then drag the area (Esc cancels).

Pointer pastes a few lines of text, then the frames:

```
Screen recording, 9 s, 3 key frames attached in order.
Frame 1 at 0:00. Said: "The country picker opens fine."
Frame 2 at 0:03, after clicking pop-up button "Country" in Google Chrome. New on screen: "Canada"; "Province". Gone: "Select a country". Said: "I pick Canada and save."
Frame 3 at 0:07, after clicking button "Save" in Google Chrome. New on screen: "Changes not saved". Said: "Now it reset."
Video with my voice: …/recording.mov, captions: …/captions.srt
```

- **Frames.** Each frame is compared with the last kept one on a 96×96 grayscale thumbnail split into a 12×12 grid. A cell counts as changed when its pixels move by more than 10 levels on average, so a toast covering 1% of the screen registers while the cursor does not. A change that keeps going for under a second (an animation, a redraw) counts once, at its settled state. 6 frames for recordings up to about 50 s, one more per 8 s after that, up to 12. Frames are saved at up to 2000 px, the most Claude accepts once a conversation holds more than 20 images.
- **Clicks.** Pointer names the button, link or field under each click through the Accessibility API. Keystrokes are never recorded.
- **Text on screen.** Apple's on-device text recognition reads each frame; the paste lists the lines that appeared and disappeared since the frame before.
- **Timing.** Words are placed by the recognizer's own timestamps, which mark when each word was spoken. The recognizer reports words several seconds late, so arrival time would misplace them.

Motion inside a transition (a flicker, a stutter) doesn't survive frame picking; describe it out loud.

## Document

**⌃⌥D** records the front window while you scroll through a document, for docs you can only view: a screen share, a locked viewer, a PDF in a browser. Say what you want from it ("summarize this and list the decisions it asks for"), scroll to the end, and press **⌃⌥D** or **Stop**.

Pointer keeps a page each time most of the visible text is new, reads every page, and joins the text without repeating the overlap between pages. Lines found on two pages give the scroll distance, so a line that was already visible is skipped even if it was read slightly differently the second time. Text that stays put, like a toolbar, is kept once. Claude gets your request, up to 12 page images, and the full text in `document.md` (pasted inline for Claude desktop and ChatGPT). On a synthetic 90-line, 3-section document scrolled over 14 s, it kept 8 pages and recovered all 90 lines in order with no repeats.

## Sharing a recording

Videos include your voice by default (**Record my voice into videos** in the menu). Each recording also gets `captions.srt` and `captions.vtt`, which Teams, Stream and YouTube accept as caption uploads and VLC and IINA load automatically. **Copy last recording** puts the .mov on the clipboard as a file, so ⌘V in Teams, Slack or Mail attaches it; **Show last recording in Finder** reveals it with its captions.

Recordings go to `~/Pictures/Pointer/<time>-video/` (or `-document/`) with the frames, `summary.txt`, `transcript.txt` and the captions.

Pointer does not press Return by default, so you can read the message before it goes. Turn on **Press Return after pasting** in the menu to send it straight away. The menu also pins a specific app as the target, changes the shortcut, and pastes the last capture again.

With Bluetooth headphones as the input, Pointer listens through the Mac's built-in mic instead. Opening a Bluetooth mic switches the headphones into headset mode, which takes a few seconds, drops your first words and lowers the headphones' sound quality. Turn off **Use Mac mic with Bluetooth headphones** in the menu to use the headphones' mic.

Your clipboard is restored after each paste. Screenshots and transcripts are kept in `~/Pictures/Pointer/`.

## Watch mode

**⌃⌥W** starts a silent session: Pointer records the screen at one frame a second with your microphone and the
Mac's own audio, and pastes nothing anywhere. The menu bar shows the elapsed time. **⌃⌥W** again stops it and
writes it up; **Discard this watch session** in the menu throws it away.

Afterwards you get a page with:

- **The write-up**, from `claude -p`: what happened, what you may have missed, follow-ups and key moments, each
  with a timestamp that jumps the video.
- **The transcript**, every line marked **You** or **Others**. Your microphone and the Mac's audio each get their own
  recognizer, so every word is attributed by where it came from.
- **The frames**, each labelled with the app and window you were in.
- **A notification** when it's ready, titled with what you may have missed, and opening the page when clicked.

Recordings run at 4 hours maximum. A silent hour costs a few hundred megabytes. Turn off **Record meeting audio
while watching** in the menu to keep only your own microphone. Teams only warns participants about its own
recording, so tell people when you capture a meeting this way.

Ask about sessions later in Claude Code with `/pointer` (`/pointer ask …`, `/pointer missed`,
`/pointer context`). **Copy for Claude** on any page copies the whole session as text for any conversation.

## Library

Every capture gets a page, and **Open recordings library** in the menu opens `~/Pictures/Pointer/index.html`: the newest capture large at the top, the rest grouped by day, with search over what you said and filters for videos, documents and screenshots.

Every capture gets a title of its own: for watch sessions from the write-up, otherwise from what you said or the
document it came from. **To review** filters the library to captures you haven't marked reviewed yet.

A capture's page has the video on the left with captions, and under it a timeline with each key frame pinned at its moment, click markers and bars where you were talking. On the right, the talk track runs frame by frame: the image, the click that led to it, what text appeared or went, and your words with timestamps. The talk track follows playback; click any frame, line or point on the timeline to jump there, or use ← → to step between frames. **Copy what Claude got** copies the text Pointer pasted.

Pages are static HTML with their data inside, so they open from Finder with no server. Rebuilding the library re-renders every page from its `session.json`, so template changes reach older captures; captures from before pages existed get a `session.json` rebuilt from their files.

## Permissions

Pointer asks for four on first launch:

| Permission | Why |
|---|---|
| Microphone | Hearing you |
| Screen Recording | The region screenshot (`/usr/sbin/screencapture -i`) |
| Accessibility | Bringing the assistant forward, pressing ⌘V, and naming what you click in a recording |

Screen Recording only takes effect after a relaunch: **Permissions → Relaunch Pointer** in the menu. Without Accessibility, Pointer copies the capture to the clipboard and you paste it yourself.

## Build

```sh
./build.sh              # build, install to ~/Applications/Pointer.app, launch
./build.sh --no-launch  # build and install only
```

Requires Xcode command line tools and macOS 26 or later (SpeechAnalyzer for on-device transcription). The speech model for your language downloads on first launch. The first build creates a self-signed signing identity in `.signing/` (its own keychain, not your login keychain). Signing with a fixed identity keeps macOS permissions valid across rebuilds; an ad-hoc signature changes on every build and silently invalidates Accessibility and Screen Recording.

Debug flags on the binary (`~/Applications/Pointer.app/Contents/MacOS/Pointer`):

- `--render-hud out.png` renders the HUD states for design checks.
- `--keyframes video.mov out-dir/` runs frame selection on any video and prints the text that appeared per frame.
- `--document-pages video.mov out-dir/` runs document mode's page picking and text joining on any video.
- `--build-library` rebuilds every page and the library and prints its path.
- `--summary-demo` prints the pasted text for a made-up 3-frame recording.
- `--describe-point x y` names the element at a screen point, the way the click log does.
- `--self-test out.txt` (launch with `open -n -W ~/Applications/Pointer.app --args --self-test out.txt` so it runs with Pointer's permissions) checks speech recognition on a generated file, then records 6 s of the top-left of the main screen with the mic while `say` speaks, and prints the audio track count, captions, text read from the frame and the pasted text. Add `window` after the output path to test recording the front window the way document mode does.

Pointer logs each capture to `~/Library/Logs/Pointer.log`.

## Files

| File | Role |
|---|---|
| `Sources/AppDelegate.swift` | Menu bar item, menu, shortcut, permissions |
| `Sources/CaptureSession.swift` | One screenshot capture: listen, select, wait for the pause, deliver |
| `Sources/VideoSession.swift` | One video or document capture: record, pick frames or pages, build the pasted text, deliver |
| `Sources/RegionPicker.swift` | The dimmed drag-to-select overlay for Record an area |
| `Sources/ScreenRecorder.swift` | ScreenCaptureKit recording of a screen area or one window, with the mic, leaving Pointer's windows out |
| `Sources/KeyFrames.swift` | Picks the frames where the screen changed, and the pages of a scrolled document |
| `Sources/ScreenText.swift` | Reads text off frames with Apple's Vision framework |
| `Sources/ClickLog.swift` | Records clicks and names the element under each one |
| `Sources/Captions.swift` | SRT and VTT captions from the timed transcript |
| `Sources/WatchSession.swift` | Watch mode: the silent session, its transcript, frames and write-up |
| `Sources/AudioMixer.swift` | Lines mic and Mac audio up on one 16 kHz timeline and hands each side to its own recognizer |
| `Sources/SpeechStream.swift` | Hours-long transcription, rotating the recognizer request every few minutes |
| `Sources/Digest.swift` | Runs `claude -p` over a session to write it up |
| `Sources/Notifier.swift` | Pointer's own notifications |
| `Sources/Viewer.swift` | Writes each capture's page and the library, and rebuilds pages for older captures |
| `Viewer/session.html`, `Viewer/library.html` | The page templates, copied into the app bundle at build time |
| `Sources/Analyzer.swift` | On-device speech recognition (SpeechAnalyzer) with per-word timing; several run at once |
| `Sources/Transcriber.swift` | Microphone (AVCaptureSession) into an `Analyzer` |
| `Sources/SpeechStream.swift` | One long-running `Analyzer` per audio source for watch mode |
| `Sources/ScreenTranscript.swift` | Writes `screen.txt`: the OCR'd text of every key frame and screenshot |
| `mcp/server.js` | MCP server: search and read captures and Cuecard meeting notes |
| `Sources/Delivery.swift` | Target tracking, focusing the target, clipboard and ⌘V |
| `Sources/HUD.swift` | The floating status pill |
| `Sources/HotKey.swift` | Global shortcuts through Carbon |
| `Sources/Mark.swift` | The mark (selection corners, speech tail, dot), shared by menu bar, HUD and icon |
| `Tools/icon/main.swift` | Renders the app icon |

The idea comes from Capi (trycapi.com), an unreleased product. Pointer is a personal rebuild under its own name.

## Listen and ask

**⌃⌥Q** starts a watch session for when you're listening to learn: a recorded talk, a webinar, a meeting you're sitting in on. It records like watch mode (⌃⌥W), and every 30 seconds, once enough new speech has come in, asks Claude for the one question worth taking away from what was just said. The question shows in the HUD for 12 seconds (unless another capture is using it). The write-up adds "Questions that came up" and "To look up", each with timestamps. Press ⌃⌥Q again to stop; the write-up finishes in the background.

## After the write-up

`defaults write com.vaibhav.pointer afterWriteUp "/path/to/script"` runs that command with the session folder once a watch or listen write-up is saved.

## Screen text and the MCP server

Each watch and video capture writes `screen.txt`: every line OCR'd off each key frame (minus the macOS menu bar), under a `## [m:ss] frame-N.png · app` header. `Pointer --screen-text-backfill` writes it for older captures.

`mcp/server.js` is a zero-dependency MCP server over `~/Pictures/Pointer` and Cuecard's meeting notes in `~/Documents/Cuecard`, with `pointer_list`, `pointer_search` (said / screen / write-up) and `pointer_get`. `pointer_get` returns the write-up and a timeline that interleaves what was said with what was on screen, so a moment can be reconstructed from text. Register it with `claude mcp add -s user pointer -- node <path>/mcp/server.js`.

Screenshots get the same treatment: `<stamp>.screen.txt` next to each `<stamp>.png`.

While a watch session is being written up, the HUD stays on "Processing the session…" and the library shows a Processing card that refreshes itself. The recorder waits up to 2 min for a long recording to finalize.

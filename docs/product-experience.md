# Recording experience improvements

> **Note:** the iPhone app no longer uses S3 or the Gateway. Mentions of pairing, LAN discovery, backups and live captions below describe the earlier design.

## Product direction

The core journey is start recording, confirm sound is being captured, finish locally,
and find useful content later. Cloud backup and live transcription are independent,
optional services. Their failures must not masquerade as microphone failures or block
the next recording after local finalization succeeds.

## Interaction design

- Idle home: one clear recording action, a recent completion card, recent recordings,
  and a searchable complete library.
- Active recording: elapsed time, actual input level and route, explicit interruption
  feedback, optional live text, and persistent pause/finish controls.
- Saved recording: editable title, playback and readable transcript first; file metadata
  and retranscription are secondary. Scrolling never seeks audio. Manual reading suspends
  playback following until the user explicitly resumes it.
- Separate capture, local file, cloud backup, and transcription status. Never announce
  a completed save before recording starts, or a live connection based on saved credentials.
- System-adaptive appearance, scalable typography, semantic state colors, named controls,
  and text in addition to color. English and Simplified Chinese share behavior.
- Service setup keeps local recording usable without configuration. Advanced fields are
  disclosed on demand; pairing is reviewed and validated before credentials are persisted.

## Independently delegated tasks

| Task | Priority | Scope |
| --- | --- | --- |
| Capture feedback | P0 | Actual audio level, input route, silence and interruption feedback |
| Background sync | P0 | New recording allowed after local finalization with cloud queue intact |
| Recording library | P0 | All recordings, persistent titles, title and transcript search |
| Accurate status | P0 | Independent, truthful capture/storage/transcription labels |
| Transcript navigation | P0 | Reading never changes playback; explicit resume following |
| Completion feedback | P1 | Saved card with rename, review, share actions |
| Content organization | P1 | Bookmarks, speaker aliases, transcript copy/export |
| Service setup | P1 | Advanced disclosure, reviewed QR/paste pairing, validation feedback |
| Recording focus | P1 | Idle/active hierarchy and persistent recording controls |
| Detail hierarchy | P1 | Playback and transcript first, secondary technical metadata |
| Adaptive appearance | P1 | System theme, scalable layout and accessible controls |

All eleven tasks were implemented by separate `gpt-5.6-sol` agents using `medium`
reasoning. Integration also preserves queued backups when cloud storage is disabled,
checks recorded upload destinations, prevents concurrent title edits from overwriting
backup metadata, and refuses to replace unreadable annotation data with an empty file.

## Verification setup

The simulator experience tests opt in with `WAKEONCUE_EXPERIENCE_FIXTURES=1`. This
DEBUG-only simulator path uses a separate `ExperienceTestData` directory containing
generated tones and text, not the user's recordings. The offline-backup case uses
`ExperienceOfflineTestData` and a deliberately unreachable loopback endpoint with dummy
credentials. Production builds contain neither fixture path nor configuration override.

The fixture library contains twelve recordings; only the oldest transcript mentions
`Orchid`, so searching it exercises navigation beyond the eight home rows. A separate
unit test searches past twenty records and verifies missing/unreadable transcript reporting.

To replay on an available simulator:

```sh
cd ios
xcodegen generate
xcodebuild -project WakeOnCue.xcodeproj -scheme WakeOnCue \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:WakeOnCueTests \
  -only-testing:WakeOnCueUITests/ProductExperienceUITests test
```

Run simulator tests serially; simultaneous test runners installing the same app can
terminate each other's sessions. Simulator tests use Xcode's default ad-hoc signing.

## Executed verification (2026-09-12)

- Core package: 26/26 tests passed, including persisted titles, pagination, concurrent
  metadata preservation and independence of finalized backup queues from active capture.
- iOS application: 40/40 unit tests passed, covering status evidence, input meter,
  transcript following, annotations, search and pairing validation.
- Product experience UI: all seven scenarios passed across the main run and targeted
  replays on iPhone 17 Pro / iOS 26.5 Simulator. Coverage includes older-transcript search,
  rename persistence, idle status, consecutive recordings, unavailable-cloud recovery,
  independent transcript reading, and Chinese accessibility text.
- Pairing generator: 4/4 Python tests passed.
- Visually inspected Chinese home in light and dark appearance and at the largest
  accessibility text size. The accessibility header now places its subtitle on a
  separate row and keeps the brand name intact; the primary recording action remains
  reachable. The large-text UI scenario passed again after this adjustment.
- The initial UI run exposed an accessibility identifier inherited from the transcript
  container by its inset button. Moving the identifier to the ScrollView preserved the
  button's own identifier; the playback/reading scenario then passed on replay.

These are 77 distinct passing tests across separate runs, not a claim that every test
in the repository or every device scenario was executed. Xcode build and signing passed
as part of the simulator tests. Evidence is available locally in
`/tmp/wakeoncue-final-core.log`, `/tmp/wakeoncue-product-final-1.xcresult`,
`/tmp/wakeoncue-product-transcript-verified.xcresult`, and
`/tmp/wakeoncue-product-large-text-verified.xcresult`.

## Acceptance boundaries

Automated fixtures can verify navigation, persistence and playback behavior; they do not
prove physical microphone quality, real interruptions, locked-device recording, camera
scanning or real remote service connectivity. Those physical-device and remote-service
checks remain unrun; generated tones and an unavailable loopback service do not substitute
for them.

## Library upkeep (2026-11-02)

- Deleting moves a recording to Recently Deleted for 30 days; its files stay until it is
  permanently deleted, by the user or on the first launch after the period ends. Copies
  already in a legacy S3 bucket are not removed, and the screen says so. Recordings still
  being captured or finished cannot be deleted, and a recording being transcribed or
  summarized cannot be permanently deleted until that ends.
- Very short recordings (under 10 s) offer Discard on the completion card.
- A summary's title and overview are stored as separate metadata. A user or calendar title
  always wins; clearing a user title falls back to the summary's. Earlier summaries are
  picked up at launch.
- When transcription or summaries cannot run, the detail page says why and opens Settings.
  Lists and the completion card show when a recording is being processed.

Not done: storage usage, low-storage warnings, and a notification when processing ends.

## Competitive roadmap (2026-10-29)

Compared against Auday (Watch-first life journal: health signals, daily AI reflection,
bring-your-own AI key) and AideMemo (private "second memory": many capture devices,
journal timeline with map and records, Apple Speech / Apple Intelligence / own models,
opt-in speaker diarization with remembered voices). WakeOnCue's position: realtime,
work conversations turned into follow-ups, open source and self-hostable.

Done in this round:

- Speaker diarization modeled on AideMemo: off by default; anonymous Speaker 1/2;
  per-recording names or a contact; the user's own enrolled voice shown as Me; opt-in
  Remember voices that keeps named people's voiceprints on the iPhone only, deletes
  voices not heard for a year, and deletes all when turned off.
- Places: finish recording on arrival or departure automatically; on arrival at a
  "start" place, a time-sensitive notification starts recording with one tap, because
  iOS does not let an app open the microphone from the background. A Shortcuts Arrive
  automation running Start Meeting Recording is documented for a fully automatic start.
- iOS 26+: free on-device transcription with SpeechAnalyzer when no realtime transcript
  exists, and an on-device Apple Intelligence summary (title, overview, key points,
  follow-ups) for every transcript; AirPods high-quality recording; importing audio
  files from Files.
- Calendar-driven recording, off by default: with full calendar access, a recording
  started during a meeting (or up to 10 minutes before it) takes the event's title,
  identifier and attendee names, and the detail page shows the linked meeting. An
  optional time-sensitive reminder at the start (or 1, 5 or 10 minutes before) has a
  Start Recording action; recording never starts without that tap. Reminders are
  rescheduled on launch, on becoming active and on calendar changes, capped at 32
  pending notifications (iOS allows 64). Users can limit which calendars count and
  require other attendees or a video link. After the meeting, "Send notes to
  attendees" builds plain text from the title, date and on-device summary and opens
  Mail with the attendees' addresses (or the share sheet); the user reviews and sends.
  Place and calendar notifications share one notification router.

Not done yet:

| Item | Priority | Notes |
| --- | --- | --- |
| Delete the last minutes | P0 | Must silence the source CAF, replace or delete 10 s chunks, drop transcript segments and remove already-uploaded S3 objects; touches the capture and upload core, so it gets its own change. |
| Live on-device captions | P0 | Feed SpeechAnalyzer from the capture buffers for realtime text without a Mac. |
| Mac menu-bar app | P1 | Shipped v1: hosts the existing Gateway and Processor, pairing QR, two-channel meeting capture. Next: bundle Python so no setup is needed; verify capture permissions and real meeting audio. |
| Answers with citations and self-hosted MCP | P1 | Shipped v1: on-device Ask screen with timestamped sources that seek playback; read-only MCP on the Gateway (`docs/mcp.md`). Next: sync edited titles and summaries to S3. |
| Daily timeline page | Later | One long page per day with recordings, summaries and AI-generated illustrations; not in the first version. |
| Location history | Not planned | Places are used only as triggers, not recorded as a history. |

Unverified on device: place notifications and background relaunch, Shortcuts Arrive
automation, AirPods high-quality input, on-device transcription quality and summary
quality, remembered-voice matching with real voices, meeting reminders firing and their
Start Recording action from the lock screen, Mail compose with attendee addresses.

# Duette hands-on test

Three days on one Mac, in order. Each step says what to do, what you should see, and what to send back if it doesn't happen. Steps 1.1 to 1.8 build on each other, so if one of them fails, stop there, send what it asks for and wait for a fix, because a failure further down is usually a failure further up. From 1.9 on the steps stand on their own: if one fails, send what it asks for, write it down and carry on with the next one.

This file is attached to every Duette release. It matches the app as built, so the names in quotes are what is on screen.

## What you need

- An Apple Silicon Mac on macOS 15 or newer, and an admin password for it.
- Headphones. Use them for every step, or the speakers will pick up your own voice.
- Discord with a second person to call (a friend, or your second account on a phone).
- OBS if the Mac has it. QuickTime Player comes with macOS and is enough for every step, but OBS is what step 2.1 is really about, so use it there if you can.
- Optional: a USB or Bluetooth microphone (step 2.4), and Terminal (steps 1.4 and 2.11).
- A notes file open next to you. Write the step number and what happened for anything odd, even if the step passed.

Download `Duette-<version>[-test-<sha>].pkg` and `TESTING.md` from the release page: https://github.com/Roboroads/Duette/releases (a test build has the `-test-<sha>` part in its name, a normal release doesn't).

## When something fails

1. Do this right after the failure, before you quit Duette or restart anything. In the menu bar, click the Duette icon, then "Export Diagnostics…". It takes up to a minute. Save the zip on the Desktop.
2. Send the zip and the step number (for example "1.7").
3. Add one line on what you saw instead. A screenshot helps.

The zip only holds the last 30 minutes of the log and the last 60 seconds of meter readings. One exported hours later, or at the end of the day, shows your versions and devices but not what went wrong.

If the app won't open at all, there is no menu to export from. Run this in Terminal instead and send the zip it puts on the Desktop:

```sh
sudo "/Library/Application Support/Duette/duette-diagnose.sh"
```

Each step below says what else to send, if anything.

## UI checks nobody has done yet

The app has been built and unit tested in CI, but nobody has looked at these on a real screen. They are part of the steps below. Note anything that looks wrong, even if the function works: cut-off text, a missing icon, a word you wouldn't understand without having built the app.

| Check | Step |
|---|---|
| Menu layout | 1.3 |
| App icons in the picker | 1.3 |
| First-run guide | 1.2, and the early-close and refusal paths in 3.4 |
| Save dialog for the diagnostics zip | 1.9 |
| "Open Login Items" button | 2.7 |
| Reopen window | 2.8 |
| Menu bar warning badge | 2.9 |
| Both Settings buttons ("Open Settings" and "Open Microphone Settings") | 2.10 |

## Not bugs

These are on purpose. Don't report them.

- The level bar of a source keeps moving when that source is muted. The bars read before the mute and the volume.
- "Mute" and the sliders only change what goes into "Duette". What you hear in your headphones never changes.
- The two test tones (driver and engine) sound the same. They are both 440 Hz. What differs is the path they take.
- There is a gap of a fraction of a second when Duette rebuilds: when the app starts or stops helper processes (Discord joining or leaving a call), when you change the app, the microphone or the buffer size, when a mic is plugged in or out, and after sleep.
- "Duette Sink" is not in the Output list in Sound settings. It is hidden on purpose. Only "Duette" should show up, under Input.
- Duette has no Dock icon. It lives in the menu bar.
- One app at a time. 48 kHz stereo only.

## Day 1: it installs and the sound path works

About 45 minutes. Each step adds one piece, so a failure points at that piece:

| Step | What is in the path | If it fails, suspect |
|---|---|---|
| 1.4 | the driver only | the audio driver ("Duette" in Sound settings) |
| 1.5 | app, hidden sink, driver | the app handing audio to the driver |
| 1.6 | plus your microphone | the microphone side |
| 1.7 | plus the sound of another app | the app-sound side and its permission |
| 1.8 | everything together | the mix |

### 1.1 Install

**Do**

1. Double-click `Duette-<version>[-test-<sha>].pkg`.
2. If macOS says it can't open it or can't check it for malware (this happens with test builds that are not notarized): close the message. Open System Settings, then Privacy & Security, scroll down to the message about the pkg and click "Open Anyway". Confirm with your password. Then open the pkg again.
3. Click through the installer. There are no choices to make. Enter your password when it asks.

**Expect**

- A release build opens with no warning at all.
- The installer shows "Welcome to Duette" and ends on "Duette is installed".
- Anything that is playing pauses for a second or two while the audio system restarts.
- A Duette icon (a circle with a sound wave) appears in the menu bar, and a window called "Welcome to Duette" opens.
- Click the Duette icon, then "About Duette". Write down the version and build in your notes.

**If it fails**

Send the step number and a screenshot of any warning. If there is no icon and no window, open Duette from the Applications folder. If still nothing, run `duette-diagnose.sh` (see "When something fails") and send the zip.

### 1.2 First-run guide

This is the window that opened at the end of 1.1. Go through it slowly and read each screen as if you had never seen the app.

**Do**

1. Screen 1, "Welcome to Duette". Click "Get started".
2. Screen 2, "Let Duette use your microphone". Click "Allow microphone". macOS asks for access to the microphone and shows "Duette mixes your microphone into the Duette input." Allow it (the button reads OK or Allow).
3. Screen 3, "Let Duette hear Discord" (or "Let Duette hear your app" if Discord isn't installed). Click "Continue". If Discord is running and playing sound, macOS may ask now whether Duette may record the sound of other apps. If it asks, choose Allow. If it doesn't ask, that is fine: it asks when the app first plays sound (step 1.7).
4. Screen 4, "Now pick “Duette” as the microphone in OBS or Zoom". Leave the switch "Open Duette when I log in" off for now. Click "Done".

**Expect**

- One big button per screen.
- On screen 2 after you allow it, a green "Microphone allowed" and the button now reads "Continue".
- "Back" works on screens 2 to 4 and doesn't exist on screen 1.
- The words are plain. Write down any word you would not understand without having built the app.
- If Discord is installed, "Sound from Discord" is already chosen in the menu afterwards. The microphone is "System default". Every volume is 100%. Nothing is muted.

**If it fails**

Send the diagnostics zip, the step number, and which screen you were on. If the macOS permission question never appeared, say so and say which screen you were on.

### 1.3 Menu tour

**Do**

Click the Duette icon in the menu bar. Look at everything, top to bottom. Open the app picker (the popup under "Sound from ...").

**Expect**

- At the top, a coloured dot and one sentence. Green means "Working: other apps can use Duette as a microphone". Orange with "Waiting for Discord to start" is also fine if Discord isn't running. See the list at the end of this file for every sentence.
- Three rows, each with a name, a volume slider with its percentage, a "Mute" button and a level bar: "Sound from Discord" (or "Sound from an app"), "Your microphone" and "What other apps hear". The first two have a popup to choose from.
- A switch "Open Duette when I log in".
- "For experts", closed, with an arrow.
- Under a line: "Export Diagnostics…", "Show the welcome guide", "About Duette", "Quit Duette".
- Nothing is cut off, nothing overlaps, and the buttons are big enough to hit without care.
- In the app picker: every app you have open, each with its real icon (not a dashed square), apps that are playing sound listed first, then the rest in alphabetical order. The last entry, below a line, is "No app, only my microphone". Duette itself is not in the list. If Discord is chosen but not running, it shows first as "Discord (not running)".
- The microphone popup starts with "System default" and then lists your microphones. "Duette" is not in it.

**If it fails**

Send the diagnostics zip, the step number, and a screenshot of the menu.

### 1.4 The driver alone

This checks the audio driver with the app out of the picture.

**Do**

1. Open System Settings, then Sound. Look at the Input list, then at the Output list.
2. Open QuickTime Player, then File, then New Audio Recording. Click the small arrow next to the red record button and choose "Duette" as the Microphone. macOS may ask whether QuickTime may use the microphone. Allow it.
3. In the Duette menu, open "For experts" and switch on "Play test tone (driver)".
4. Click record, wait 5 seconds, stop, and play it back.
5. Switch "Play test tone (driver)" off again.

**Expect**

- "Duette" is in the Input list. "Duette Sink" is not in the Output list. ("Duette Sink" is an output device, so the Output list is where it would show up if it weren't hidden.)
- The recording is a steady, fairly quiet beep, and the QuickTime level meter moves while recording.

**Optional second opinion in Terminal**

```sh
"/Library/Application Support/Duette/duettectl" list
```

It prints one line per check. Expect `CHECK PASS list.duette.listed` and `CHECK PASS list.sink.hidden`, and a last line that ends in `0 failed`.

**If it fails**

Send the diagnostics zip and the step number. Also say whether "Duette" is in the Input list and whether "Duette Sink" is in the Output list, and send the Terminal output if you ran it. If "Duette" isn't in the list at all, the driver did not load: that's a bigger failure than a missing beep, say so. If this is not your first install, say what was on the Mac before.

### 1.5 App, sink and driver

This checks the path from the Duette app to "Duette". Step 1.4 must have passed.

**Do**

1. In the app row, open the popup and choose "No app, only my microphone", so the sound of another app is not part of this test.
2. In the Duette menu, under "For experts", switch on "Play test tone (engine)".
3. Record "Duette" in QuickTime for 5 seconds and play it back.
4. Switch the engine tone off again.

**Expect**

- The same kind of beep as in 1.4. It sounds identical on purpose.
- The status line at the top is not red.

**If it fails**

Send the diagnostics zip and the step number. Say what the status line said, word for word.

### 1.6 Your microphone

**Do**

1. The app row should still say "No app, only my microphone" from 1.5. If not, choose it.
2. Leave the microphone on "System default", or choose a microphone you want to test.
3. Record "Duette" in QuickTime and talk for 5 seconds. Play it back.
4. Click "Mute" in the "Your microphone" row (it turns into "Muted"). Record and talk again.
5. Unmute. Drag the slider to about 50%, then to 200%, and record a short bit at each.
6. Set the slider back to 100%.

**Expect**

- Your voice in the first recording. The "Your microphone" bar and the "What other apps hear" bar move while you talk.
- A silent recording while muted. The "Your microphone" bar still moves (see "Not bugs"). The "What other apps hear" bar stays empty.
- Quieter at 50%, louder at 200%. Loud speech at 200% may distort. That is the hard limit at full scale.
- The status line is green: "Working: other apps can use Duette as a microphone".

**If it fails**

Send the diagnostics zip and the step number. Say which microphone you chose.

### 1.7 Sound of another app

**Do**

1. Start something that plays sound: Music, or a YouTube tab in Safari. Keep it playing.
2. In the Duette menu, open the app popup and pick that app. It should be near the top because it is playing sound.
3. Click "Mute" in the "Your microphone" row, so only the app is in the mix.
4. If macOS asks whether Duette may record the sound of other apps, choose Allow.
5. Record "Duette" in QuickTime for 10 seconds and play it back.
6. Move the app's slider to about 50%, record a bit. Then click "Mute" in the app row and record again.

**Expect**

- The music is in the recording, and you hear it in your headphones the whole time.
- The "Sound from ..." bar moves.
- 50% is quieter in the recording. While muted, the recording is silent but you still hear the music in your headphones.
- The status line is green.

If the recording is silent and the status line turns red with "Duette needs permission to hear ..." and a button "Open Settings", the permission was refused or never asked. That is step 2.10 happening early. Click "Open Settings", switch Duette on as described there, and carry on.

**If it fails**

Send the diagnostics zip and the step number. Say which app you picked and whether the permission question appeared at all, and when.

### 1.8 The mix

**Do**

1. Click "Muted" in the microphone row to unmute it.
2. With the music playing, record "Duette" in QuickTime while you talk over it, for 15 seconds. Play it back.
3. Move each slider while recording and see whether the recording follows. Move the "What other apps hear" slider too.

**Expect**

- Music and your voice together, with no echo between them and no crackle.
- All three level bars move.
- Each slider changes its own part of the recording. The "What other apps hear" slider changes everything.

**If it fails**

Send the diagnostics zip and the step number, and the recording if you can.

### 1.9 Export Diagnostics and the Save dialog

You will use this every day, so look at it properly.

**Do**

1. Click the Duette icon, then "Export Diagnostics…".
2. When the Save window appears, first click Cancel. Then do it again and click Save.
3. Open the zip and look at what is in it.

**Expect**

- While it works, the menu shows "Collecting the details…" with a small spinner.
- A Save window titled "Save the Duette details" with the text "Save this file, then send it to whoever is helping you." It opens on the Desktop, and the file name is `Duette-Diagnostics-` followed by the date and time, ending in `.zip`.
- No extra macOS question about the Desktop folder.
- After Cancel, nothing is saved and the menu goes back to normal.
- After Save, Finder opens with the file selected, and the menu says "Saved. Send that file to whoever is helping you." with a "Show in Finder" button.
- The zip holds one folder with four files: `diagnostics.json`, `app.log`, `system.log` and `signatures.txt`.

**If it fails**

Send the step number and what the menu said. If it says "Duette couldn't put the details together. Please try again." or "Duette couldn't save the file there. Please choose another place.", send that sentence and try again with a different folder.

**End of day 1**

Keep the zip from this step and send it with your notes, even if everything passed. It is a snapshot of versions, devices, permissions and settings on a working setup, not a record of a failure. Quit Duette from the menu ("Quit Duette") or leave it running, whichever you like.

## Day 2: the real call, recovery and edge cases

About 90 minutes. Start with Duette running and Discord signed in.

### 2.1 The Discord call

This is the one the whole app exists for. If it works, the rest is polish.

**Do**

1. Join a Discord voice channel with a second person.
2. In the Duette menu, choose "Discord" in the app popup. Pick your real microphone in the "Your microphone" popup. Unmute everything. All three sliders at 100%.
3. Leave Discord's own input device on your real microphone. Do not choose "Duette" in Discord.
4. In OBS, add a source "Audio Input Capture" and choose "Duette" as its device (or use QuickTime again, with "Duette" as the microphone).
5. Record for at least one minute while you and the other person talk, sometimes at the same time.
6. Play the recording back.

**Expect**

- You hear the other person in your headphones for the whole call.
- The recording has both of you. The other person sounds as they did live, and your voice is in step with theirs. No echo and no delay between the two.
- The other person hears you normally, and does not hear themselves.
- The status line is green. The "Sound from Discord" bar moves when they talk, and the "Your microphone" bar moves when you do.
- No orange banner and no dot on the menu bar icon, even though OBS or QuickTime is reading "Duette". That would be a false alarm.
- macOS may ask for permission to record Discord's sound the first time. Choose Allow.

**If it fails**

Send the diagnostics zip right away, while the call is still on, and the step number. Say what part of the call was missing from the recording (you, them, both), and send the recording if you can.

### 2.2 Latency numbers

**Do**

1. Open "For experts". Write down "Estimated delay: about N ms" and "Missed deadlines".
2. Run "Measure latency". <!-- S9: verify wording -->
3. Write down the number it shows, and the buffer size it was measured at (128 frames by default). <!-- S9: verify wording -->

**Expect**

- An estimated delay of roughly 10 to 12 ms at 128 frames, and a measured figure within 1 ms of it. Under 20 ms is the goal. <!-- S9: verify wording -->
- "Missed deadlines" is 0.

**If it fails**

Send the diagnostics zip and the step number. A bigger number is not a failure of the test, it is a result: send it.

### 2.3 Discord restart

**Do**

1. With the call going and "Discord" chosen, quit Discord completely (Discord menu, then Quit).
2. Watch the Duette menu. Keep recording "Duette" in QuickTime while you speak.
3. Reopen Discord and rejoin the call. Don't touch Duette.

**Expect**

- Within a few seconds the status line turns orange: "Waiting for Discord to start". The app popup still shows Discord, as "Discord (not running)".
- Your voice keeps being recorded the whole time.
- After Discord is back and you rejoin, the status line turns green by itself and the other person's voice is back in the recording within a few seconds.

**If it fails**

Send the diagnostics zip and the step number. Say what the status line said and for how long, and whether it needed a click on "Try again".

### 2.4 Microphone unplugged

Skip this if you have no USB or Bluetooth microphone. Write "skipped" in your notes.

**Do**

1. Plug in the microphone. In the "Your microphone" popup choose it by name (not "System default").
2. Record "Duette" while you speak into it. Then unplug it (or switch off the Bluetooth one) while the other person is talking.
3. Open the Duette menu and look at the popup. Wait 10 seconds.
4. Plug it back in.

**Expect**

- While it is out, the status line says "Your microphone isn't connected" (orange) and the popup shows "Your microphone (not connected)". The other person's sound keeps being recorded.
- After you plug it in, the status line goes green by itself, within a few seconds, and your voice is back in the recording. No click needed.

**If it fails**

Send the diagnostics zip and the step number, with the make and model of the microphone.

### 2.5 Sleep

**Do**

1. With the call going and the status line green, close the lid or choose Sleep from the Apple menu. Wait 30 seconds.
2. Wake the Mac. Don't touch Duette.
3. After the status line is green again, start a new recording of "Duette" in QuickTime and speak.

**Expect**

- Within a few seconds of waking, the status line is green again.
- A new recording has your voice. (QuickTime's old recording may have stopped by itself. That is QuickTime.)
- If the call dropped, rejoin it. Discord does that, not Duette.

**If it fails**

Send the diagnostics zip and the step number. Say how long the status line stayed orange or red after waking.

### 2.6 Buffer sizes

**Do**

1. In the call with a recording running, open "For experts". Next to "Buffer size", choose "64 frames". Talk for 30 seconds. Note the "Missed deadlines" count.
2. Do the same at "256 frames" and "512 frames".
3. End on "128 frames".
4. Run "Measure latency" at 64 and at 256 frames. <!-- S9: verify wording -->

**Expect**

- Each change takes a moment, then audio is back by itself. The recording is clean at every size. A busy Mac may crackle at 64 frames. If it does, write that down. It decides whether 128 stays the default.
- "Estimated delay" gets bigger with the buffer size.
- "Missed deadlines" stays 0, or close to it.

**If it fails**

Send the diagnostics zip and the step number, with the size that failed and what it did (crackle, silence, status line).

### 2.7 Launch at login

**Do**

1. Make the settings easy to recognise: app Discord, your real microphone, app volume 80%, microphone volume 120%, buffer size 256 frames.
2. In the Duette menu, switch on "Open Duette when I log in".
3. If the switch is followed by "Your Mac needs your OK first. Switch Duette on in Login Items." click "Open Login Items", switch Duette on in the list that opens, and come back.
4. Log out and log in again (Apple menu, then Log Out).
5. In System Settings, then General, then Login Items & Extensions, switch Duette off. Open the Duette menu. Switch it back on.

**Expect**

- After logging in, the Duette icon is in the menu bar without you opening anything, and no guide window.
- The same app, microphone, volumes and buffer size as before.
- After step 5, the switch in the menu shows what System Settings says (off after you turned it off there), because Duette reads it each time.
- If the switch gives "Duette couldn't change this. You can also do it in System Settings > General > Login Items.", try the Login Items way yourself, and send the zip. An unsigned test build may be the cause. On macOS 15 that System Settings page is called "Login Items & Extensions", so the app's message and its "Open Login Items" button use an older name for it.

**If it fails**

Send the diagnostics zip and the step number, and say which part didn't come back.

**End of this step**

Set "128 frames" again. Leave "Open Duette when I log in" on. You'll check it again on day 3.

### 2.8 Reopen window

The menu bar icon can be hidden behind the notch or in a full menu bar. Opening Duette again should still get you to the controls.

**Do**

1. With Duette running, open it again from the Applications folder or Spotlight.
2. Close the window with the red button.
3. In Terminal, run `open -n /Applications/Duette.app`. This starts a second copy.
4. In the Duette menu, click "Show the welcome guide". Close it again with the red button.

**Expect**

- A window called "Duette" with the heading "Duette is running in the menu bar" and the text "Look for the Duette icon at the top of your screen. If you can't see it, the menu bar may be full. You can use everything here too." Under it, the same controls as the menu.
- After step 3, the second copy quits again at once and the window from step 1 comes back. There is still one icon in the menu bar and one Duette in Activity Monitor.
- Step 4 opens the guide at screen 1. Closing it changes nothing and the app keeps working.

**If it fails**

Send the diagnostics zip and the step number, and how many Duette icons or processes you saw.

### 2.9 Feedback loop warning

If an app that is mixed into Duette also records "Duette", its callers hear themselves. Duette warns, and leaves the audio alone.

Tell the other person first: they will hear themselves for a moment. Keep it short.

**Do**

1. In the Duette menu, "Discord" is the chosen app. In Discord, open User Settings, then Voice & Video. Set Input Device to "Duette". Either join a voice channel or use the microphone test there.
2. Look at the menu bar icon, then open the Duette menu.
3. Set Discord's Input Device back to your real microphone.

**Expect**

- After a second or two the menu bar icon gets an orange dot.
- In the menu, an orange banner: "Discord is using Duette as its input: callers will hear themselves", with the line "In Discord, choose your real microphone instead of “Duette”."
- After step 3 the dot and the banner go away.

**If it fails**

Send the diagnostics zip and the step number. Say how Discord was set, and whether the other person heard themselves.

### 2.10 Permission denial and the Settings buttons

**Part A: sound of other apps**

**Do**

1. Open System Settings, then Privacy & Security, then "Screen & System Audio Recording". Scroll to "System Audio Recording Only" and switch Duette off.
2. Quit Duette ("Quit Duette" in its menu) and open it again from Applications. Make sure Discord is playing sound (the other person talks, or play a sound in Discord).
3. Wait 5 seconds and open the Duette menu.
4. Click "Open Settings".
5. Switch Duette on again and watch the menu.

**Expect**

- The status line turns red: "Duette needs permission to hear Discord", with a button "Open Settings" and underneath it: "Scroll down to System Audio Recording Only and switch on Duette".
- Your microphone keeps working: a recording of "Duette" still has your voice.
- "Open Settings" opens Privacy & Security on the Screen & System Audio Recording page.
- After you switch Duette on again, the red line goes away and the other person's sound is back within a few seconds. If it doesn't, quit and reopen Duette, and note that you had to.

**Part B: microphone**

**Do**

1. In System Settings, Privacy & Security, then Microphone, switch Duette off.
2. Open the Duette menu.
3. Click "Open Microphone Settings".
4. Switch Duette on again. Open the Duette menu again. Record "Duette" and speak.

**Expect**

- The status line turns red: "Duette needs permission to use your microphone", with a button "Open Microphone Settings".
- Sound from Discord keeps being recorded while the microphone is off.
- The button opens Privacy & Security on the Microphone page.
- After you switch it on again, the menu goes green and your voice is back in the recording. If macOS says Duette must quit and reopen, do that and write it down.

**If it fails**

Send the diagnostics zip and the step number (2.10A or 2.10B). Say whether the status line text matched the quoted one.

### 2.11 Ten-minute soak

<!-- S9: verify wording -->

This runs the engine for ten minutes in Terminal and checks the sound the whole time. It finds the slow failures: a dropout after five minutes, a creeping delay. If this build has no soak mode that works on a Mac like this one, use the fallback below.

**Do**

1. Quit Duette from its menu. The test builds its own engine, and two engines at once would confuse the result.
2. Close the other heavy apps. Keep the Mac awake and plugged in.
3. In Terminal:

```sh
"/Library/Application Support/Duette/duettectl" soak --minutes 10
```

<!-- S9: verify wording -->

4. When it finishes, run `echo $?`.
5. Open Duette again from Applications.

**Expect**

- macOS may ask whether Terminal may use the microphone. Choose OK and run the command again.
- It prints progress for ten minutes, then check lines, with no `FAIL`. The last line ends in `0 failed`, and `echo $?` prints `0`. <!-- S9: verify wording -->
- If it prints `SKIP test-devices` and stops straight away, this build's soak can't run on a Mac without test devices. Send that output.

**If it fails**

Send the whole Terminal output (select all, copy, paste into a text file), the step number, and the diagnostics zip from Duette after you open it again.

**Fallback: a 30-minute call**

Use this when the command above isn't in this build, or prints `SKIP`.

1. Open Duette and "For experts". Write down "Missed deadlines" (call it A).
2. Join a Discord call with "Discord" chosen in Duette, and record "Duette" in OBS or QuickTime the whole time. Keep the Mac awake and plugged in. Talk now and then, and use the Mac as you normally would.
3. After 30 minutes, write down "Missed deadlines" again (call it B), and play the recording back, skimming through it.

Expect B to be the same as A, no dropouts or crackle in the recording, and a green status line the whole time. If B is higher, export diagnostics straight away, and send it with A, B and what you were doing.

### 2.12 End of day 2

**Do**

1. Open "For experts" and write down "Missed deadlines" after the day's use.
2. Export Diagnostics and keep the zip. Like the one from day 1, it is a snapshot of versions, devices and settings, not a record of a failure.
3. Shut the Mac down (Apple menu, then Shut Down), not sleep. You'll start day 3 from a cold boot.

**Send**

The zip and your notes.

## Day 3: retest, cold start, clean slate, uninstall

### 3.1 Cold start

**Do**

Start the Mac and log in. Don't open Duette. Don't open Discord for a minute.

**Expect**

- The Duette icon is in the menu bar within a few seconds, without a welcome guide.
- Your day 2 settings are still there.
- The status line is green, or orange with "Waiting for Discord to start" if the app is Discord and it isn't open yet. It turns green when you open Discord.
- System Settings, then Sound, then Input lists "Duette".

**If it fails**

Send the diagnostics zip and the step number, and say how you started Duette if it wasn't there.

### 3.2 Install the fixed build and retest

Skip this if there is no new build. If there is one, you'll have a new `Duette-<version>[-test-<sha>].pkg` and a list of failed steps.

**Do**

1. Install the new pkg over the old one. No uninstall first. Follow 1.1 (the "Open Anyway" part applies again for an unsigned build).
2. Check "About Duette" shows the new version. Write it down.
3. Repeat each step that failed, in order. Fill in this table in your notes:

| Step | Failed on | Now | Notes |
|---|---|---|---|
| | | | |

**Expect**

- Duette quits and comes back by itself during the install. Your settings are kept.
- The steps that failed now pass. Every step that passed before still passes.

**If it fails**

Send the zip for the step that still fails, and the step number.

### 3.3 The call, once more

**Do**

Repeat 2.1 for five minutes with the newest build.

**Expect**

The same as 2.1.

**If it fails**

Send the diagnostics zip and the step number.

### 3.4 Clean slate

This runs the first-run paths a second time, and the ones step 1.2 couldn't cover: closing the guide early, and refusing the microphone.

**Do**

1. Quit Duette from its menu.
2. In Terminal:

```sh
defaults delete me.roboroads.duette
tccutil reset All me.roboroads.duette
```

3. Open Duette from Applications.
4. On screen 1 click "Get started". On screen 2 close the window with the red button.
5. Open the Duette menu. Click "Continue setup".
6. On screen 2 click "Allow microphone" and this time choose Don't Allow in macOS's question.
7. Click "Open Microphone Settings", switch Duette on, and go back to the guide.
8. Finish the guide.

**Expect**

- Step 4: the menu says "Duette needs a few more steps before it can start" with a big "Continue setup" button. Step 5 opens the guide again at screen 1.
- Step 6: the screen says "Duette can't use your microphone yet. You can switch it on in System Settings." and has two buttons, "Open Microphone Settings" and "Continue without it". The big button is now also "Open Microphone Settings".
- Step 7: when you come back to the guide, it shows "Microphone allowed" and the button reads "Continue" without any clicking.
- After step 8, the app is "Discord" if it's installed, the microphone is "System default", every volume is 100% and nothing is muted, the same as at the start of day 1.

**If it fails**

Send the diagnostics zip and the step number. Say which line in this list didn't happen.

### 3.5 Uninstall

**Do**

1. Open Terminal and run:

```sh
sudo "/Library/Application Support/Duette/uninstall.sh"
```

2. Check System Settings, then Sound, then Input, the Applications folder, the menu bar, and System Settings, then General, then Login Items & Extensions.
3. Optional: download `uninstall.sh` from the release page and run it with `sudo bash ~/Downloads/uninstall.sh`.

**Expect**

- It asks for your password if you didn't use `sudo`. It prints `Removed /Applications/Duette.app`, `Removed /Library/Audio/Plug-Ins/HAL/Duette.driver`, `Removed /Library/Application Support/Duette`, `Forgot installer receipt me.roboroads.duette.pkg`, `Restarting the audio system.` and ends with `Duette is removed.`
- Audio pauses for a moment.
- The Duette icon is gone from the menu bar, "Duette" is gone from Sound settings, and there is no Duette in Applications. Write down whether Duette is still listed under Login Items & Extensions.
- The second run, from the downloaded copy, prints `Not installed:` for each path and ends with `Duette is removed.` Your Duette preferences stay on the Mac on purpose.

**If it fails**

Send the whole Terminal output and the step number. If Duette is still in Sound settings, run `duette-diagnose.sh` before restarting, if the script is still there. Otherwise restart the Mac and look again.

### 3.6 Send everything back

- The zips you made right after failures, if there were any.
- The snapshot zips from the end of day 1, the end of day 2 and after step 3.3.
- Your notes, with the table from 3.2.
- Which Mac it was (the model is in the zip) and which macOS.
- The version from "About Duette".
- The latency numbers from 2.2 and 2.6, and the "Missed deadlines" numbers.

## The status line

The sentence at the top of the menu, from first to last as it is checked:

| Colour | Sentence | Button |
|---|---|---|
| Orange | Duette needs a few more steps before it can start | Continue setup |
| Red | Duette isn't installed properly. Please run the Duette installer again. | none |
| Red | Something went wrong. Duette is trying again. | Try again |
| Red | Duette needs permission to use your microphone | Open Microphone Settings |
| Orange | Duette needs to ask for your microphone | Allow microphone |
| Red | Duette needs permission to hear (app) | Open Settings |
| Orange | Waiting for (app) to start | none |
| Orange | Duette can't hear (app) yet | Try again |
| Orange | Your microphone isn't connected | none |
| Green | Working: other apps can use Duette as a microphone | none |
| Grey | Duette is paused | none |

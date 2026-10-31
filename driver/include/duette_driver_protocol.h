/*
 * What the Duette HAL plug-in (Duette.driver) publishes to its clients: device UIDs and names,
 * and the custom properties on the "Duette" device. The app (DuetteKit) and duettectl mirror
 * these values. Plain C with no includes, so Swift and C++ can both import it.
 *
 * Change a value here only together with every client that reads it.
 */
#ifndef DUETTE_DRIVER_PROTOCOL_H
#define DUETTE_DRIVER_PROTOCOL_H

/* ---- Plug-in bundle ------------------------------------------------------------------------ */

#define DUETTE_DRIVER_BUNDLE_ID   "me.roboroads.duette.driver"
#define DUETTE_DRIVER_BUNDLE_NAME "Duette.driver"
#define DUETTE_DRIVER_MANUFACTURER "Duette"

/* ---- Devices ------------------------------------------------------------------------------- */

/* "Duette": visible, input only, 2 ch float32 at 48 kHz. Plays back what the sink receives. */
#define DUETTE_DEVICE_UID  "me.roboroads.duette.device"
#define DUETTE_DEVICE_NAME "Duette"

/* "Duette Sink": hidden, output only, 2 ch float32 at 48 kHz, cannot be a default device.
 * The app's private aggregate writes the mix here. Find it with
 * kAudioHardwarePropertyTranslateUIDToDevice: hidden devices are not in the device list. */
#define DUETTE_SINK_UID  "me.roboroads.duette.sink"
#define DUETTE_SINK_NAME "Duette Sink"

/* Both devices run on one clock: the same zero timestamps, ZeroTimeStampPeriod and
 * kAudioDevicePropertyClockDomain (this value). */
#define DUETTE_CLOCK_DOMAIN 0x44756574u /* 'Duet' */

#define DUETTE_SAMPLE_RATE    48000
#define DUETTE_CHANNEL_COUNT  2

/* Test devices. They exist only in CI builds made with -DDUETTE_TEST_DEVICES=ON; a shipped
 * plug-in never has them. */
#define DUETTE_TEST_MIC_UID      "me.roboroads.duette.test-mic"
#define DUETTE_TEST_MIC_NAME     "Duette Test Mic"     /* input, 1 kHz tone, clock +200 ppm */
#define DUETTE_TEST_MIC_TONE_HZ  1000
#define DUETTE_TEST_MIC_CLOCK_PPM 200
#define DUETTE_TEST_SPEAKER_UID  "me.roboroads.duette.test-speaker"
#define DUETTE_TEST_SPEAKER_NAME "Duette Test Speaker" /* output, 48000 or 44100 Hz, discards */

/* ---- Custom properties on "Duette" ----------------------------------------------------------
 *
 * Scope kAudioObjectPropertyScopeGlobal, element kAudioObjectPropertyElementMain. Both are listed
 * in kAudioObjectPropertyCustomPropertyInfoList as kAudioServerPlugInCustomPropertyDataTypeCFPropertyList:
 * coreaudiod marshals a plug-in's custom properties only as CFString or CFPropertyList, so the
 * values travel as CF objects, not as raw integers. (Checked in CI: a raw UInt32 property left
 * out of that list reads as kAudioHardwareUnknownPropertyError from a client.)
 *
 * Reading one: pass a CFPropertyListRef (size sizeof(CFPropertyListRef)) to
 * AudioObjectGetPropertyData. You own the returned object and must CFRelease it.
 * Writing one: pass a pointer to a CFPropertyListRef holding the value, with the same size.
 */

/* Self-test tone. Value: CFNumber, 0 = off (the default), 1 = on. Settable, not persisted.
 * While on, "Duette" plays a 440 Hz sine at -12 dBFS on both channels instead of the sink's
 * audio. A CFBoolean is accepted when setting. The plug-in sends a property-changed
 * notification when the value changes. */
#define DUETTE_PROPERTY_SELF_TEST_TONE 0x64747374u /* 'dtst' */
#define DUETTE_SELF_TEST_TONE_HZ       440
#define DUETTE_SELF_TEST_TONE_DBFS     (-12)

/* Input clients. Value: CFArray of CFNumber (pid_t as SInt32), sorted ascending, no
 * duplicates: the processes currently doing input IO (between StartIO and StopIO) on "Duette".
 * Read-only. The plug-in sends a property-changed notification whenever the set changes, so
 * add a listener instead of polling. */
#define DUETTE_PROPERTY_INPUT_CLIENTS 0x64636c69u /* 'dcli' */

#endif /* DUETTE_DRIVER_PROTOCOL_H */

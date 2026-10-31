/* Compiles the protocol header as strict C99 (it is imported from Swift and C) and checks that
 * the FourCC constants spell what their comments say. */
#include "duette_driver_protocol.h"
#include "duette_driver_protocol.h" /* include guard */

#define FOURCC(a, b, c, d) \
  (((unsigned)(a) << 24) | ((unsigned)(b) << 16) | ((unsigned)(c) << 8) | (unsigned)(d))

typedef char check_dtst[(DUETTE_PROPERTY_SELF_TEST_TONE == FOURCC('d', 't', 's', 't')) ? 1 : -1];
typedef char check_dcli[(DUETTE_PROPERTY_INPUT_CLIENTS == FOURCC('d', 'c', 'l', 'i')) ? 1 : -1];
typedef char check_clock[(DUETTE_CLOCK_DOMAIN == FOURCC('D', 'u', 'e', 't')) ? 1 : -1];

const char* duette_protocol_strings[] = {
    DUETTE_DRIVER_BUNDLE_ID, DUETTE_DEVICE_UID,       DUETTE_DEVICE_NAME,
    DUETTE_SINK_UID,         DUETTE_SINK_NAME,        DUETTE_TEST_MIC_UID,
    DUETTE_TEST_MIC_NAME,    DUETTE_TEST_SPEAKER_UID, DUETTE_TEST_SPEAKER_NAME,
};

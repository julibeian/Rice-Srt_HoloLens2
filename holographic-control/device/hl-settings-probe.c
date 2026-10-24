/* Opens only the public For developers settings URI. Does not select any
 * control, change a setting, request a pairing PIN, or access credentials. */
#define HL_FIXED_DEVELOPER_SETTINGS
#define hl_uri_entry settings_probe_entry
#include "../../capture-app/device-research/hl-uri-launch.c"

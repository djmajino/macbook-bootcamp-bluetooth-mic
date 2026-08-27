/*
 * Static endpoint list for the experimental HFP-only adapter.
 *
 * The Microsoft SysVAD adapter normally exposes several simulated speakers
 * and microphones.  This project deliberately exposes none of them.  The
 * only endpoints are registered dynamically by BthhfpDevice.cpp when a real
 * GUID_DEVINTERFACE_BLUETOOTH_HFP_SCO_HCIBYPASS interface arrives.
 */

#ifndef _BTH_HFP_AUDIO_MINIPAIRS_H_
#define _BTH_HFP_AUDIO_MINIPAIRS_H_

static PENDPOINT_MINIPAIR g_RenderEndpoints[1] = { nullptr };
static PENDPOINT_MINIPAIR g_CaptureEndpoints[1] = { nullptr };

// Keep these as runtime values. A literal zero makes the sample's unsigned
// loop comparison trigger C4296 when warnings are treated as errors.
static ULONG g_cRenderEndpoints = 0;
static ULONG g_cCaptureEndpoints = 0;

#define g_MaxMiniports ((g_cRenderEndpoints + g_cCaptureEndpoints) * 2)

#endif // _BTH_HFP_AUDIO_MINIPAIRS_H_

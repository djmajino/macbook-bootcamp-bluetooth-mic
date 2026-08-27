# Architecture

Boot Camp's Broadcom Bluetooth stack can establish an HFP control connection,
but on the supported Mac it requests vendor PCM sideband routing for SCO audio.
That physical PCM route is not exposed to the Windows audio engine.

`UartH4Probe` is a KMDF upper filter on the exact Intel Serial IO UART used by
Bluetooth on `MacBookPro16,1`. When an HFP WaveRT stream starts, it rewrites
only the next Enhanced Setup Synchronous Connection command so that input and
output use HCI routing. It removes incoming H4 SCO packets before the original
serial bus driver parses them, stores their PCM payload in a bounded capture
ring and sends paced outgoing SCO packets from a bounded render ring. Other H4
traffic is forwarded unchanged.

`BthHfpAudio` is a PortCls/WaveRT driver derived from Microsoft SysVAD. It
discovers Windows HFP HCI-bypass interfaces and creates speaker and microphone
endpoints dynamically. Its kernel-only bridge connects those WaveRT buffers to
the two rings exported by `UartH4Probe`.

The implementation accepts mono 16-bit CVSD-style 8 kHz and mSBC-style 16 kHz
endpoint formats. Bluetooth pairing, codec negotiation, A2DP and HFP control
remain the responsibility of the existing Microsoft/Broadcom stack.

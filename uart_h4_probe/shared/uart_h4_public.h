#pragma once

#ifdef _KERNEL_MODE
#include <ntddk.h>
#else
#include <windows.h>
#include <winioctl.h>
#endif

#define UART_H4_PROBE_STATE_VERSION 5UL
#define UART_H4_PROBE_MAX_ENTRIES 128UL
#define UART_H4_PROBE_PAYLOAD_BYTES 64UL
#define UART_H4_PROBE_LAST_SCO_PAYLOAD_BYTES 255UL

#define IOCTL_UART_H4_PROBE_GET_STATE \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x820, METHOD_BUFFERED, FILE_READ_DATA)
#define IOCTL_UART_H4_PROBE_ARM_HCI_ROUTE \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x821, METHOD_BUFFERED, FILE_WRITE_DATA)
#define IOCTL_UART_H4_PROBE_READ_SCO_PCM \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x822, METHOD_OUT_DIRECT, FILE_READ_DATA)
#define IOCTL_UART_H4_PROBE_GET_AUDIO_INTERFACE \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x823, METHOD_BUFFERED, FILE_READ_DATA)

#ifdef _KERNEL_MODE
#define UART_H4_AUDIO_INTERFACE_VERSION 1UL

typedef VOID (*PFN_UART_H4_AUDIO_REFERENCE)(_In_ PVOID Context);
typedef NTSTATUS (*PFN_UART_H4_AUDIO_STREAM_OPEN)(_In_ PVOID Context);
typedef VOID (*PFN_UART_H4_AUDIO_STREAM_OPEN_COMPLETE)(_In_ PVOID Context);
typedef VOID (*PFN_UART_H4_AUDIO_STREAM_CLOSE)(_In_ PVOID Context);
typedef ULONG (*PFN_UART_H4_AUDIO_READ_CAPTURE)(
    _In_ PVOID Context,
    _Out_writes_bytes_(Length) UCHAR *Buffer,
    _In_ ULONG Length);
typedef ULONG (*PFN_UART_H4_AUDIO_QUEUE_RENDER)(
    _In_ PVOID Context,
    _In_reads_bytes_(Length) const UCHAR *Buffer,
    _In_ ULONG Length);

typedef struct _UART_H4_AUDIO_INTERFACE {
    ULONG Version;
    ULONG Size;
    PVOID Context;
    PFN_UART_H4_AUDIO_REFERENCE Reference;
    PFN_UART_H4_AUDIO_REFERENCE Dereference;
    PFN_UART_H4_AUDIO_STREAM_OPEN StreamOpen;
    PFN_UART_H4_AUDIO_STREAM_OPEN_COMPLETE StreamOpenComplete;
    PFN_UART_H4_AUDIO_STREAM_CLOSE StreamClose;
    PFN_UART_H4_AUDIO_READ_CAPTURE ReadCapture;
    PFN_UART_H4_AUDIO_QUEUE_RENDER QueueRender;
} UART_H4_AUDIO_INTERFACE, *PUART_H4_AUDIO_INTERFACE;
#endif

typedef struct _UART_H4_PROBE_ROUTE_ARM {
    ULONG Version;
    ULONG Size;
    ULONG RewriteCount;
} UART_H4_PROBE_ROUTE_ARM, *PUART_H4_PROBE_ROUTE_ARM;

typedef enum _UART_H4_PROBE_DIRECTION {
    UartH4ProbeRead = 1,
    UartH4ProbeWrite = 2
} UART_H4_PROBE_DIRECTION;

typedef struct _UART_H4_PROBE_ENTRY {
    ULONGLONG Timestamp100ns;
    ULONG Sequence;
    ULONG Direction;
    ULONG RequestedLength;
    ULONG CompletedLength;
    LONG Status;
    ULONG PayloadLength;
    UCHAR Payload[UART_H4_PROBE_PAYLOAD_BYTES];
} UART_H4_PROBE_ENTRY, *PUART_H4_PROBE_ENTRY;

typedef struct _UART_H4_PROBE_STATE {
    ULONG Version;
    ULONG Size;
    ULONG EntryCount;
    ULONG TotalEntries;
    ULONGLONG ReadRequests;
    ULONGLONG ReadBytes;
    ULONGLONG WriteRequests;
    ULONGLONG WriteBytes;
    ULONGLONG FirstByteCommand;
    ULONGLONG FirstByteAcl;
    ULONGLONG FirstByteSco;
    ULONGLONG FirstByteEvent;
    ULONGLONG FirstByteOther;
    ULONG ArmedHciRouteRewrites;
    ULONG RewrittenEnhancedSyncCommands;
    ULONG LastOriginalInputDataPath;
    ULONG LastOriginalOutputDataPath;
    ULONG LastOriginalInputTransportUnitSize;
    ULONG LastOriginalOutputTransportUnitSize;
    ULONG ScoSiphonEnabled;
    ULONG ScoSiphonBusy;
    ULONGLONG SiphonedScoPackets;
    ULONGLONG SiphonedScoPayloadBytes;
    ULONGLONG SiphonedScoNonzeroBytes;
    ULONG LastScoHandle;
    ULONG LastScoPacketStatus;
    ULONG LastScoPayloadLength;
    ULONG ScoCaptureRingAvailable;
    ULONGLONG ScoCaptureRingDroppedBytes;
    ULONG AudioInterfaceClients;
    ULONG ScoRenderRingAvailable;
    ULONGLONG ScoRenderRingDroppedBytes;
    ULONGLONG ScoRenderUnderrunBytes;
    ULONGLONG SentScoPackets;
    ULONGLONG SentScoPayloadBytes;
    ULONGLONG FailedScoWrites;
    UCHAR LastScoPayload[UART_H4_PROBE_LAST_SCO_PAYLOAD_BYTES];
    UART_H4_PROBE_ENTRY Entries[UART_H4_PROBE_MAX_ENTRIES];
} UART_H4_PROBE_STATE, *PUART_H4_PROBE_STATE;

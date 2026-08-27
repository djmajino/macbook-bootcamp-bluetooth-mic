#pragma once

#include <ntddk.h>
#include <wdf.h>

#include "..\shared\uart_h4_public.h"

#define UART_H4_PROBE_NT_DEVICE_NAME L"\\Device\\UartH4Probe"
#define UART_H4_PROBE_DOS_DEVICE_NAME L"\\DosDevices\\UartH4Probe"

typedef enum _UART_H4_SIPHON_STAGE {
    UartH4SiphonHeader = 1,
    UartH4SiphonPayload = 2,
    UartH4SiphonNextType = 3
} UART_H4_SIPHON_STAGE;

typedef struct _UART_H4_DEVICE_CONTEXT {
    WDFREQUEST OriginalReadRequest;
    WDFREQUEST InternalReadRequest;
    WDFMEMORY InternalReadMemory;
    BOOLEAN InternalReadUsed;
    WDFREQUEST InternalWriteRequest;
    WDFMEMORY InternalWriteMemory;
    BOOLEAN InternalWriteUsed;
    volatile LONG InternalWriteBusy;
    UART_H4_SIPHON_STAGE SiphonStage;
    ULONG StageExpected;
    ULONG StageCompleted;
    UCHAR SiphonBuffer[3 + UART_H4_PROBE_LAST_SCO_PAYLOAD_BYTES];
    UCHAR ScoWriteBuffer[4 + UART_H4_PROBE_LAST_SCO_PAYLOAD_BYTES];
} UART_H4_DEVICE_CONTEXT, *PUART_H4_DEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(UART_H4_DEVICE_CONTEXT, UartH4GetDeviceContext);

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD UartH4ProbeEvtDeviceAdd;
EVT_WDF_IO_QUEUE_IO_READ UartH4ProbeEvtIoRead;
EVT_WDF_IO_QUEUE_IO_WRITE UartH4ProbeEvtIoWrite;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL UartH4ProbeEvtIoDeviceControl;
EVT_WDF_IO_QUEUE_IO_INTERNAL_DEVICE_CONTROL UartH4ProbeEvtIoInternalDeviceControl;
EVT_WDF_REQUEST_COMPLETION_ROUTINE UartH4ProbeReadCompletion;
EVT_WDF_REQUEST_COMPLETION_ROUTINE UartH4ProbeInternalReadCompletion;
EVT_WDF_REQUEST_COMPLETION_ROUTINE UartH4ProbeInternalWriteCompletion;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL UartH4ProbeEvtControlDeviceControl;
EVT_WDF_OBJECT_CONTEXT_CLEANUP UartH4ProbeEvtDeviceContextCleanup;

NTSTATUS
UartH4ProbeCreateControlDevice(
    _In_ WDFDRIVER Driver
    );

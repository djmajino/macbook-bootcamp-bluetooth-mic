#include "uart_h4_probe.h"

static WDFSPINLOCK g_StateLock;
static UART_H4_PROBE_STATE g_State;
static ULONG g_NextEntry;
static WDFDEVICE g_FilterDevice;
#define UART_H4_SCO_CAPTURE_RING_BYTES (256UL * 1024UL)
static UCHAR g_ScoCaptureRing[UART_H4_SCO_CAPTURE_RING_BYTES];
static ULONG g_ScoCaptureRead;
static ULONG g_ScoCaptureWrite;
static ULONG g_ScoCaptureCount;
#define UART_H4_SCO_RENDER_RING_BYTES (256UL * 1024UL)
static UCHAR g_ScoRenderRing[UART_H4_SCO_RENDER_RING_BYTES];
static ULONG g_ScoRenderRead;
static ULONG g_ScoRenderWrite;
static ULONG g_ScoRenderCount;

static
VOID
UartH4ProbeMaybeRewriteSynchronousDataPath(
    _Inout_updates_bytes_(PayloadLength) UCHAR *Payload,
    _In_ ULONG PayloadLength
    )
{
    ULONG inputPathIndex;
    BOOLEAN rewrite;

    if (Payload == NULL || PayloadLength < 4 ||
        Payload[0] != 0x01 || Payload[2] != 0x04) {
        return;
    }

    if (Payload[1] == 0x3D && Payload[3] == 0x3B && PayloadLength >= 63) {
        inputPathIndex = 54;
    } else if (Payload[1] == 0x3E && Payload[3] == 0x3F && PayloadLength >= 67) {
        inputPathIndex = 58;
    } else {
        return;
    }

    rewrite = FALSE;
    WdfSpinLockAcquire(g_StateLock);
    if (g_State.ArmedHciRouteRewrites != 0) {
        --g_State.ArmedHciRouteRewrites;
        ++g_State.RewrittenEnhancedSyncCommands;
        g_State.ScoSiphonEnabled = 1;
        g_State.LastOriginalInputDataPath = Payload[inputPathIndex];
        g_State.LastOriginalOutputDataPath = Payload[inputPathIndex + 1];
        g_State.LastOriginalInputTransportUnitSize = Payload[inputPathIndex + 2];
        g_State.LastOriginalOutputTransportUnitSize = Payload[inputPathIndex + 3];
        rewrite = TRUE;
    }
    WdfSpinLockRelease(g_StateLock);

    if (rewrite) {
        Payload[inputPathIndex] = 0x00;
        Payload[inputPathIndex + 1] = 0x00;
        Payload[inputPathIndex + 2] = 0x00;
        Payload[inputPathIndex + 3] = 0x00;
    }
}

#ifdef ALLOC_PRAGMA
#pragma alloc_text(INIT, DriverEntry)
#pragma alloc_text(PAGE, UartH4ProbeEvtDeviceAdd)
#endif

static
VOID
UartH4ProbeCountFirstByte(
    _In_ UCHAR Value
    )
{
    switch (Value) {
    case 0x01:
        ++g_State.FirstByteCommand;
        break;
    case 0x02:
        ++g_State.FirstByteAcl;
        break;
    case 0x03:
        ++g_State.FirstByteSco;
        break;
    case 0x04:
        ++g_State.FirstByteEvent;
        break;
    default:
        ++g_State.FirstByteOther;
        break;
    }
}

static
VOID
UartH4ProbeRecord(
    _In_ ULONG Direction,
    _In_ ULONG RequestedLength,
    _In_ ULONG CompletedLength,
    _In_ NTSTATUS Status,
    _In_reads_bytes_opt_(PayloadLength) const UCHAR *Payload,
    _In_ ULONG PayloadLength
    )
{
    PUART_H4_PROBE_ENTRY entry;
    ULONG copyLength;

    WdfSpinLockAcquire(g_StateLock);

    entry = &g_State.Entries[g_NextEntry];
    RtlZeroMemory(entry, sizeof(*entry));
    entry->Timestamp100ns = KeQueryInterruptTime();
    entry->Sequence = ++g_State.TotalEntries;
    entry->Direction = Direction;
    entry->RequestedLength = RequestedLength;
    entry->CompletedLength = CompletedLength;
    entry->Status = Status;
    copyLength = min(PayloadLength, (ULONG)sizeof(entry->Payload));
    entry->PayloadLength = copyLength;
    if (Payload != NULL && copyLength != 0) {
        RtlCopyMemory(entry->Payload, Payload, copyLength);
        UartH4ProbeCountFirstByte(Payload[0]);
    }

    if (Direction == UartH4ProbeRead) {
        ++g_State.ReadRequests;
        g_State.ReadBytes += CompletedLength;
    } else {
        ++g_State.WriteRequests;
        g_State.WriteBytes += CompletedLength;
    }

    g_NextEntry = (g_NextEntry + 1) % UART_H4_PROBE_MAX_ENTRIES;
    if (g_State.EntryCount < UART_H4_PROBE_MAX_ENTRIES) {
        ++g_State.EntryCount;
    }

    WdfSpinLockRelease(g_StateLock);
}

static
VOID
UartH4ProbeCompleteStateRequest(
    _In_ WDFREQUEST Request
    )
{
    PUART_H4_PROBE_STATE output;
    ULONG index;
    ULONG firstIndex;
    NTSTATUS status;

    status = WdfRequestRetrieveOutputBuffer(
        Request,
        sizeof(UART_H4_PROBE_STATE),
        (PVOID *)&output,
        NULL);
    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(Request, status);
        return;
    }

    WdfSpinLockAcquire(g_StateLock);
    *output = g_State;
    firstIndex =
        (g_NextEntry + UART_H4_PROBE_MAX_ENTRIES - g_State.EntryCount) %
        UART_H4_PROBE_MAX_ENTRIES;
    for (index = 0; index < g_State.EntryCount; ++index) {
        output->Entries[index] = g_State.Entries[
            (firstIndex + index) % UART_H4_PROBE_MAX_ENTRIES];
    }
    WdfSpinLockRelease(g_StateLock);

    output->Size = sizeof(*output);
    WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, sizeof(*output));
}

static
VOID
UartH4ProbeCompleteArmRequest(
    _In_ WDFREQUEST Request
    )
{
    PUART_H4_PROBE_ROUTE_ARM input;
    NTSTATUS status;

    status = WdfRequestRetrieveInputBuffer(
        Request,
        sizeof(UART_H4_PROBE_ROUTE_ARM),
        (PVOID *)&input,
        NULL);
    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(Request, status);
        return;
    }
    if (input->Version != UART_H4_PROBE_STATE_VERSION ||
        input->Size != sizeof(*input) || input->RewriteCount > 1) {
        WdfRequestComplete(Request, STATUS_INVALID_PARAMETER);
        return;
    }

    WdfSpinLockAcquire(g_StateLock);
    g_State.ArmedHciRouteRewrites = input->RewriteCount;
    /* Enable only when the matching command is actually rewritten. */
    g_State.ScoSiphonEnabled = 0;
    if (input->RewriteCount != 0) {
        g_ScoCaptureRead = 0;
        g_ScoCaptureWrite = 0;
        g_ScoCaptureCount = 0;
        g_State.ScoCaptureRingAvailable = 0;
        g_ScoRenderRead = 0;
        g_ScoRenderWrite = 0;
        g_ScoRenderCount = 0;
        g_State.ScoRenderRingAvailable = 0;
    }
    WdfSpinLockRelease(g_StateLock);
    WdfRequestComplete(Request, STATUS_SUCCESS);
}

static
BOOLEAN
UartH4ProbeIsScoSiphonEnabled(VOID)
{
    BOOLEAN enabled;

    WdfSpinLockAcquire(g_StateLock);
    enabled = g_State.ScoSiphonEnabled != 0;
    WdfSpinLockRelease(g_StateLock);
    return enabled;
}

static
VOID
UartH4ProbeSetScoSiphonBusy(
    _In_ BOOLEAN Busy
    )
{
    WdfSpinLockAcquire(g_StateLock);
    g_State.ScoSiphonBusy = Busy ? 1 : 0;
    WdfSpinLockRelease(g_StateLock);
}

static
VOID
UartH4ProbeRecordScoPacket(
    _In_reads_bytes_(3) const UCHAR *Header,
    _In_reads_bytes_opt_(PayloadLength) const UCHAR *Payload,
    _In_ ULONG PayloadLength
    )
{
    ULONG index;
    ULONG copyLength;

    WdfSpinLockAcquire(g_StateLock);
    ++g_State.SiphonedScoPackets;
    g_State.SiphonedScoPayloadBytes += PayloadLength;
    g_State.LastScoHandle = Header[0] | ((Header[1] & 0x0F) << 8);
    g_State.LastScoPacketStatus = (Header[1] >> 4) & 0x03;
    g_State.LastScoPayloadLength = PayloadLength;
    copyLength = min(PayloadLength, (ULONG)sizeof(g_State.LastScoPayload));
    RtlZeroMemory(g_State.LastScoPayload, sizeof(g_State.LastScoPayload));
    if (Payload != NULL && copyLength != 0) {
        RtlCopyMemory(g_State.LastScoPayload, Payload, copyLength);
        for (index = 0; index < copyLength; ++index) {
            if (Payload[index] != 0) {
                ++g_State.SiphonedScoNonzeroBytes;
            }
            if (g_ScoCaptureCount == UART_H4_SCO_CAPTURE_RING_BYTES) {
                g_ScoCaptureRead =
                    (g_ScoCaptureRead + 1) % UART_H4_SCO_CAPTURE_RING_BYTES;
                --g_ScoCaptureCount;
                ++g_State.ScoCaptureRingDroppedBytes;
            }
            g_ScoCaptureRing[g_ScoCaptureWrite] = Payload[index];
            g_ScoCaptureWrite =
                (g_ScoCaptureWrite + 1) % UART_H4_SCO_CAPTURE_RING_BYTES;
            ++g_ScoCaptureCount;
        }
    }
    g_State.ScoCaptureRingAvailable = g_ScoCaptureCount;
    WdfSpinLockRelease(g_StateLock);
}

static
VOID
UartH4ProbeCompleteScoPcmRead(
    _In_ WDFREQUEST Request
    )
{
    PUCHAR output;
    size_t outputLength;
    ULONG copyLength;
    ULONG firstRun;
    NTSTATUS status;

    status = WdfRequestRetrieveOutputBuffer(
        Request,
        1,
        (PVOID *)&output,
        &outputLength);
    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(Request, status);
        return;
    }

    WdfSpinLockAcquire(g_StateLock);
    copyLength = (ULONG)min(outputLength, (size_t)g_ScoCaptureCount);
    firstRun = min(
        copyLength,
        UART_H4_SCO_CAPTURE_RING_BYTES - g_ScoCaptureRead);
    if (firstRun != 0) {
        RtlCopyMemory(output, &g_ScoCaptureRing[g_ScoCaptureRead], firstRun);
    }
    if (copyLength > firstRun) {
        RtlCopyMemory(
            output + firstRun,
            g_ScoCaptureRing,
            copyLength - firstRun);
    }
    g_ScoCaptureRead =
        (g_ScoCaptureRead + copyLength) % UART_H4_SCO_CAPTURE_RING_BYTES;
    g_ScoCaptureCount -= copyLength;
    g_State.ScoCaptureRingAvailable = g_ScoCaptureCount;
    WdfSpinLockRelease(g_StateLock);

    WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, copyLength);
}

static
VOID
UartH4AudioReference(
    _In_ PVOID Context
    )
{
    WdfObjectReference((WDFOBJECT)Context);
}

static
VOID
UartH4AudioDereference(
    _In_ PVOID Context
    )
{
    WdfObjectDereference((WDFOBJECT)Context);
}

static
NTSTATUS
UartH4AudioStreamOpen(
    _In_ PVOID Context
    )
{
    UNREFERENCED_PARAMETER(Context);

    WdfSpinLockAcquire(g_StateLock);
    if (g_State.AudioInterfaceClients == 0) {
        g_State.ArmedHciRouteRewrites = 1;
        g_State.ScoSiphonEnabled = 0;
        g_ScoCaptureRead = 0;
        g_ScoCaptureWrite = 0;
        g_ScoCaptureCount = 0;
        g_State.ScoCaptureRingAvailable = 0;
        g_ScoRenderRead = 0;
        g_ScoRenderWrite = 0;
        g_ScoRenderCount = 0;
        g_State.ScoRenderRingAvailable = 0;
    }
    ++g_State.AudioInterfaceClients;
    WdfSpinLockRelease(g_StateLock);
    return STATUS_SUCCESS;
}

static
VOID
UartH4AudioStreamOpenComplete(
    _In_ PVOID Context
    )
{
    UNREFERENCED_PARAMETER(Context);

    WdfSpinLockAcquire(g_StateLock);
    g_State.ArmedHciRouteRewrites = 0;
    WdfSpinLockRelease(g_StateLock);
}

static
VOID
UartH4AudioStreamClose(
    _In_ PVOID Context
    )
{
    UNREFERENCED_PARAMETER(Context);

    WdfSpinLockAcquire(g_StateLock);
    if (g_State.AudioInterfaceClients != 0) {
        --g_State.AudioInterfaceClients;
    }
    if (g_State.AudioInterfaceClients == 0) {
        g_State.ArmedHciRouteRewrites = 0;
        g_State.ScoSiphonEnabled = 0;
    }
    WdfSpinLockRelease(g_StateLock);
}

static
ULONG
UartH4AudioReadCapture(
    _In_ PVOID Context,
    _Out_writes_bytes_(Length) UCHAR *Buffer,
    _In_ ULONG Length
    )
{
    ULONG copyLength;
    ULONG firstRun;

    UNREFERENCED_PARAMETER(Context);
    if (Buffer == NULL || Length == 0) {
        return 0;
    }

    WdfSpinLockAcquire(g_StateLock);
    copyLength = min(Length, g_ScoCaptureCount);
    firstRun = min(
        copyLength,
        UART_H4_SCO_CAPTURE_RING_BYTES - g_ScoCaptureRead);
    if (firstRun != 0) {
        RtlCopyMemory(Buffer, &g_ScoCaptureRing[g_ScoCaptureRead], firstRun);
    }
    if (copyLength > firstRun) {
        RtlCopyMemory(
            Buffer + firstRun,
            g_ScoCaptureRing,
            copyLength - firstRun);
    }
    g_ScoCaptureRead =
        (g_ScoCaptureRead + copyLength) % UART_H4_SCO_CAPTURE_RING_BYTES;
    g_ScoCaptureCount -= copyLength;
    g_State.ScoCaptureRingAvailable = g_ScoCaptureCount;
    WdfSpinLockRelease(g_StateLock);
    return copyLength;
}

static
ULONG
UartH4AudioQueueRender(
    _In_ PVOID Context,
    _In_reads_bytes_(Length) const UCHAR *Buffer,
    _In_ ULONG Length
    )
{
    ULONG index;

    UNREFERENCED_PARAMETER(Context);
    if (Buffer == NULL || Length == 0) {
        return 0;
    }

    WdfSpinLockAcquire(g_StateLock);
    for (index = 0; index < Length; ++index) {
        if (g_ScoRenderCount == UART_H4_SCO_RENDER_RING_BYTES) {
            g_ScoRenderRead =
                (g_ScoRenderRead + 1) % UART_H4_SCO_RENDER_RING_BYTES;
            --g_ScoRenderCount;
            ++g_State.ScoRenderRingDroppedBytes;
        }
        g_ScoRenderRing[g_ScoRenderWrite] = Buffer[index];
        g_ScoRenderWrite =
            (g_ScoRenderWrite + 1) % UART_H4_SCO_RENDER_RING_BYTES;
        ++g_ScoRenderCount;
    }
    g_State.ScoRenderRingAvailable = g_ScoRenderCount;
    WdfSpinLockRelease(g_StateLock);
    return Length;
}

static
NTSTATUS
UartH4ProbeQueueScoOutput(
    _In_ WDFDEVICE Device,
    _In_reads_bytes_(3) const UCHAR *Header,
    _In_ ULONG PayloadLength
    )
{
    PUART_H4_DEVICE_CONTEXT deviceContext;
    WDF_REQUEST_REUSE_PARAMS reuseParams;
    WDFMEMORY_OFFSET memoryOffset;
    ULONG index;
    NTSTATUS status;
    BOOLEAN sent;

    if (PayloadLength > UART_H4_PROBE_LAST_SCO_PAYLOAD_BYTES) {
        return STATUS_INVALID_BUFFER_SIZE;
    }

    deviceContext = UartH4GetDeviceContext(Device);
    if (InterlockedCompareExchange(
            &deviceContext->InternalWriteBusy,
            1,
            0) != 0) {
        WdfSpinLockAcquire(g_StateLock);
        ++g_State.FailedScoWrites;
        WdfSpinLockRelease(g_StateLock);
        return STATUS_DEVICE_BUSY;
    }

    deviceContext->ScoWriteBuffer[0] = 0x03;
    deviceContext->ScoWriteBuffer[1] = Header[0];
    deviceContext->ScoWriteBuffer[2] = Header[1] & 0x0F;
    deviceContext->ScoWriteBuffer[3] = (UCHAR)PayloadLength;

    WdfSpinLockAcquire(g_StateLock);
    for (index = 0; index < PayloadLength; ++index) {
        if (g_ScoRenderCount != 0) {
            deviceContext->ScoWriteBuffer[4 + index] =
                g_ScoRenderRing[g_ScoRenderRead];
            g_ScoRenderRead =
                (g_ScoRenderRead + 1) % UART_H4_SCO_RENDER_RING_BYTES;
            --g_ScoRenderCount;
        } else {
            deviceContext->ScoWriteBuffer[4 + index] = 0;
            ++g_State.ScoRenderUnderrunBytes;
        }
    }
    g_State.ScoRenderRingAvailable = g_ScoRenderCount;
    WdfSpinLockRelease(g_StateLock);

    if (deviceContext->InternalWriteUsed) {
        WDF_REQUEST_REUSE_PARAMS_INIT(
            &reuseParams,
            WDF_REQUEST_REUSE_NO_FLAGS,
            STATUS_SUCCESS);
        status = WdfRequestReuse(
            deviceContext->InternalWriteRequest,
            &reuseParams);
        if (!NT_SUCCESS(status)) {
            goto Failure;
        }
    } else {
        deviceContext->InternalWriteUsed = TRUE;
    }

    memoryOffset.BufferOffset = 0;
    memoryOffset.BufferLength = 4 + PayloadLength;
    status = WdfIoTargetFormatRequestForWrite(
        WdfDeviceGetIoTarget(Device),
        deviceContext->InternalWriteRequest,
        deviceContext->InternalWriteMemory,
        &memoryOffset,
        NULL);
    if (!NT_SUCCESS(status)) {
        goto Failure;
    }

    WdfRequestSetCompletionRoutine(
        deviceContext->InternalWriteRequest,
        UartH4ProbeInternalWriteCompletion,
        Device);
    sent = WdfRequestSend(
        deviceContext->InternalWriteRequest,
        WdfDeviceGetIoTarget(Device),
        WDF_NO_SEND_OPTIONS);
    if (!sent) {
        status = WdfRequestGetStatus(deviceContext->InternalWriteRequest);
        goto Failure;
    }
    return STATUS_SUCCESS;

Failure:
    WdfSpinLockAcquire(g_StateLock);
    ++g_State.FailedScoWrites;
    WdfSpinLockRelease(g_StateLock);
    InterlockedExchange(&deviceContext->InternalWriteBusy, 0);
    return status;
}

static
VOID
UartH4ProbeCompleteAudioInterfaceRequest(
    _In_ WDFREQUEST Request
    )
{
    PUART_H4_AUDIO_INTERFACE output;
    WDFDEVICE filterDevice;
    NTSTATUS status;

    if (WdfRequestGetRequestorMode(Request) != KernelMode) {
        WdfRequestComplete(Request, STATUS_ACCESS_DENIED);
        return;
    }
    status = WdfRequestRetrieveOutputBuffer(
        Request,
        sizeof(UART_H4_AUDIO_INTERFACE),
        (PVOID *)&output,
        NULL);
    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(Request, status);
        return;
    }

    WdfSpinLockAcquire(g_StateLock);
    filterDevice = g_FilterDevice;
    if (filterDevice != NULL) {
        WdfObjectReference(filterDevice);
    }
    WdfSpinLockRelease(g_StateLock);
    if (filterDevice == NULL) {
        WdfRequestComplete(Request, STATUS_DEVICE_NOT_READY);
        return;
    }

    RtlZeroMemory(output, sizeof(*output));
    output->Version = UART_H4_AUDIO_INTERFACE_VERSION;
    output->Size = sizeof(*output);
    output->Context = filterDevice;
    output->Reference = UartH4AudioReference;
    output->Dereference = UartH4AudioDereference;
    output->StreamOpen = UartH4AudioStreamOpen;
    output->StreamOpenComplete = UartH4AudioStreamOpenComplete;
    output->StreamClose = UartH4AudioStreamClose;
    output->ReadCapture = UartH4AudioReadCapture;
    output->QueueRender = UartH4AudioQueueRender;
    WdfRequestCompleteWithInformation(
        Request,
        STATUS_SUCCESS,
        sizeof(*output));
}

static
VOID
UartH4ProbeCompleteSiphonedRead(
    _In_ WDFDEVICE Device,
    _In_ NTSTATUS Status,
    _In_ BOOLEAN ReturnType,
    _In_ UCHAR Type
    )
{
    PUART_H4_DEVICE_CONTEXT deviceContext;
    WDFREQUEST originalRequest;
    PUCHAR output;
    NTSTATUS bufferStatus;

    deviceContext = UartH4GetDeviceContext(Device);
    originalRequest = deviceContext->OriginalReadRequest;
    deviceContext->OriginalReadRequest = NULL;
    deviceContext->StageCompleted = 0;
    deviceContext->StageExpected = 0;
    UartH4ProbeSetScoSiphonBusy(FALSE);

    if (originalRequest == NULL) {
        return;
    }

    if (NT_SUCCESS(Status) && ReturnType) {
        output = NULL;
        bufferStatus = WdfRequestRetrieveOutputBuffer(
            originalRequest,
            1,
            (PVOID *)&output,
            NULL);
        if (!NT_SUCCESS(bufferStatus)) {
            WdfRequestComplete(originalRequest, bufferStatus);
            return;
        }
        output[0] = Type;
        WdfRequestCompleteWithInformation(originalRequest, STATUS_SUCCESS, 1);
    } else {
        WdfRequestCompleteWithInformation(originalRequest, Status, 0);
    }
}

static
NTSTATUS
UartH4ProbeSendInternalRead(
    _In_ WDFDEVICE Device
    )
{
    PUART_H4_DEVICE_CONTEXT deviceContext;
    WDF_REQUEST_REUSE_PARAMS reuseParams;
    WDFMEMORY_OFFSET memoryOffset;
    ULONG baseOffset;
    ULONG remaining;
    NTSTATUS status;
    BOOLEAN sent;

    deviceContext = UartH4GetDeviceContext(Device);
    if (deviceContext->StageCompleted >= deviceContext->StageExpected) {
        return STATUS_INVALID_DEVICE_STATE;
    }

    if (deviceContext->InternalReadUsed) {
        WDF_REQUEST_REUSE_PARAMS_INIT(
            &reuseParams,
            WDF_REQUEST_REUSE_NO_FLAGS,
            STATUS_SUCCESS);
        status = WdfRequestReuse(deviceContext->InternalReadRequest, &reuseParams);
        if (!NT_SUCCESS(status)) {
            return status;
        }
    } else {
        deviceContext->InternalReadUsed = TRUE;
    }

    baseOffset = deviceContext->SiphonStage == UartH4SiphonPayload ? 3 : 0;
    remaining = deviceContext->StageExpected - deviceContext->StageCompleted;
    memoryOffset.BufferOffset = baseOffset + deviceContext->StageCompleted;
    memoryOffset.BufferLength = remaining;
    status = WdfIoTargetFormatRequestForRead(
        WdfDeviceGetIoTarget(Device),
        deviceContext->InternalReadRequest,
        deviceContext->InternalReadMemory,
        &memoryOffset,
        NULL);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    WdfRequestSetCompletionRoutine(
        deviceContext->InternalReadRequest,
        UartH4ProbeInternalReadCompletion,
        Device);
    sent = WdfRequestSend(
        deviceContext->InternalReadRequest,
        WdfDeviceGetIoTarget(Device),
        WDF_NO_SEND_OPTIONS);
    return sent ? STATUS_SUCCESS : WdfRequestGetStatus(deviceContext->InternalReadRequest);
}

static
NTSTATUS
UartH4ProbeBeginScoSiphon(
    _In_ WDFDEVICE Device,
    _In_ WDFREQUEST OriginalRequest
    )
{
    PUART_H4_DEVICE_CONTEXT deviceContext;

    deviceContext = UartH4GetDeviceContext(Device);
    if (deviceContext->OriginalReadRequest != NULL) {
        return STATUS_DEVICE_BUSY;
    }

    deviceContext->OriginalReadRequest = OriginalRequest;
    deviceContext->SiphonStage = UartH4SiphonHeader;
    deviceContext->StageExpected = 3;
    deviceContext->StageCompleted = 0;
    UartH4ProbeSetScoSiphonBusy(TRUE);
    return UartH4ProbeSendInternalRead(Device);
}

VOID
UartH4ProbeInternalReadCompletion(
    _In_ WDFREQUEST Request,
    _In_ WDFIOTARGET Target,
    _In_ PWDF_REQUEST_COMPLETION_PARAMS CompletionParams,
    _In_ WDFCONTEXT Context
    )
{
    WDFDEVICE device;
    PUART_H4_DEVICE_CONTEXT deviceContext;
    ULONG completedLength;
    NTSTATUS status;
    UCHAR nextType;

    UNREFERENCED_PARAMETER(Request);
    UNREFERENCED_PARAMETER(Target);

    device = (WDFDEVICE)Context;
    deviceContext = UartH4GetDeviceContext(device);
    status = CompletionParams->IoStatus.Status;
    completedLength = (ULONG)min(
        CompletionParams->IoStatus.Information,
        (ULONG_PTR)MAXULONG);
    if (!NT_SUCCESS(status) || completedLength == 0 ||
        completedLength > deviceContext->StageExpected - deviceContext->StageCompleted) {
        if (NT_SUCCESS(status)) {
            status = STATUS_DEVICE_DATA_ERROR;
        }
        UartH4ProbeCompleteSiphonedRead(device, status, FALSE, 0);
        return;
    }

    deviceContext->StageCompleted += completedLength;
    if (deviceContext->StageCompleted < deviceContext->StageExpected) {
        status = UartH4ProbeSendInternalRead(device);
        if (!NT_SUCCESS(status)) {
            UartH4ProbeCompleteSiphonedRead(device, status, FALSE, 0);
        }
        return;
    }

    if (deviceContext->SiphonStage == UartH4SiphonHeader) {
        deviceContext->SiphonStage = UartH4SiphonPayload;
        deviceContext->StageExpected = deviceContext->SiphonBuffer[2];
        deviceContext->StageCompleted = 0;
        if (deviceContext->StageExpected == 0) {
            UartH4ProbeRecordScoPacket(deviceContext->SiphonBuffer, NULL, 0);
            (VOID)UartH4ProbeQueueScoOutput(
                device,
                deviceContext->SiphonBuffer,
                0);
            deviceContext->SiphonStage = UartH4SiphonNextType;
            deviceContext->StageExpected = 1;
        }
    } else if (deviceContext->SiphonStage == UartH4SiphonPayload) {
        UartH4ProbeRecordScoPacket(
            deviceContext->SiphonBuffer,
            &deviceContext->SiphonBuffer[3],
            deviceContext->StageExpected);
        (VOID)UartH4ProbeQueueScoOutput(
            device,
            deviceContext->SiphonBuffer,
            deviceContext->StageExpected);
        deviceContext->SiphonStage = UartH4SiphonNextType;
        deviceContext->StageExpected = 1;
        deviceContext->StageCompleted = 0;
    } else {
        nextType = deviceContext->SiphonBuffer[0];
        if (nextType != 0x03) {
            UartH4ProbeCompleteSiphonedRead(device, STATUS_SUCCESS, TRUE, nextType);
            return;
        }
        deviceContext->SiphonStage = UartH4SiphonHeader;
        deviceContext->StageExpected = 3;
        deviceContext->StageCompleted = 0;
    }

    status = UartH4ProbeSendInternalRead(device);
    if (!NT_SUCCESS(status)) {
        UartH4ProbeCompleteSiphonedRead(device, status, FALSE, 0);
    }
}

VOID
UartH4ProbeInternalWriteCompletion(
    _In_ WDFREQUEST Request,
    _In_ WDFIOTARGET Target,
    _In_ PWDF_REQUEST_COMPLETION_PARAMS CompletionParams,
    _In_ WDFCONTEXT Context
    )
{
    WDFDEVICE device;
    PUART_H4_DEVICE_CONTEXT deviceContext;
    WDF_REQUEST_REUSE_PARAMS reuseParams;
    ULONG payloadLength;
    NTSTATUS reuseStatus;

    UNREFERENCED_PARAMETER(Request);
    UNREFERENCED_PARAMETER(Target);

    device = (WDFDEVICE)Context;
    deviceContext = UartH4GetDeviceContext(device);
    payloadLength = deviceContext->ScoWriteBuffer[3];

    WdfSpinLockAcquire(g_StateLock);
    if (NT_SUCCESS(CompletionParams->IoStatus.Status) &&
        CompletionParams->IoStatus.Information == 4 + payloadLength) {
        ++g_State.SentScoPackets;
        g_State.SentScoPayloadBytes += payloadLength;
    } else {
        ++g_State.FailedScoWrites;
    }
    WdfSpinLockRelease(g_StateLock);

    WDF_REQUEST_REUSE_PARAMS_INIT(
        &reuseParams,
        WDF_REQUEST_REUSE_NO_FLAGS,
        STATUS_SUCCESS);
    reuseStatus = WdfRequestReuse(Request, &reuseParams);
    if (NT_SUCCESS(reuseStatus)) {
        deviceContext->InternalWriteUsed = FALSE;
    } else {
        WdfSpinLockAcquire(g_StateLock);
        ++g_State.FailedScoWrites;
        WdfSpinLockRelease(g_StateLock);
    }
    InterlockedExchange(&deviceContext->InternalWriteBusy, 0);
}

static
VOID
UartH4ProbeForward(
    _In_ WDFDEVICE Device,
    _In_ WDFREQUEST Request
    )
{
    WDF_REQUEST_SEND_OPTIONS options;
    BOOLEAN sent;

    WdfRequestFormatRequestUsingCurrentType(Request);
    WDF_REQUEST_SEND_OPTIONS_INIT(
        &options,
        WDF_REQUEST_SEND_OPTION_SEND_AND_FORGET);
    sent = WdfRequestSend(Request, WdfDeviceGetIoTarget(Device), &options);
    if (!sent) {
        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
    }
}

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
{
    WDF_DRIVER_CONFIG config;
    WDF_OBJECT_ATTRIBUTES lockAttributes;
    WDFDRIVER driver;
    NTSTATUS status;

    WDF_DRIVER_CONFIG_INIT(&config, UartH4ProbeEvtDeviceAdd);
    status = WdfDriverCreate(
        DriverObject,
        RegistryPath,
        WDF_NO_OBJECT_ATTRIBUTES,
        &config,
        &driver);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    WDF_OBJECT_ATTRIBUTES_INIT(&lockAttributes);
    lockAttributes.ParentObject = driver;
    status = WdfSpinLockCreate(&lockAttributes, &g_StateLock);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    RtlZeroMemory(&g_State, sizeof(g_State));
    g_State.Version = UART_H4_PROBE_STATE_VERSION;
    g_State.Size = sizeof(g_State);
    g_NextEntry = 0;
    return UartH4ProbeCreateControlDevice(driver);
}

NTSTATUS
UartH4ProbeCreateControlDevice(
    _In_ WDFDRIVER Driver
    )
{
    DECLARE_CONST_UNICODE_STRING(
        sddl,
        L"D:P(A;;GA;;;SY)(A;;GRGWGX;;;BA)");
    DECLARE_CONST_UNICODE_STRING(ntName, UART_H4_PROBE_NT_DEVICE_NAME);
    DECLARE_CONST_UNICODE_STRING(dosName, UART_H4_PROBE_DOS_DEVICE_NAME);
    PWDFDEVICE_INIT deviceInit;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDFDEVICE device;
    NTSTATUS status;

    deviceInit = WdfControlDeviceInitAllocate(Driver, &sddl);
    if (deviceInit == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    WdfDeviceInitSetDeviceType(deviceInit, FILE_DEVICE_UNKNOWN);
    WdfDeviceInitSetCharacteristics(deviceInit, FILE_DEVICE_SECURE_OPEN, FALSE);
    status = WdfDeviceInitAssignName(deviceInit, &ntName);
    if (!NT_SUCCESS(status)) {
        WdfDeviceInitFree(deviceInit);
        return status;
    }

    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    status = WdfDeviceCreate(&deviceInit, &attributes, &device);
    if (!NT_SUCCESS(status)) {
        if (deviceInit != NULL) {
            WdfDeviceInitFree(deviceInit);
        }
        return status;
    }

    status = WdfDeviceCreateSymbolicLink(device, &dosName);
    if (!NT_SUCCESS(status)) {
        WdfObjectDelete(device);
        return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(
        &queueConfig,
        WdfIoQueueDispatchParallel);
    queueConfig.PowerManaged = WdfFalse;
    queueConfig.EvtIoDeviceControl = UartH4ProbeEvtControlDeviceControl;
    status = WdfIoQueueCreate(
        device,
        &queueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) {
        WdfObjectDelete(device);
        return status;
    }

    WdfControlFinishInitializing(device);
    return STATUS_SUCCESS;
}

NTSTATUS
UartH4ProbeEvtDeviceAdd(
    _In_ WDFDRIVER Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
    )
{
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_OBJECT_ATTRIBUTES childAttributes;
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDFDEVICE device;
    PUART_H4_DEVICE_CONTEXT deviceContext;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(Driver);
    PAGED_CODE();

    WdfFdoInitSetFilter(DeviceInit);
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, UART_H4_DEVICE_CONTEXT);
    attributes.EvtCleanupCallback = UartH4ProbeEvtDeviceContextCleanup;
    status = WdfDeviceCreate(&DeviceInit, &attributes, &device);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    deviceContext = UartH4GetDeviceContext(device);
    WDF_OBJECT_ATTRIBUTES_INIT(&childAttributes);
    childAttributes.ParentObject = device;
    status = WdfMemoryCreatePreallocated(
        &childAttributes,
        deviceContext->SiphonBuffer,
        sizeof(deviceContext->SiphonBuffer),
        &deviceContext->InternalReadMemory);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    status = WdfRequestCreate(
        &childAttributes,
        WdfDeviceGetIoTarget(device),
        &deviceContext->InternalReadRequest);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    status = WdfMemoryCreatePreallocated(
        &childAttributes,
        deviceContext->ScoWriteBuffer,
        sizeof(deviceContext->ScoWriteBuffer),
        &deviceContext->InternalWriteMemory);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    status = WdfRequestCreate(
        &childAttributes,
        WdfDeviceGetIoTarget(device),
        &deviceContext->InternalWriteRequest);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(
        &queueConfig,
        WdfIoQueueDispatchParallel);
    queueConfig.PowerManaged = WdfFalse;
    queueConfig.EvtIoRead = UartH4ProbeEvtIoRead;
    queueConfig.EvtIoWrite = UartH4ProbeEvtIoWrite;
    queueConfig.EvtIoDeviceControl = UartH4ProbeEvtIoDeviceControl;
    queueConfig.EvtIoInternalDeviceControl =
        UartH4ProbeEvtIoInternalDeviceControl;
    status = WdfIoQueueCreate(
        device,
        &queueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    WdfSpinLockAcquire(g_StateLock);
    g_FilterDevice = device;
    WdfSpinLockRelease(g_StateLock);
    return STATUS_SUCCESS;
}

VOID
UartH4ProbeEvtDeviceContextCleanup(
    _In_ WDFOBJECT Object
    )
{
    WDFDEVICE device;

    device = (WDFDEVICE)Object;
    WdfSpinLockAcquire(g_StateLock);
    if (g_FilterDevice == device) {
        g_FilterDevice = NULL;
    }
    WdfSpinLockRelease(g_StateLock);
}

VOID
UartH4ProbeEvtIoRead(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t Length
    )
{
    WDFDEVICE device;
    BOOLEAN sent;

    device = WdfIoQueueGetDevice(Queue);
    WdfRequestFormatRequestUsingCurrentType(Request);
    WdfRequestSetCompletionRoutine(
        Request,
        UartH4ProbeReadCompletion,
        (WDFCONTEXT)(ULONG_PTR)Length);
    sent = WdfRequestSend(
        Request,
        WdfDeviceGetIoTarget(device),
        WDF_NO_SEND_OPTIONS);
    if (!sent) {
        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
    }
}

VOID
UartH4ProbeReadCompletion(
    _In_ WDFREQUEST Request,
    _In_ WDFIOTARGET Target,
    _In_ PWDF_REQUEST_COMPLETION_PARAMS CompletionParams,
    _In_ WDFCONTEXT Context
    )
{
    PUCHAR buffer;
    ULONG requestedLength;
    ULONG completedLength;
    NTSTATUS bufferStatus;
    NTSTATUS siphonStatus;
    WDFDEVICE device;

    requestedLength = (ULONG)min((ULONG_PTR)Context, (ULONG_PTR)MAXULONG);
    completedLength = (ULONG)min(
        CompletionParams->IoStatus.Information,
        (ULONG_PTR)MAXULONG);
    buffer = NULL;
    if (completedLength != 0) {
        bufferStatus = WdfRequestRetrieveOutputBuffer(
            Request,
            1,
            (PVOID *)&buffer,
            NULL);
        if (!NT_SUCCESS(bufferStatus)) {
            buffer = NULL;
        }
    }

    UartH4ProbeRecord(
        UartH4ProbeRead,
        requestedLength,
        completedLength,
        CompletionParams->IoStatus.Status,
        buffer,
        buffer != NULL ? completedLength : 0);

    if (NT_SUCCESS(CompletionParams->IoStatus.Status) &&
        requestedLength == 1 && completedLength == 1 &&
        buffer != NULL && buffer[0] == 0x03 &&
        UartH4ProbeIsScoSiphonEnabled()) {
        device = WdfIoTargetGetDevice(Target);
        siphonStatus = UartH4ProbeBeginScoSiphon(device, Request);
        if (NT_SUCCESS(siphonStatus)) {
            return;
        }
        WdfRequestCompleteWithInformation(Request, siphonStatus, 0);
        return;
    }

    WdfRequestCompleteWithInformation(
        Request,
        CompletionParams->IoStatus.Status,
        CompletionParams->IoStatus.Information);
}

VOID
UartH4ProbeEvtIoWrite(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t Length
    )
{
    PUCHAR buffer;
    NTSTATUS status;

    buffer = NULL;
    if (Length != 0) {
        status = WdfRequestRetrieveInputBuffer(
            Request,
            1,
            (PVOID *)&buffer,
            NULL);
        if (!NT_SUCCESS(status)) {
            buffer = NULL;
        }
    }

    UartH4ProbeRecord(
        UartH4ProbeWrite,
        (ULONG)min(Length, (size_t)MAXULONG),
        (ULONG)min(Length, (size_t)MAXULONG),
        STATUS_PENDING,
        buffer,
        buffer != NULL ? (ULONG)min(Length, (size_t)MAXULONG) : 0);
    UartH4ProbeMaybeRewriteSynchronousDataPath(
        buffer,
        buffer != NULL ? (ULONG)min(Length, (size_t)MAXULONG) : 0);
    UartH4ProbeForward(WdfIoQueueGetDevice(Queue), Request);
}

VOID
UartH4ProbeEvtIoDeviceControl(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength,
    _In_ ULONG IoControlCode
    )
{
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);
    UNREFERENCED_PARAMETER(IoControlCode);
    UartH4ProbeForward(WdfIoQueueGetDevice(Queue), Request);
}

VOID
UartH4ProbeEvtIoInternalDeviceControl(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength,
    _In_ ULONG IoControlCode
    )
{
    UartH4ProbeEvtIoDeviceControl(
        Queue,
        Request,
        OutputBufferLength,
        InputBufferLength,
        IoControlCode);
}

VOID
UartH4ProbeEvtControlDeviceControl(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength,
    _In_ ULONG IoControlCode
    )
{
    UNREFERENCED_PARAMETER(Queue);
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    if (IoControlCode == IOCTL_UART_H4_PROBE_GET_STATE) {
        UartH4ProbeCompleteStateRequest(Request);
    } else if (IoControlCode == IOCTL_UART_H4_PROBE_ARM_HCI_ROUTE) {
        UartH4ProbeCompleteArmRequest(Request);
    } else if (IoControlCode == IOCTL_UART_H4_PROBE_READ_SCO_PCM) {
        UartH4ProbeCompleteScoPcmRead(Request);
    } else if (IoControlCode == IOCTL_UART_H4_PROBE_GET_AUDIO_INTERFACE) {
        UartH4ProbeCompleteAudioInterfaceRequest(Request);
    } else {
        WdfRequestComplete(Request, STATUS_INVALID_DEVICE_REQUEST);
    }
}

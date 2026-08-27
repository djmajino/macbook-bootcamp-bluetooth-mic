#include <windows.h>
#include <stdio.h>

#include "..\shared\uart_h4_public.h"

static const char *DirectionName(ULONG direction)
{
    return direction == UartH4ProbeRead ? "RX" : "TX";
}

int wmain(int argc, wchar_t **argv)
{
    HANDLE device;
    UART_H4_PROBE_STATE state;
    DWORD returned;
    ULONG index;
    ULONG byteIndex;

    UART_H4_PROBE_ROUTE_ARM arm;

    device = CreateFileW(
        L"\\\\.\\UartH4Probe",
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    if (device == INVALID_HANDLE_VALUE) {
        fwprintf(stderr, L"UartH4Probe open failed: %lu\n", GetLastError());
        return 1;
    }

    if (argc == 2 &&
        (wcscmp(argv[1], L"--arm-hci-route") == 0 ||
         wcscmp(argv[1], L"--disarm-hci-route") == 0)) {
        ZeroMemory(&arm, sizeof(arm));
        arm.Version = UART_H4_PROBE_STATE_VERSION;
        arm.Size = sizeof(arm);
        arm.RewriteCount = wcscmp(argv[1], L"--arm-hci-route") == 0 ? 1 : 0;
        returned = 0;
        if (!DeviceIoControl(
                device,
                IOCTL_UART_H4_PROBE_ARM_HCI_ROUTE,
                &arm,
                sizeof(arm),
                NULL,
                0,
                &returned,
                NULL)) {
            fwprintf(stderr, L"Route arm request failed: %lu\n", GetLastError());
            CloseHandle(device);
            return 3;
        }
        printf("next enhanced synchronous HCI-route rewrite: %s\n",
            arm.RewriteCount == 0 ? "disarmed" : "armed once");
    } else if (argc != 1) {
        fwprintf(stderr, L"Usage: UartH4Query.exe [--arm-hci-route|--disarm-hci-route]\n");
        CloseHandle(device);
        return 4;
    }

    ZeroMemory(&state, sizeof(state));
    returned = 0;
    if (!DeviceIoControl(
            device,
            IOCTL_UART_H4_PROBE_GET_STATE,
            NULL,
            0,
            &state,
            sizeof(state),
            &returned,
            NULL)) {
        fwprintf(stderr, L"State query failed: %lu\n", GetLastError());
        CloseHandle(device);
        return 2;
    }
    CloseHandle(device);

    printf("UartH4Probe state v%lu (%lu bytes)\n", state.Version, returned);
    printf("read requests/bytes: %llu/%llu\n", state.ReadRequests, state.ReadBytes);
    printf("write requests/bytes: %llu/%llu\n", state.WriteRequests, state.WriteBytes);
    printf("first-byte command/ACL/SCO/event/other: %llu/%llu/%llu/%llu/%llu\n",
        state.FirstByteCommand,
        state.FirstByteAcl,
        state.FirstByteSco,
        state.FirstByteEvent,
        state.FirstByteOther);
    printf("HCI-route armed/rewritten: %lu/%lu\n",
        state.ArmedHciRouteRewrites,
        state.RewrittenEnhancedSyncCommands);
    printf("last original path input/output, unit input/output: %lu/%lu, %lu/%lu\n",
        state.LastOriginalInputDataPath,
        state.LastOriginalOutputDataPath,
        state.LastOriginalInputTransportUnitSize,
        state.LastOriginalOutputTransportUnitSize);
    printf("SCO siphon enabled/busy, packets/payload/nonzero: %lu/%lu, %llu/%llu/%llu\n",
        state.ScoSiphonEnabled,
        state.ScoSiphonBusy,
        state.SiphonedScoPackets,
        state.SiphonedScoPayloadBytes,
        state.SiphonedScoNonzeroBytes);
    printf("last SCO handle/status/length: 0x%03lX/%lu/%lu payload=",
        state.LastScoHandle,
        state.LastScoPacketStatus,
        state.LastScoPayloadLength);
    for (byteIndex = 0;
         byteIndex < min(state.LastScoPayloadLength, UART_H4_PROBE_LAST_SCO_PAYLOAD_BYTES);
         ++byteIndex) {
        printf("%02X", state.LastScoPayload[byteIndex]);
    }
    printf("\n");
    printf("SCO capture ring available/dropped bytes: %lu/%llu\n",
        state.ScoCaptureRingAvailable,
        state.ScoCaptureRingDroppedBytes);
    printf("audio clients, render ring available/dropped/underrun: %lu, %lu/%llu/%llu\n",
        state.AudioInterfaceClients,
        state.ScoRenderRingAvailable,
        state.ScoRenderRingDroppedBytes,
        state.ScoRenderUnderrunBytes);
    printf("SCO output packets/payload/failures: %llu/%llu/%llu\n",
        state.SentScoPackets,
        state.SentScoPayloadBytes,
        state.FailedScoWrites);
    printf("trace entries: %lu (total %lu)\n", state.EntryCount, state.TotalEntries);

    for (index = 0; index < state.EntryCount; ++index) {
        const UART_H4_PROBE_ENTRY *entry = &state.Entries[index];
        printf("%06lu %s requested=%lu completed=%lu status=0x%08lX payload=",
            entry->Sequence,
            DirectionName(entry->Direction),
            entry->RequestedLength,
            entry->CompletedLength,
            (ULONG)entry->Status);
        for (byteIndex = 0; byteIndex < entry->PayloadLength; ++byteIndex) {
            printf("%02X", entry->Payload[byteIndex]);
        }
        printf("\n");
    }
    return 0;
}

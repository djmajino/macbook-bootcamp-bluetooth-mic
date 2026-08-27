#include <windows.h>
#include <newdev.h>
#include <setupapi.h>
#include <strsafe.h>

#include <iostream>
#include <string>
#include <vector>

#pragma comment(lib, "newdev.lib")
#pragma comment(lib, "setupapi.lib")

namespace {

constexpr ULONG kSystemCodeIntegrityInformation = 103;
constexpr ULONG kCodeIntegrityOptionTestSign = 0x02;

struct SystemCodeIntegrityInformation {
    ULONG Length;
    ULONG CodeIntegrityOptions;
};

using NtQuerySystemInformationFn = LONG(NTAPI*)(ULONG, PVOID, ULONG, PULONG);

void PrintWin32Error(const wchar_t* operation, DWORD error)
{
    wchar_t* message = nullptr;
    const DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER |
        FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_IGNORE_INSERTS;
    FormatMessageW(flags,
                   nullptr,
                   error,
                   0,
                   reinterpret_cast<wchar_t*>(&message),
                   0,
                   nullptr);
    std::wcerr << L"ERROR: " << operation << L" failed (" << error << L")";
    if (message != nullptr) {
        std::wcerr << L": " << message;
        LocalFree(message);
    } else {
        std::wcerr << std::endl;
    }
}

int PrintTestSigningStatus()
{
    const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    if (ntdll == nullptr) {
        PrintWin32Error(L"GetModuleHandleW(ntdll.dll)", GetLastError());
        return 10;
    }

    const auto query = reinterpret_cast<NtQuerySystemInformationFn>(
        GetProcAddress(ntdll, "NtQuerySystemInformation"));
    if (query == nullptr) {
        PrintWin32Error(L"GetProcAddress(NtQuerySystemInformation)", GetLastError());
        return 10;
    }

    SystemCodeIntegrityInformation information{};
    information.Length = sizeof(information);
    const LONG status = query(kSystemCodeIntegrityInformation,
                              &information,
                              sizeof(information),
                              nullptr);
    if (status < 0) {
        std::wcerr << L"ERROR: NtQuerySystemInformation failed (NTSTATUS=0x"
                   << std::hex << static_cast<ULONG>(status) << L")" << std::endl;
        return 10;
    }

    std::wcout << L"CODE_INTEGRITY_OPTIONS=0x" << std::hex
               << information.CodeIntegrityOptions << std::endl;
    const bool enabled =
        (information.CodeIntegrityOptions & kCodeIntegrityOptionTestSign) != 0;
    std::wcout << L"TESTSIGNING_ACTIVE=" << (enabled ? L"1" : L"0") << std::endl;
    return enabled ? 0 : 3;
}

bool RemoveCreatedDevice(HDEVINFO deviceInfoSet, SP_DEVINFO_DATA* deviceInfoData)
{
    SP_REMOVEDEVICE_PARAMS removeParameters{};
    removeParameters.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
    removeParameters.ClassInstallHeader.InstallFunction = DIF_REMOVE;
    removeParameters.Scope = DI_REMOVEDEVICE_GLOBAL;
    removeParameters.HwProfile = 0;

    if (!SetupDiSetClassInstallParamsW(
            deviceInfoSet,
            deviceInfoData,
            &removeParameters.ClassInstallHeader,
            sizeof(removeParameters))) {
        return false;
    }
    return SetupDiCallClassInstaller(DIF_REMOVE, deviceInfoSet, deviceInfoData) == TRUE;
}

int InstallRootDevice(const wchar_t* infArgument, const wchar_t* hardwareId)
{
    wchar_t infPath[MAX_PATH]{};
    if (GetFullPathNameW(infArgument, ARRAYSIZE(infPath), infPath, nullptr) == 0) {
        PrintWin32Error(L"GetFullPathNameW", GetLastError());
        return 20;
    }

    GUID classGuid{};
    wchar_t className[256]{};
    if (!SetupDiGetINFClassW(
            infPath, &classGuid, className, ARRAYSIZE(className), nullptr)) {
        PrintWin32Error(L"SetupDiGetINFClassW", GetLastError());
        return 21;
    }

    HDEVINFO deviceInfoSet = SetupDiCreateDeviceInfoList(&classGuid, nullptr);
    if (deviceInfoSet == INVALID_HANDLE_VALUE) {
        PrintWin32Error(L"SetupDiCreateDeviceInfoList", GetLastError());
        return 22;
    }

    SP_DEVINFO_DATA deviceInfoData{};
    deviceInfoData.cbSize = sizeof(deviceInfoData);
    if (!SetupDiCreateDeviceInfoW(deviceInfoSet,
                                  className,
                                  &classGuid,
                                  nullptr,
                                  nullptr,
                                  DICD_GENERATE_ID,
                                  &deviceInfoData)) {
        const DWORD error = GetLastError();
        SetupDiDestroyDeviceInfoList(deviceInfoSet);
        PrintWin32Error(L"SetupDiCreateDeviceInfoW", error);
        return 23;
    }

    const size_t hardwareIdCharacters = wcslen(hardwareId) + 2;
    std::vector<wchar_t> hardwareIds(hardwareIdCharacters, L'\0');
    StringCchCopyW(hardwareIds.data(), hardwareIds.size(), hardwareId);
    if (!SetupDiSetDeviceRegistryPropertyW(
            deviceInfoSet,
            &deviceInfoData,
            SPDRP_HARDWAREID,
            reinterpret_cast<const BYTE*>(hardwareIds.data()),
            static_cast<DWORD>(hardwareIds.size() * sizeof(wchar_t)))) {
        const DWORD error = GetLastError();
        SetupDiDestroyDeviceInfoList(deviceInfoSet);
        PrintWin32Error(L"SetupDiSetDeviceRegistryPropertyW", error);
        return 24;
    }

    if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE,
                                   deviceInfoSet,
                                   &deviceInfoData)) {
        const DWORD error = GetLastError();
        SetupDiDestroyDeviceInfoList(deviceInfoSet);
        PrintWin32Error(L"DIF_REGISTERDEVICE", error);
        return 25;
    }

    BOOL rebootRequired = FALSE;
    if (!UpdateDriverForPlugAndPlayDevicesW(nullptr,
                                            hardwareId,
                                            infPath,
                                            INSTALLFLAG_FORCE,
                                            &rebootRequired)) {
        const DWORD error = GetLastError();
        if (!RemoveCreatedDevice(deviceInfoSet, &deviceInfoData)) {
            PrintWin32Error(L"rollback DIF_REMOVE", GetLastError());
        }
        SetupDiDestroyDeviceInfoList(deviceInfoSet);
        PrintWin32Error(L"UpdateDriverForPlugAndPlayDevicesW", error);
        return 26;
    }

    SetupDiDestroyDeviceInfoList(deviceInfoSet);
    std::wcout << L"ROOT_DEVICE_INSTALLED=1" << std::endl;
    std::wcout << L"REBOOT_REQUIRED=" << (rebootRequired ? L"1" : L"0")
               << std::endl;
    return 0;
}

int UpdateExistingDevice(const wchar_t* infArgument, const wchar_t* hardwareId)
{
    wchar_t infPath[MAX_PATH]{};
    if (GetFullPathNameW(infArgument, ARRAYSIZE(infPath), infPath, nullptr) == 0) {
        PrintWin32Error(L"GetFullPathNameW", GetLastError());
        return 30;
    }

    BOOL rebootRequired = FALSE;
    if (!UpdateDriverForPlugAndPlayDevicesW(nullptr,
                                            hardwareId,
                                            infPath,
                                            INSTALLFLAG_FORCE,
                                            &rebootRequired)) {
        PrintWin32Error(L"UpdateDriverForPlugAndPlayDevicesW", GetLastError());
        return 31;
    }

    std::wcout << L"DRIVER_UPDATED=1" << std::endl;
    std::wcout << L"REBOOT_REQUIRED=" << (rebootRequired ? L"1" : L"0")
               << std::endl;
    return 0;
}

void PrintUsage()
{
    std::wcerr
        << L"Usage:\n"
        << L"  BluetoothMicMacNative.exe status-testsigning\n"
        << L"  BluetoothMicMacNative.exe install-root <full-inf-path> <hardware-id>\n"
        << L"  BluetoothMicMacNative.exe update-driver <full-inf-path> <hardware-id>\n";
}

} // namespace

int wmain(int argc, wchar_t** argv)
{
    if (argc == 2 && _wcsicmp(argv[1], L"status-testsigning") == 0) {
        return PrintTestSigningStatus();
    }
    if (argc == 4 && _wcsicmp(argv[1], L"install-root") == 0) {
        return InstallRootDevice(argv[2], argv[3]);
    }
    if (argc == 4 && _wcsicmp(argv[1], L"update-driver") == 0) {
        return UpdateExistingDevice(argv[2], argv[3]);
    }

    PrintUsage();
    return 2;
}

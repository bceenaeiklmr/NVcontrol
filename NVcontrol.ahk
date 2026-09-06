/**
 * @file NVcontrol.ahk
 * @description GPU Power Limit, Clock Offset & Fan Controller for Windows (NVcontrol), written in AutoHotkey v2.
 * Utilizes direct Win32 DllCall with nvml.dll. ~3 MB RAM usage.
 * @version 1.0.0
 * @license MIT
 * @author Bence Markiel (bceenaeiklmr)
 * @repository https://github.com/bceenaeiklmr/NVcontrol
 */

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All

/**
 * Single-instance manager using a cross-integrity named Win32 mutex and registered window messages.
 * Prevents duplicate processes, avoids elevation privilege deadlocks, and brings running instance to front on relaunch.
 */
class InstanceManager {
    static MutexName := "Local\NVcontrol_app_instance_mutex"
    static MsgName := "NVCONTROL_RESTORE_WINDOW_MSG"
    static hMutex := 0
    static WakeMsg := 0

    /**
     * Initializes single-instance management.
     * If an instance already exists, signals it to restore and returns false (to exit caller).
     * If this is the primary instance, claims the mutex and configures UIPI bypass.
     * @returns {Boolean} True if this is the primary instance, false if already running.
     */
    static Init() {
        this.WakeMsg := DllCall("RegisterWindowMessage", "str", this.MsgName, "UInt")

        ; Security descriptor with NULL DACL allows both unelevated and elevated processes to access mutex
        sd := Buffer(40, 0)
        DllCall("advapi32\InitializeSecurityDescriptor", "Ptr", sd, "UInt", 1)
        DllCall("advapi32\SetSecurityDescriptorDacl", "Ptr", sd, "Int", 1, "Ptr", 0, "Int", 0)

        sa := Buffer(A_PtrSize == 8 ? 24 : 12, 0)
        NumPut("UInt", sa.Size, sa, 0)
        NumPut("Ptr", sd.Ptr, sa, A_PtrSize)
        NumPut("Int", 0, sa, A_PtrSize * 2)

        this.hMutex := DllCall("CreateMutexW", "Ptr", sa, "Int", 1, "WStr", this.MutexName, "Ptr")
        lastErr := DllCall("GetLastError", "UInt")

        ; If mutex already exists (183 = ERROR_ALREADY_EXISTS)
        if (lastErr == 183) {
            this.SignalExisting()
            if this.hMutex {
                DllCall("CloseHandle", "Ptr", this.hMutex)
                this.hMutex := 0
            }
            return false
        }

        ; Primary instance: allow the restore message through Windows UIPI filter
        DllCall("ChangeWindowMessageFilter", "UInt", this.WakeMsg, "UInt", 1) ; MSGFLT_ADD = 1
        return true
    }

    /**
     * Broadcasts restore message to wake the existing running instance.
     */
    static SignalExisting() {
        if this.WakeMsg
            DllCall("PostMessage", "Ptr", 0xFFFF, "UInt", this.WakeMsg, "UPtr", 0, "Ptr", 0)
    }

    /**
     * Registers the wake listener in the primary instance.
     * @param {NvControlGui} controller - Controller instance to restore.
     */
    static RegisterListener(controller) {
        if this.WakeMsg {
            OnMessage(this.WakeMsg, (*) => (controller.Restore(), 1))
        }
    }

    /**
     * Releases mutex handle on application exit.
     */
    static Close() {
        if this.hMutex {
            DllCall("CloseHandle", "Ptr", this.hMutex)
            this.hMutex := 0
        }
    }
}

/**
 * Checks and requests Administrator privileges required for NVML hardware control.
 * Restarts the script with *RunAs and /restart flag if necessary.
 * @returns {Boolean} True if running elevated, false otherwise.
 */
EnsureAdmin() {
    fullCmdLine := DllCall("GetCommandLine", "str")
    if !A_IsAdmin && !RegExMatch(fullCmdLine, "i) /restart(?!\S)") {
        try {
            InstanceManager.Close()
            if A_IsCompiled
                Run('*RunAs "' A_ScriptFullPath '" /restart')
            else
                Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
            ExitApp()
        } catch {
            return false
        }
    }
    return A_IsAdmin
}

/**
 * Trims the process working set memory to the bare minimum via SetProcessWorkingSetSize.
 * Flushes one-time initialization pages and unreferenced driver memory, keeping RAM at ~1.5 - 3 MB.
 */
TrimWorkingSet() {
    DllCall("SetProcessWorkingSetSize", "Ptr", -1, "UPtr", -1, "UPtr", -1)
}

/**
 * Manages Windows Startup shortcut integration for silent, minimized boot execution.
 */
class StartupManager {
    static ShortcutPath := A_Startup "\NVcontrol.lnk"
    static LegacyShortcutPath := A_Startup "\nv-control.lnk"
    static AncientShortcutPath := A_Startup "\NvidiaGPUController.lnk"

    /**
     * Checks if the application is currently registered to start with Windows.
     * @returns {Boolean} True if startup shortcut exists.
     */
    static IsEnabled() {
        return (FileExist(this.ShortcutPath) || FileExist(this.LegacyShortcutPath) || FileExist(this.AncientShortcutPath)) ? true : false
    }

    /**
     * Creates or removes the Windows Startup shortcut.
     * @param {Boolean} enable - True to create startup shortcut, false to delete.
     * @returns {Boolean} True on success.
     */
    static SetEnabled(enable) {
        if enable {
            target := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
            args := A_IsCompiled ? "/minimized" : ('"' A_ScriptFullPath '" /minimized')
            try {
                if FileExist(this.LegacyShortcutPath)
                    try FileDelete(this.LegacyShortcutPath)
                if FileExist(this.AncientShortcutPath)
                    try FileDelete(this.AncientShortcutPath)
                FileCreateShortcut(target, this.ShortcutPath, A_ScriptDir, args, "NVcontrol - GPU Hardware & Power Controller", A_ScriptFullPath)
                return true
            } catch as err {
                MsgBox("Failed to create Windows startup shortcut:`n`n" err.Message, "NVcontrol - Startup Error", "Iconx")
                return false
            }
        } else {
            try {
                if FileExist(this.ShortcutPath)
                    FileDelete(this.ShortcutPath)
                if FileExist(this.LegacyShortcutPath)
                    FileDelete(this.LegacyShortcutPath)
                if FileExist(this.AncientShortcutPath)
                    FileDelete(this.AncientShortcutPath)
                return true
            } catch as err {
                MsgBox("Failed to remove Windows startup shortcut:`n`n" err.Message, "NVcontrol - Startup Error", "Iconx")
                return false
            }
        }
    }
}

/**
 * Hardware limits, input validation, and crash recovery.
 * Clamps inputs within VBIOS limits, guards against fan stalling,
 * and restores safe defaults if an unexpected crash occurs.
 */
class Safety {
    static CanaryDir := A_AppData "\NVcontrol"
    static CanaryPath := A_AppData "\NVcontrol\session_active.canary"
    static LegacyCanaryDir := A_AppData "\nv-control"
    static LegacyCanaryPath := A_AppData "\nv-control\session_active.canary"
    static AncientCanaryDir := A_AppData "\NvidiaGPUController"
    static AncientCanaryPath := A_AppData "\NvidiaGPUController\session_active.canary"
    static CanaryTimer := 0

    /**
     * Performs safe-boot crash detection. If a previous session terminated abnormally,
     * restores all hardware parameters to safe VBIOS factory defaults.
     * @param {NvmlDevice} gpu - Active GPU device instance.
     * @returns {Boolean} True if safe-boot recovery was triggered.
     */
    static CheckSafeBoot(gpu) {
        if !DirExist(this.CanaryDir) {
            try DirCreate(this.CanaryDir)
        }

        hasCrash := FileExist(this.CanaryPath) || FileExist(this.LegacyCanaryPath)
        if FileExist(this.CanaryPath)
            try FileDelete(this.CanaryPath)
        if FileExist(this.LegacyCanaryPath)
            try FileDelete(this.LegacyCanaryPath)

        if hasCrash {
            this.RecoverToSafeDefaults(gpu)
            MsgBox("Safe Boot Activated`n`n"
                . "The previous session ended unexpectedly or Windows rebooted abruptly.`n`n"
                . "Hardware parameters have been reset to factory defaults:`n"
                . "• Clock offsets: 0 MHz`n"
                . "• Fans: Auto (VBIOS thermal curve)`n"
                . "• Power limit: Factory default",
                "Safe Boot", "Icon!")
            return true
        }

        ; Write session canary
        try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " | PID: " ProcessExist(), this.CanaryPath, "UTF-8")

        ; After 45 seconds of continuous stable execution, clear the canary
        this.CanaryTimer := () => this.ClearCanary()
        SetTimer(this.CanaryTimer, -45000)
        return false
    }

    /**
     * Clears the session canary once stability is proven or upon clean exit.
     */
    static ClearCanary() {
        try {
            if FileExist(this.CanaryPath)
                FileDelete(this.CanaryPath)
        }
    }

    /**
     * Restores all hardware parameters to safe factory VBIOS defaults.
     * @param {NvmlDevice} gpu - Active GPU device instance.
     */
    static RecoverToSafeDefaults(gpu) {
        try gpu.ResetClockOffsets()
        try gpu.ResetGpuClocks()
        try gpu.ResetFansToAuto()
        try gpu.ResetPowerLimit()
        try gpu.SetTargetTemp(80)
    }

    /**
     * Sanitizes and validates a requested power limit against GPU VBIOS constraints.
     * @param {*} input - User input value.
     * @param {Number} minP - Minimum supported watts.
     * @param {Number} maxP - Maximum supported watts.
     * @returns {Number} Validated wattage.
     * @throws {ValueError} If input is non-numeric or out of bounds.
     */
    static ValidatePower(input, minP, maxP) {
        clean := Trim(String(input))
        if !RegExMatch(clean, "^-?\d+(\.\d+)?$")
            throw ValueError("Power limit must be a valid number.")
        val := Round(Number(clean), 1)
        if (val < minP || val > maxP)
            throw ValueError(Format("Power limit {} W is outside supported hardware range ({} W - {} W).", val, minP, maxP))
        return val
    }

    /**
     * Sanitizes and validates fan speed against stall thresholds.
     * @param {*} input - User input percentage.
     * @param {Integer} minFan - Minimum fan threshold (typically 30%).
     * @param {Integer} maxFan - Maximum fan threshold (100%).
     * @returns {Integer} Validated percentage.
     * @throws {ValueError} If input is invalid.
     */
    static ValidateFanSpeed(input, minFan, maxFan) {
        clean := Trim(String(input))
        if !RegExMatch(clean, "^\d+$")
            throw ValueError("Fan speed must be a whole number percentage.")
        val := Integer(clean)
        if (val < minFan || val > maxFan)
            throw ValueError(Format("Fan speed {}% is outside safe range ({}% - {}%). Speeds below {}% can stall fans.", val, minFan, maxFan, minFan))
        return val
    }

    /**
     * Sanitizes and checks Core Clock Offset with high-offset warning.
     * @param {*} input - User input MHz.
     * @returns {Integer} Validated offset.
     */
    static ValidateCoreOffset(input) {
        clean := Trim(String(input))
        if !RegExMatch(clean, "^-?\d+$")
            throw ValueError("Core clock offset must be an integer (e.g. +50, -100).")
        val := Integer(clean)
        if (val < -1000 || val > 1000)
            throw ValueError(Format("Core clock offset {} MHz exceeds hardware limits (-1000 to +1000 MHz).", val))
        if (val > 300) {
            btn := MsgBox(Format("Core offset +{} MHz is exceptionally high and may cause an immediate GPU driver crash or display freeze.`n`nAre you sure you want to apply this offset?", val),
                "High Clock Warning", "YesNo Icon!")
            if (btn != "Yes")
                throw ValueError("Operation canceled by user.")
        }
        return val
    }

    /**
     * Sanitizes and checks Memory Clock Offset with high-offset warning.
     * @param {*} input - User input MHz.
     * @returns {Integer} Validated offset.
     */
    static ValidateMemOffset(input) {
        clean := Trim(String(input))
        if !RegExMatch(clean, "^-?\d+$")
            throw ValueError("Memory clock offset must be an integer (e.g. +500, -200).")
        val := Integer(clean)
        if (val < -2000 || val > 6000)
            throw ValueError(Format("Memory clock offset {} MHz exceeds hardware limits (-2000 to +6000 MHz).", val))
        if (val > 1500) {
            btn := MsgBox(Format("Memory offset +{} MHz is very aggressive and may cause memory artifacts or system reboot.`n`nDo you want to proceed?", val),
                "Aggressive Memory Offset", "YesNo Icon!")
            if (btn != "Yes")
                throw ValueError("Operation canceled by user.")
        }
        return val
    }

    /**
     * Sanitizes target temperature.
     * @param {*} input - User input °C.
     * @returns {Integer} Validated temperature.
     */
    static ValidateTargetTemp(input) {
        clean := Trim(String(input))
        if !RegExMatch(clean, "^\d+$")
            throw ValueError("Target temperature must be a whole number between 60 and 90 °C.")
        val := Integer(clean)
        if (val < 60 || val > 90)
            throw ValueError(Format("Target temperature {} °C is outside safe operational range (60 - 90 °C).", val))
        return val
    }
}

/**
 * Low-level Win32 DllCall wrapper around the NVIDIA Management Library (nvml.dll).
 * Provides in-memory C-API communication with sub-millisecond execution.
 */
class NVML {
    static hModule := 0
    static Functions := Map()

    /**
     * Loads nvml.dll and initializes the library via nvmlInit_v2.
     * @returns {Boolean} True on success.
     * @throws {Error} If DLL loading or initialization fails.
     */
    static Init() {
        if this.hModule
            return true

        dllPath := "nvml.dll"
        if FileExist(A_WinDir "\System32\nvml.dll")
            dllPath := A_WinDir "\System32\nvml.dll"
        else if FileExist("C:\Program Files\NVIDIA Corporation\NVSMI\nvml.dll")
            dllPath := "C:\Program Files\NVIDIA Corporation\NVSMI\nvml.dll"

        this.hModule := DllCall("LoadLibrary", "Str", dllPath, "Ptr")
        if !this.hModule
            throw Error("Failed to load nvml.dll.`nPlease ensure NVIDIA graphics drivers are installed.")

        r := this.Call("nvmlInit_v2", "Int")
        if (r != 0)
            throw Error("NVML initialization failed: " this.ErrorString(r))
        return true
    }

    /**
     * Shuts down NVML and unloads nvml.dll.
     */
    static Shutdown() {
        if (this.hModule) {
            try this.Call("nvmlShutdown", "Int")
            DllCall("FreeLibrary", "Ptr", this.hModule)
            this.hModule := 0
            this.Functions.Clear()
        }
    }

    /**
     * Resolves and caches a function pointer from nvml.dll.
     * @param {String} name - Exported symbol name.
     * @returns {Integer} Function address pointer.
     * @throws {Error} If symbol is not found.
     */
    static GetProc(name) {
        if this.Functions.Has(name)
            return this.Functions[name]
        p := DllCall("GetProcAddress", "Ptr", this.hModule, "AStr", name, "Ptr")
        if !p
            throw Error("NVML function not found: " name)
        return this.Functions[name] := p
    }

    /**
     * Invokes an NVML function pointer with typed arguments.
     * @param {String} name - Exported symbol name.
     * @param {Array} argTypes - Variable arguments for DllCall.
     * @returns {*} Return value from DllCall.
     */
    static Call(name, argTypes*) {
        fn := this.GetProc(name)
        return DllCall(fn, argTypes*)
    }

    /**
     * Translates an NVML error code into a human-readable description.
     * @param {Integer} code - NVML error code.
     * @returns {String} Descriptive error message.
     */
    static ErrorString(code) {
        try {
            fn := this.GetProc("nvmlErrorString")
            ptr := DllCall(fn, "Int", code, "Ptr")
            if ptr
                return StrGet(ptr, "CP0")
        }
        return "NVML Error Code " code
    }
}

/**
 * Object-oriented controller for querying telemetry and configuring hardware settings
 * for a specific NVIDIA GPU via NVML. Pre-allocates reusable struct buffers to avoid
 * memory churn during polling.
 */
class NvmlDevice {
    Index := 0
    Handle := 0
    Name := ""
    DriverVersion := ""
    NumFans := 0
    MinFan := 30
    MaxFan := 100
    MinPower := 100.0
    MaxPower := 380.0
    DefaultPower := 370.0
    ManualFanActive := false

    ; Pre-allocated reusable buffers to avoid heap fragmentation and GC pressure
    utilBuf := Buffer(8, 0)
    memBuf := Buffer(40, 0)
    offsetBuf := Buffer(24, 0)

    /**
     * Connects to a GPU device handle by index and caches device metadata.
     * @param {Integer} index - Zero-based GPU index (default 0).
     */
    __New(index := 0) {
        NVML.Init()
        this.Index := index

        hDev := 0
        r := NVML.Call("nvmlDeviceGetHandleByIndex_v2", "UInt", index, "PtrP", &hDev, "Int")
        if r != 0
            throw Error("Failed to get GPU device handle: " NVML.ErrorString(r))
        this.Handle := hDev

        ; Device Name
        nameBuf := Buffer(96, 0)
        NVML.Call("nvmlDeviceGetName", "Ptr", this.Handle, "Ptr", nameBuf, "UInt", 96, "Int")
        this.Name := StrGet(nameBuf, "UTF-8")

        ; Driver Version
        verBuf := Buffer(80, 0)
        NVML.Call("nvmlSystemGetDriverVersion", "Ptr", verBuf, "UInt", 80, "Int")
        this.DriverVersion := StrGet(verBuf, "UTF-8")

        ; Fan Count & Constraints
        numFans := 0
        NVML.Call("nvmlDeviceGetNumFans", "Ptr", this.Handle, "UIntP", &numFans, "Int")
        this.NumFans := numFans

        minFan := 30, maxFan := 100
        NVML.Call("nvmlDeviceGetMinMaxFanSpeed", "Ptr", this.Handle, "UIntP", &minFan, "UIntP", &maxFan, "Int")
        this.MinFan := minFan
        this.MaxFan := maxFan

        ; Power Limits (converted milliwatts -> watts)
        minP := 0, maxP := 0, defP := 0
        NVML.Call("nvmlDeviceGetPowerManagementLimitConstraints", "Ptr", this.Handle, "UIntP", &minP, "UIntP", &maxP, "Int")
        NVML.Call("nvmlDeviceGetPowerManagementDefaultLimit", "Ptr", this.Handle, "UIntP", &defP, "Int")
        this.MinPower := Round(minP / 1000.0, 1)
        this.MaxPower := Round(maxP / 1000.0, 1)
        this.DefaultPower := Round(defP / 1000.0, 1)

        ; Pre-initialize struct version headers
        NumPut("UInt", 40 | (2 << 24), this.memBuf, 0)   ; 0x02000028 (NvmlMemory_v2)
        NumPut("UInt", 24 | (1 << 24), this.offsetBuf, 0) ; 0x01000018 (NvmlClockOffset_v1)
    }

    /**
     * Reads current, default, min, and max power limits.
     * @returns {Map} Map with keys "Min", "Max", "Default", "Current" in Watts.
     */
    GetPowerLimits() {
        curP := 0
        r := NVML.Call("nvmlDeviceGetPowerManagementLimit", "Ptr", this.Handle, "UIntP", &curP, "Int")
        if r != 0
            return false
        return Map(
            "Min", this.MinPower,
            "Max", this.MaxPower,
            "Default", this.DefaultPower,
            "Current", Round(curP / 1000.0, 1)
        )
    }

    /**
     * Sets the GPU power management limit in Watts.
     * @param {Number} watts - Requested power limit in Watts.
     * @returns {Number} Verified active power limit in Watts.
     * @throws {ValueError|Error} If out of range or insufficient permissions.
     */
    SetPowerLimit(watts) {
        watts := Round(Number(watts), 1)
        if (watts < this.MinPower || watts > this.MaxPower)
            throw ValueError(Format("Power limit {} W is outside supported GPU range ({} - {} W).", watts, this.MinPower, this.MaxPower))

        milliwatts := Integer(watts * 1000)
        r := NVML.Call("nvmlDeviceSetPowerManagementLimit", "Ptr", this.Handle, "UInt", milliwatts, "Int")
        if r != 0 {
            errStr := NVML.ErrorString(r)
            if (r == 7 || InStr(errStr, "Permission"))
                throw Error("Administrator privileges are required to change power limits.`nPlease restart the script as Administrator.")
            throw Error(Format("Failed to set power limit ({} W): {}", watts, errStr))
        }

        Sleep(80)
        limits := this.GetPowerLimits()
        return limits ? limits["Current"] : watts
    }

    /**
     * Resets the GPU power limit to its factory VBIOS default.
     * @returns {Number} Verified active power limit in Watts.
     */
    ResetPowerLimit() {
        return this.SetPowerLimit(this.DefaultPower)
    }

    /**
     * Queries the target temperature threshold specification.
     * @returns {Integer} Target temperature in °C (default 80 °C).
     */
    GetTargetTemp() {
        targetTemp := 0
        ; Threshold 5 corresponds to NVML_TEMPERATURE_THRESHOLD_GPU_MAX / Target Temp
        r := NVML.Call("nvmlDeviceGetTemperatureThreshold", "Ptr", this.Handle, "UInt", 5, "UIntP", &targetTemp, "Int")
        return (r == 0 && targetTemp > 0) ? targetTemp : 80
    }

    /**
     * Sets the GPU thermal slowdown target temperature.
     * @param {Integer} celsius - Requested temperature (60 - 90 °C).
     * @returns {Boolean} True on success.
     */
    SetTargetTemp(celsius) {
        celsius := Integer(celsius)
        if (celsius < 60 || celsius > 90)
            throw ValueError(Format("Target temperature {} °C is outside safe range (60 - 90 °C).", celsius))

        r := NVML.Call("nvmlDeviceSetTemperatureThreshold", "Ptr", this.Handle, "UInt", 5, "UInt", celsius, "Int")
        if r != 0 {
            errStr := NVML.ErrorString(r)
            if (r == 7 || InStr(errStr, "Permission"))
                throw Error("Administrator privileges are required to set target temperature.")
            throw Error(Format("Failed to set target temperature to {} °C: {}", celsius, errStr))
        }
        return true
    }

    /**
     * Polls complete live hardware telemetry in a single sub-millisecond pass using pre-allocated buffers.
     * @returns {Map} Live telemetry data.
     */
    GetTelemetry() {
        ; Power Usage & Limit
        pwrDraw := 0, curLimit := 0
        NVML.Call("nvmlDeviceGetPowerUsage", "Ptr", this.Handle, "UIntP", &pwrDraw, "Int")
        NVML.Call("nvmlDeviceGetPowerManagementLimit", "Ptr", this.Handle, "UIntP", &curLimit, "Int")

        ; Temperature
        temp := 0
        NVML.Call("nvmlDeviceGetTemperature", "Ptr", this.Handle, "UInt", 0, "UIntP", &temp, "Int")

        ; Clocks
        coreClk := 0, memClk := 0
        NVML.Call("nvmlDeviceGetClockInfo", "Ptr", this.Handle, "UInt", 0, "UIntP", &coreClk, "Int")
        NVML.Call("nvmlDeviceGetClockInfo", "Ptr", this.Handle, "UInt", 2, "UIntP", &memClk, "Int")

        ; Utilization (reusing this.utilBuf)
        NVML.Call("nvmlDeviceGetUtilizationRates", "Ptr", this.Handle, "Ptr", this.utilBuf, "Int")
        gpuLoad := NumGet(this.utilBuf, 0, "UInt")
        memUtil := NumGet(this.utilBuf, 4, "UInt")

        ; Memory v2 (reusing this.memBuf)
        NVML.Call("nvmlDeviceGetMemoryInfo_v2", "Ptr", this.Handle, "Ptr", this.memBuf, "Int")
        totalBytes := NumGet(this.memBuf, 8, "UInt64")
        usedBytes := NumGet(this.memBuf, 32, "UInt64")

        ; Fan Speeds
        fanSpeeds := []
        Loop this.NumFans {
            spd := 0
            NVML.Call("nvmlDeviceGetFanSpeed_v2", "Ptr", this.Handle, "UInt", A_Index - 1, "UIntP", &spd, "Int")
            fanSpeeds.Push(spd)
        }

        return Map(
            "Name", this.Name,
            "Driver", this.DriverVersion,
            "PowerDraw", Round(pwrDraw / 1000.0, 1),
            "PowerLimit", Round(curLimit / 1000.0, 1),
            "Temperature", temp,
            "CoreClock", coreClk,
            "MemoryClock", memClk,
            "GpuLoad", gpuLoad,
            "MemUtil", memUtil,
            "MemoryUsedGB", Round(usedBytes / (1024**3), 2),
            "MemoryTotalGB", Round(totalBytes / (1024**3), 1),
            "FanSpeeds", fanSpeeds
        )
    }

    /**
     * Sets a manual fan speed percentage across all fans or a specific fan.
     * @param {Integer} percent - Speed percentage (MinFan - MaxFan).
     * @param {Integer} fanIdx - Specific fan index, or -1 for all fans.
     * @returns {Boolean} True on success.
     */
    SetFanSpeed(percent, fanIdx := -1) {
        percent := Integer(percent)
        if (percent < this.MinFan || percent > this.MaxFan)
            throw ValueError(Format("Fan speed {}% is outside supported range ({}% - {}%).", percent, this.MinFan, this.MaxFan))

        targetFans := (fanIdx == -1) ? [0, 1] : [fanIdx]
        for idx in targetFans {
            if (idx < this.NumFans) {
                r := NVML.Call("nvmlDeviceSetFanSpeed_v2", "Ptr", this.Handle, "UInt", idx, "UInt", percent, "Int")
                if r != 0 {
                    errStr := NVML.ErrorString(r)
                    if (r == 7 || InStr(errStr, "Permission"))
                        throw Error("Administrator privileges are required to change fan speeds.")
                    throw Error(Format("Failed to set Fan {} to {}%: {}", idx, percent, errStr))
                }
            }
        }
        this.ManualFanActive := true
        return true
    }

    /**
     * Restores all fans to the automatic VBIOS thermal curve.
     * @returns {Boolean} True on success.
     */
    ResetFansToAuto() {
        Loop this.NumFans {
            r := NVML.Call("nvmlDeviceSetDefaultFanSpeed_v2", "Ptr", this.Handle, "UInt", A_Index - 1, "Int")
            if r != 0 {
                errStr := NVML.ErrorString(r)
                if (r == 7 || InStr(errStr, "Permission"))
                    throw Error("Administrator privileges are required to reset fan speeds.")
                throw Error(Format("Failed to restore Fan {} to Auto: {}", A_Index - 1, errStr))
            }
        }
        this.ManualFanActive := false
        return true
    }

    /**
     * Queries current clock offsets and supported offset ranges for Core and Memory.
     * Uses pre-allocated nvmlClockOffset_v1_t struct (size 24, version 0x01000018).
     * @returns {Map} Map containing offsets and bounds in MHz.
     */
    GetClockOffsets() {
        NumPut("UInt", 24 | (1 << 24), this.offsetBuf, 0) ; 0x01000018
        NumPut("UInt", 0, this.offsetBuf, 4)               ; NVML_CLOCK_GRAPHICS
        NumPut("UInt", 0, this.offsetBuf, 8)               ; P0
        rC := NVML.Call("nvmlDeviceGetClockOffsets", "Ptr", this.Handle, "Ptr", this.offsetBuf, "Int")
        coreOffset := (rC == 0) ? NumGet(this.offsetBuf, 12, "Int") : 0
        coreMin := (rC == 0) ? NumGet(this.offsetBuf, 16, "Int") : -1000
        coreMax := (rC == 0) ? NumGet(this.offsetBuf, 20, "Int") : 1000

        NumPut("UInt", 2, this.offsetBuf, 4)               ; NVML_CLOCK_MEM
        NumPut("UInt", 0, this.offsetBuf, 8)               ; P0
        rM := NVML.Call("nvmlDeviceGetClockOffsets", "Ptr", this.Handle, "Ptr", this.offsetBuf, "Int")
        memOffset := (rM == 0) ? NumGet(this.offsetBuf, 12, "Int") : 0
        memMin := (rM == 0) ? NumGet(this.offsetBuf, 16, "Int") : -2000
        memMax := (rM == 0) ? NumGet(this.offsetBuf, 20, "Int") : 6000

        return Map(
            "CoreOffset", coreOffset, "CoreMin", coreMin, "CoreMax", coreMax,
            "MemOffset", memOffset, "MemMin", memMin, "MemMax", memMax
        )
    }

    /**
     * Applies a Core Clock Offset in MHz.
     * @param {Integer} mhz - Requested offset.
     * @returns {Boolean} True on success.
     */
    SetCoreClockOffset(mhz) {
        mhz := Integer(mhz)
        NumPut("UInt", 24 | (1 << 24), this.offsetBuf, 0)
        NumPut("UInt", 0, this.offsetBuf, 4) ; NVML_CLOCK_GRAPHICS
        NumPut("UInt", 0, this.offsetBuf, 8) ; P0
        NumPut("Int", mhz, this.offsetBuf, 12)
        r := NVML.Call("nvmlDeviceSetClockOffsets", "Ptr", this.Handle, "Ptr", this.offsetBuf, "Int")
        if r != 0 {
            errStr := NVML.ErrorString(r)
            if (r == 7 || InStr(errStr, "Permission"))
                throw Error("Administrator privileges are required to set clock offsets.")
            throw Error(Format("Failed to set Core Clock Offset to {} MHz: {}", mhz, errStr))
        }
        return true
    }

    /**
     * Applies a Memory Clock Offset in MHz.
     * @param {Integer} mhz - Requested offset.
     * @returns {Boolean} True on success.
     */
    SetMemClockOffset(mhz) {
        mhz := Integer(mhz)
        NumPut("UInt", 24 | (1 << 24), this.offsetBuf, 0)
        NumPut("UInt", 2, this.offsetBuf, 4) ; NVML_CLOCK_MEM
        NumPut("UInt", 0, this.offsetBuf, 8) ; P0
        NumPut("Int", mhz, this.offsetBuf, 12)
        r := NVML.Call("nvmlDeviceSetClockOffsets", "Ptr", this.Handle, "Ptr", this.offsetBuf, "Int")
        if r != 0 {
            errStr := NVML.ErrorString(r)
            if (r == 7 || InStr(errStr, "Permission"))
                throw Error("Administrator privileges are required to set memory clock offsets.")
            throw Error(Format("Failed to set Memory Clock Offset to {} MHz: {}", mhz, errStr))
        }
        return true
    }

    /**
     * Resets both Core and Memory clock offsets to 0 MHz.
     * @returns {Boolean} True on success.
     */
    ResetClockOffsets() {
        this.SetCoreClockOffset(0)
        this.SetMemClockOffset(0)
        return true
    }

    /**
     * Locks the GPU core clock to a fixed frequency or range.
     * @param {Integer} maxClock - Upper clock limit in MHz.
     * @param {Integer} minClock - Optional lower clock limit in MHz (default 0).
     * @returns {Boolean} True on success.
     */
    LockGpuClocks(maxClock, minClock := 0) {
        maxClock := Integer(maxClock)
        minClock := Integer(minClock)
        r := NVML.Call("nvmlDeviceSetGpuLockedClocks", "Ptr", this.Handle, "UInt", minClock, "UInt", maxClock, "Int")
        if r != 0 {
            errStr := NVML.ErrorString(r)
            if (r == 7 || InStr(errStr, "Permission"))
                throw Error("Administrator privileges are required to lock GPU clocks.")
            throw Error("Failed to lock GPU clocks: " errStr)
        }
        return true
    }

    /**
     * Unlocks GPU clocks, restoring factory dynamic boost behaviour.
     * @returns {Boolean} True on success.
     */
    ResetGpuClocks() {
        r := NVML.Call("nvmlDeviceResetGpuLockedClocks", "Ptr", this.Handle, "Int")
        if r != 0 {
            errStr := NVML.ErrorString(r)
            if (r == 7 || InStr(errStr, "Permission"))
                throw Error("Administrator privileges are required to reset GPU clocks.")
            throw Error("Failed to reset GPU clocks: " errStr)
        }
        return true
    }
}

/**
 * Compact hardware monitor docked inside the primary monitor's taskbar.
 * Displays live GPU Load, Memory Controller Bandwidth, Temperature, Power, and VRAM.
 */
class TaskbarWidget {
    Gui := 0
    txtLine1 := 0
    txtLine2 := 0
    X := 0
    Y := 0
    W := 320
    H := 30
    WorkBottom := 0
    TaskbarHeight := 48
    IsCompact := false
    Controller := ""

    /**
     * Initializes widget window geometry and UI controls.
     */
    __New() {
        this.CalculateGeometry()
        this.BuildGui()
        this.RegisterWindowMessages()
    }

    /**
     * Associates the widget with the main controller instance and builds the context menu.
     * @param {NvControlGui} controller - The parent controller instance.
     */
    SetController(controller) {
        this.Controller := controller
        this.BuildContextMenu()
    }

    /**
     * Determines screen taskbar dimensions and centers widget vertically in the primary taskbar.
     */
    CalculateGeometry() {
        primaryMon := MonitorGetPrimary()
        MonitorGet(primaryMon, &sLeft, &sTop, &sRight, &sBottom)
        MonitorGetWorkArea(primaryMon, &wLeft, &wTop, &wRight, &wBottom)

        this.WorkBottom := wBottom
        this.TaskbarHeight := sBottom - wBottom
        if (this.TaskbarHeight <= 0)
            this.TaskbarHeight := 48

        this.W := this.IsCompact ? 390 : 320
        this.H := this.IsCompact ? 20 : 30

        ; Detect taskbar location on primary monitor and dock cleanly inside it
        if (sBottom > wBottom) {
            tbHeight := sBottom - wBottom
            this.X := sLeft + 12
            this.Y := wBottom + Round((tbHeight - this.H) / 2)
        } else if (wTop > sTop) {
            tbHeight := wTop - sTop
            this.X := sLeft + 12
            this.Y := sTop + Round((tbHeight - this.H) / 2)
        } else if (wLeft > sLeft) {
            this.X := sLeft + 6
            this.Y := sBottom - this.H - 12
        } else {
            this.X := sLeft + 12
            this.Y := sBottom - this.H - 8
        }

        ; Load persisted multi-monitor position if available and visible
        this.LoadPersistedPosition()
    }

    /**
     * Checks if coordinates fall within any active monitor's bounding box.
     * @param {Integer} x - X coordinate.
     * @param {Integer} y - Y coordinate.
     * @param {Integer} [w=100] - Window width.
     * @param {Integer} [h=30] - Window height.
     * @returns {Boolean} True if at least partially visible on a connected screen.
     */
    static IsOnScreen(x, y, w := 100, h := 30) {
        Loop MonitorGetCount() {
            MonitorGet(A_Index, &l, &t, &r, &b)
            if (x + w > l && x < r && y + h > t && y < b)
                return true
        }
        return false
    }

    /**
     * Loads previously saved widget position and mode from AppData.
     */
    LoadPersistedPosition() {
        iniPath := A_AppData "\NVcontrol\geometry.ini"
        if !FileExist(iniPath)
            iniPath := A_AppData "\nv-control\geometry.ini"
        if !FileExist(iniPath)
            return

        try {
            rawX := IniRead(iniPath, "Widget", "X", "")
            rawY := IniRead(iniPath, "Widget", "Y", "")
            rawCompact := IniRead(iniPath, "Widget", "Compact", "0")
            if (rawX != "" && rawY != "") {
                savedX := Integer(rawX)
                savedY := Integer(rawY)
                ; Ignore (0, 0) or uninitialized artifacts to prevent top-left glitch
                if !(savedX == 0 && savedY == 0) && TaskbarWidget.IsOnScreen(savedX, savedY, this.W, this.H) {
                    this.X := savedX
                    this.Y := savedY
                }
            }
            if (rawCompact = "1")
                this.IsCompact := true
        }
    }

    /**
     * Saves current widget position and compact state to AppData.
     */
    SavePersistedPosition() {
        dir := A_AppData "\NVcontrol"
        if !DirExist(dir)
            try DirCreate(dir)
        iniPath := dir "\geometry.ini"
        try {
            IniWrite(String(this.X), iniPath, "Widget", "X")
            IniWrite(String(this.Y), iniPath, "Widget", "Y")
            IniWrite(this.IsCompact ? "1" : "0", iniPath, "Widget", "Compact")
        }
    }

    /**
     * Constructs the frameless overlay GUI.
     */
    BuildGui() {
        this.Gui := Gui("+AlwaysOnTop -Caption +ToolWindow", "")
        this.Gui.BackColor := "141414"
        this.Gui.MarginX := 0
        this.Gui.MarginY := 0
        this.Gui.SetFont("s8 Bold cWhite", "Segoe UI")

        this.txtLine1 := this.Gui.AddText(Format("x0 y1 w{} h14 Center c00E5FF", this.W), "GPU: -- %  |  BW: -- %  |  -- °C")
        this.txtLine2 := this.Gui.AddText(Format("x0 y15 w{} h14 Center c76B900", this.W), "⚡ -- W / -- W  |  VRAM: -- / -- GB")

        this.txtLine1.OnEvent("DoubleClick", (*) => this.OnActivate())
        this.txtLine2.OnEvent("DoubleClick", (*) => this.OnActivate())

        if this.IsCompact {
            this.H := 20
            this.W := 390
            this.txtLine1.Move(0, 2, this.W, 16)
            this.txtLine2.Visible := false
        }
    }

    /**
     * Builds the right-click context menu.
     */
    BuildContextMenu() {
        wMenu := Menu()
        wMenu.Add("Open Controller", (*) => this.OnActivate())
        wMenu.Add("Refresh Stats", (*) => (this.Controller ? this.Controller.RefreshStats() : ""))
        wMenu.Add("Toggle 1-Line / 2-Line", (*) => this.ToggleCompact())
        wMenu.Add()
        wMenu.Add("Restore Auto Fans", (*) => (this.Controller ? this.Controller.ResetFansToAuto() : ""))
        wMenu.Add("Hide Taskbar Overlay", (*) => this.Hide())
        wMenu.Add("Exit", (*) => ExitApp())
        this.Gui.OnEvent("ContextMenu", (*) => wMenu.Show())
    }

    /**
     * Hooks Windows mouse messages for window dragging, double-click restoration,
     * and window move completion across monitors.
     */
    RegisterWindowMessages() {
        OnMessage(0x0201, (wp, lp, msg, hwnd) => this.HandleDrag(hwnd))
        OnMessage(0x0203, (wp, lp, msg, hwnd) => this.HandleDoubleClick(hwnd))
        OnMessage(0x00A3, (wp, lp, msg, hwnd) => this.HandleDoubleClick(hwnd))
        OnMessage(0x0232, (wp, lp, msg, hwnd) => this.OnExitSizeMove(hwnd))
    }

    /**
     * Handles dragging of the frameless window across monitors.
     * @param {Integer} hwnd - Handle of the clicked control.
     */
    HandleDrag(hwnd) {
        if (hwnd == this.Gui.Hwnd || hwnd == this.txtLine1.Hwnd || hwnd == this.txtLine2.Hwnd) {
            PostMessage(0xA1, 2, , this.Gui.Hwnd) ; WM_NCLBUTTONDOWN, HTCAPTION
        }
    }

    /**
     * WM_EXITSIZEMOVE handler. Fires when user finishes dragging or moving either the widget or controller window.
     * @param {Integer} hwnd - Window handle that completed sizing/moving.
     */
    OnExitSizeMove(hwnd) {
        if (this.Gui && hwnd == this.Gui.Hwnd)
            this.UpdatePosition(true)
        else if (this.Controller && this.Controller.Gui && hwnd == this.Controller.Gui.Hwnd)
            this.Controller.SavePosition()
    }

    /**
     * Updates in-memory X and Y coordinates from live window placement.
     * Strictly verifies window visibility and dimensions to prevent uninitialized 0,0 corruption.
     * @param {Boolean} [persist=false] - True to also flush to geometry.ini.
     */
    UpdatePosition(persist := false) {
        if (!this.Gui || !this.IsVisible())
            return
        try {
            this.Gui.GetPos(&curX, &curY, &curW, &curH)
            if (curW > 0 && curH > 0 && curX > -30000 && curY > -30000 && !(curX == 0 && curY == 0)) {
                this.X := curX
                this.Y := curY
                if persist
                    this.SavePersistedPosition()
            }
        }
    }

    /**
     * Handles double-clicking on the widget to restore the main GUI.
     * @param {Integer} hwnd - Handle of the clicked control.
     */
    HandleDoubleClick(hwnd) {
        if (hwnd == this.Gui.Hwnd || hwnd == this.txtLine1.Hwnd || hwnd == this.txtLine2.Hwnd) {
            this.OnActivate()
        }
    }

    /**
     * Activates and focuses the main controller window.
     */
    OnActivate() {
        if this.IsVisible()
            this.UpdatePosition(true)
        if this.Controller
            this.Controller.Restore()
    }

    /**
     * Displays the overlay without stealing focus at its exact placed coordinates.
     */
    Show() {
        this.Gui.Show(Format("x{} y{} w{} h{} NoActivate", this.X, this.Y, this.W, this.H))
    }

    /**
     * Hides the overlay window while recording its last position.
     */
    Hide() {
        if this.IsVisible()
            this.UpdatePosition(true)
        this.Gui.Hide()
    }

    /**
     * Checks if the overlay window is currently visible.
     * @returns {Boolean} True if visible.
     */
    IsVisible() {
        return WinExist("ahk_id " this.Gui.Hwnd) ? true : false
    }

    /**
     * Toggles overlay visibility.
     */
    Toggle() {
        if this.IsVisible()
            this.Hide()
        else
            this.Show()
    }

    /**
     * Toggles between standard 2-line mode (30px) and ultra-compact 1-line mode (20px),
     * preserving position and monitor placement without snapping to primary screen.
     */
    ToggleCompact() {
        this.UpdatePosition(false)
        this.IsCompact := !this.IsCompact
        if this.IsCompact {
            this.H := 20
            this.W := 390
            this.Y += 5
            this.txtLine1.Move(0, 2, this.W, 16)
            this.txtLine2.Visible := false
        } else {
            this.H := 30
            this.W := 320
            this.Y -= 5
            this.txtLine1.Move(0, 1, this.W, 14)
            this.txtLine2.Move(0, 15, this.W, 14)
            this.txtLine2.Visible := true
        }
        this.Gui.Move(this.X, this.Y, this.W, this.H)
        this.SavePersistedPosition()
        if this.Controller
            this.Controller.RefreshStats()
    }

    /**
     * Updates widget text with live telemetry metrics.
     * @param {Map} t - Telemetry dictionary from NvmlDevice.
     */
    Update(t) {
        if this.IsCompact {
            this.txtLine1.Text := Format("GPU: {}% | BW: {}% | {}°C | {:.0f}W/{:.0f}W | {:.1f}G",
                t["GpuLoad"], t["MemUtil"], t["Temperature"], t["PowerDraw"], t["PowerLimit"], t["MemoryUsedGB"])
        } else {
            this.txtLine1.Text := Format("GPU: {}%  |  BW: {}%  |  {}°C", t["GpuLoad"], t["MemUtil"], t["Temperature"])
            this.txtLine2.Text := Format("{:.1f}W / {:.1f}W  |  VRAM: {:.1f}/{:.0f} GB",
                t["PowerDraw"], t["PowerLimit"], t["MemoryUsedGB"], t["MemoryTotalGB"])
        }
    }
}

/**
 * Primary user interface for monitoring telemetry, setting power limits,
 * configuring fan speeds, adjusting clock offsets, and managing profiles.
 */
class NvControlGui {
    Gpu := 0
    Widget := 0
    OwnerGui := 0
    Gui := 0
    TimerCallback := 0
    IsUpdating := false

    ; Layout metrics
    GroupWidth := 608
    InnerWidth := 576
    ActionBtnWidth := 278

    ; Power cache
    pMin := 100
    pMax := 380
    pDef := 370
    pCur := 370

    ; Controls
    txtGpuName := 0
    txtPowerDraw := 0
    txtTemp := 0
    txtClocks := 0
    txtVram := 0
    txtUtil := 0
    txtBandwidth := 0
    txtPowerRange := 0
    txtFanStatus := 0

    chkAuto := 0
    chkStartup := 0
    chkShowWidget := 0

    sldPower := 0
    edtPower := 0

    sldCoreOffset := 0
    edtCoreOffset := 0
    sldMemOffset := 0
    edtMemOffset := 0
    edtLockClock := 0

    sldFan := 0
    edtFan := 0
    edtTargetTemp := 0

    sb := 0
    LastX := ""
    LastY := ""

    /**
     * Instantiates controller window, binds hardware instance, and builds UI.
     * @param {NvmlDevice} gpu - The active GPU device instance.
     * @param {TaskbarWidget} widget - The active taskbar overlay instance.
     */
    __New(gpu, widget) {
        this.Gpu := gpu
        this.Widget := widget

        limits := this.Gpu.GetPowerLimits()
        if limits {
            this.pMin := Round(limits["Min"])
            this.pMax := Round(limits["Max"])
            this.pDef := Round(limits["Default"])
            this.pCur := Round(limits["Current"])
        }

        this.LoadPersistedPosition()
        this.BuildWindow()
        this.TimerCallback := () => this.RefreshStats()
    }

    /**
     * Loads previously saved window position from AppData.
     */
    LoadPersistedPosition() {
        iniPath := A_AppData "\NVcontrol\geometry.ini"
        if !FileExist(iniPath)
            iniPath := A_AppData "\nv-control\geometry.ini"
        if !FileExist(iniPath)
            return

        try {
            rawX := IniRead(iniPath, "Window", "X", "")
            rawY := IniRead(iniPath, "Window", "Y", "")
            if (rawX != "" && rawY != "") {
                savedX := Integer(rawX)
                savedY := Integer(rawY)
                if TaskbarWidget.IsOnScreen(savedX, savedY, this.GroupWidth, 300) {
                    this.LastX := savedX
                    this.LastY := savedY
                }
            }
        }
    }

    /**
     * Saves active window coordinates to AppData.
     */
    SavePosition() {
        if (this.Gui && WinExist("ahk_id " this.Gui.Hwnd)) {
            try {
                this.Gui.GetPos(&curX, &curY, &curW, &curH)
                if (curW > 0 && curH > 0 && curX > -30000 && curY > -30000 && !(curX == 0 && curY == 0)) {
                    this.LastX := curX
                    this.LastY := curY
                    dir := A_AppData "\NVcontrol"
                    if !DirExist(dir)
                        try DirCreate(dir)
                    iniPath := dir "\geometry.ini"
                    try {
                        IniWrite(String(curX), iniPath, "Window", "X")
                        IniWrite(String(curY), iniPath, "Window", "Y")
                    }
                }
            }
        }
    }

    /**
     * Constructs the 644px wide GUI layout with pixel-aligned controls.
     */
    BuildWindow() {
        this.OwnerGui := Gui()
        this.Gui := Gui("+Owner" this.OwnerGui.Hwnd " -MaximizeBox", "NVcontrol - GPU Hardware & Power Controller")
        this.Gui.SetFont("s9", "Segoe UI")
        this.Gui.MarginX := 18
        this.Gui.MarginY := 14

        grpW := this.GroupWidth
        innerW := this.InnerWidth
        actionBtnW := this.ActionBtnWidth

        ; Non-Admin Warning Banner (if user declined UAC)
        if !A_IsAdmin {
            this.Gui.SetFont("s9 c8A5D00 Bold")
            this.Gui.AddText(Format("w{} Center", grpW), "⚠ Running in Read-Only Mode (Administrator privileges required to change settings)")
            btnElevate := this.Gui.AddButton(Format("w{} h26", grpW), "Restart as Administrator")
            btnElevate.OnEvent("Click", (*) => this.RestartAsAdmin())
            this.Gui.SetFont("s9 cDefault Norm")
        }

        ; Section 1: GPU Status
        this.Gui.AddGroupBox(Format("w{} h168", grpW), "GPU Status")
        this.txtGpuName := this.Gui.AddText(Format("x34 yp+24 w{}", innerW), Format("GPU 0: {} (Driver: {})", this.Gpu.Name, this.Gpu.DriverVersion))
        this.txtGpuName.SetFont("Bold")

        colW := 275
        this.txtPowerDraw := this.Gui.AddText(Format("x34 yp+26 w{}", colW), "Power Draw: -- W / -- W")
        this.txtTemp      := this.Gui.AddText(Format("x335 yp w{}", colW), "Temp: -- °C (Fans: --% / --%)")

        this.txtClocks    := this.Gui.AddText(Format("x34 yp+24 w{}", colW), "Clocks: Core -- MHz | Mem -- MHz")
        this.txtVram      := this.Gui.AddText(Format("x335 yp w{}", colW), "VRAM: -- / -- GB")

        this.txtUtil      := this.Gui.AddText(Format("x34 yp+24 w{}", colW), "GPU Load: -- %")
        this.txtBandwidth := this.Gui.AddText(Format("x335 yp w{}", colW), "Mem Controller / BW: -- %")

        ; Checkbox row: Auto-Refresh, Start with Windows, Taskbar Widget, Refresh Now
        this.chkAuto := this.Gui.AddCheckbox("x34 yp+28 w120", "Auto-Refresh (1s)")
        this.chkAuto.Value := 1
        this.chkAuto.OnEvent("Click", (ctrl, *) => this.ToggleAutoRefresh(ctrl.Value))

        this.chkStartup := this.Gui.AddCheckbox("x158 yp w135", "Start with Windows")
        this.chkStartup.Value := StartupManager.IsEnabled() ? 1 : 0
        this.chkStartup.OnEvent("Click", (ctrl, *) => this.ToggleStartup(ctrl.Value))

        this.chkShowWidget := this.Gui.AddCheckbox("x298 yp w185", "Taskbar Mini-Overlay")
        this.chkShowWidget.Value := 1
        this.chkShowWidget.OnEvent("Click", (ctrl, *) => this.ToggleTaskbarOption(ctrl.Value))

        btnRefresh := this.Gui.AddButton("x490 yp-4 w120 h26", "Refresh Now")
        btnRefresh.OnEvent("Click", (*) => this.RefreshStats())

        ; Section 2: Power Limit Control
        this.Gui.AddGroupBox(Format("x18 y+14 w{} h185", grpW), "Power Limit Control")
        this.txtPowerRange := this.Gui.AddText(Format("x34 yp+24 w{} Center", innerW),
            Format("Range: {} W - {} W   |   VBIOS Default: {} W   |   Current: {} W", this.pMin, this.pMax, this.pDef, this.pCur))

        sliderW := innerW - 86 ; 490px
        this.sldPower := this.Gui.AddSlider(Format("x34 yp+26 w{} Thick20 ToolTip Range{}-{}", sliderW, this.pMin, this.pMax), this.pCur)
        this.edtPower := this.Gui.AddEdit("x530 yp-2 w55 h26 Center Number", this.pCur)
        this.Gui.AddText("x590 yp+4 w20", "W")

        this.sldPower.OnEvent("Change", (ctrl, *) => this.edtPower.Value := ctrl.Value)
        this.edtPower.OnEvent("Change", (ctrl, *) => this.OnEditPowerChange(ctrl.Value))

        ; Quick Presets
        this.Gui.AddText("x34 yp+36 w55", "Presets:")
        pStep1 := Round(this.pMin + (this.pMax - this.pMin) * 0.2)
        pStep2 := Round(this.pMin + (this.pMax - this.pMin) * 0.4)
        pStep3 := Round(this.pMin + (this.pMax - this.pMin) * 0.6)
        pStep4 := Round(this.pMin + (this.pMax - this.pMin) * 0.8)

        pBtnW := 93
        pGap := 10
        btnP1 := this.Gui.AddButton(Format("x94 yp-4 w{} h26", pBtnW), pStep1 " W")
        btnP1.OnEvent("Click", (*) => this.SetPowerSliderValue(pStep1))

        btnP2 := this.Gui.AddButton(Format("x+{} yp w{} h26", pGap, pBtnW), pStep2 " W")
        btnP2.OnEvent("Click", (*) => this.SetPowerSliderValue(pStep2))

        btnP3 := this.Gui.AddButton(Format("x+{} yp w{} h26", pGap, pBtnW), pStep3 " W")
        btnP3.OnEvent("Click", (*) => this.SetPowerSliderValue(pStep3))

        btnP4 := this.Gui.AddButton(Format("x+{} yp w{} h26", pGap, pBtnW), pStep4 " W")
        btnP4.OnEvent("Click", (*) => this.SetPowerSliderValue(pStep4))

        btnPDef := this.Gui.AddButton(Format("x+{} yp w{} h26", pGap, pBtnW + 15), "Default")
        btnPDef.OnEvent("Click", (*) => this.SetPowerSliderValue(this.pDef))

        btnApplyPower := this.Gui.AddButton(Format("x34 yp+38 w{} h34 Default", actionBtnW), "✔ Apply Power Limit")
        btnApplyPower.SetFont("Bold")
        btnApplyPower.OnEvent("Click", (*) => this.ApplyPowerLimit())

        btnResetPower := this.Gui.AddButton(Format("x332 yp w{} h34", actionBtnW), "↺ Reset to VBIOS Default")
        btnResetPower.OnEvent("Click", (*) => this.ResetPowerLimit())

        ; Section 3: Clock Offsets & Lock
        offsets := this.Gpu.GetClockOffsets()
        initCore := offsets["CoreOffset"]
        initMem := offsets["MemOffset"]

        this.Gui.AddGroupBox(Format("x18 y+14 w{} h145", grpW), "Clock Offsets & Lock")

        this.Gui.AddText("x34 yp+25 w125", "Core Clock Offset:")
        this.sldCoreOffset := this.Gui.AddSlider("x162 yp-4 w245 ToolTip Range-500-500", initCore)
        this.edtCoreOffset := this.Gui.AddEdit("x415 yp w50 h24 Center", initCore)
        this.Gui.AddText("x470 yp+3 w28", "MHz")
        btnApplyCore := this.Gui.AddButton("x502 yp-3 w108 h25", "Apply Core")
        btnApplyCore.OnEvent("Click", (*) => this.ApplyCoreOffset())

        this.sldCoreOffset.OnEvent("Change", (ctrl, *) => this.edtCoreOffset.Value := ctrl.Value)
        this.edtCoreOffset.OnEvent("Change", (ctrl, *) => this.OnEditCoreChange(ctrl.Value))

        this.Gui.AddText("x34 yp+34 w125", "Memory Offset:")
        this.sldMemOffset := this.Gui.AddSlider("x162 yp-4 w245 ToolTip Range-1000-2000", initMem)
        this.edtMemOffset := this.Gui.AddEdit("x415 yp w50 h24 Center", initMem)
        this.Gui.AddText("x470 yp+3 w28", "MHz")
        btnApplyMem := this.Gui.AddButton("x502 yp-3 w108 h25", "Apply Mem")
        btnApplyMem.OnEvent("Click", (*) => this.ApplyMemOffset())

        this.sldMemOffset.OnEvent("Change", (ctrl, *) => this.edtMemOffset.Value := ctrl.Value)
        this.edtMemOffset.OnEvent("Change", (ctrl, *) => this.OnEditMemChange(ctrl.Value))

        this.Gui.AddText("x34 yp+34 w115", "Lock Core Clock:")
        this.edtLockClock := this.Gui.AddEdit("x152 yp-3 w55 h25 Center Number", "1800")
        this.Gui.AddText("x212 yp+3 w28", "MHz")
        btnLockClock := this.Gui.AddButton("x245 yp-3 w95 h25", "Lock Clock")
        btnLockClock.OnEvent("Click", (*) => this.ApplyLockClock())

        btnUnlockClock := this.Gui.AddButton("x348 yp w115 h25", "↺ Unlock Clocks")
        btnUnlockClock.OnEvent("Click", (*) => this.ApplyResetClock())

        btnResetOffsets := this.Gui.AddButton("x471 yp w139 h25", "↺ Reset Offsets (0)")
        btnResetOffsets.OnEvent("Click", (*) => this.ApplyResetOffsets())

        ; Section 4: Fan & Thermal Control
        targetTemp := this.Gpu.GetTargetTemp()
        this.Gui.AddGroupBox(Format("x18 y+14 w{} h155", grpW), "Fan & Thermal Control")

        this.txtFanStatus := this.Gui.AddText(Format("x34 yp+24 w{}", innerW),
            Format("Status: Auto (VBIOS Thermal Curve)  |  Speeds: Fan 0: --%, Fan 1: --%  |  Target: {} °C", targetTemp))

        this.Gui.AddText("x34 yp+26 w125", "Manual Fan Speed:")
        this.sldFan := this.Gui.AddSlider("x162 yp-4 w245 ToolTip Range30-100", 50)
        this.edtFan := this.Gui.AddEdit("x415 yp w50 h24 Center Number", "50")
        this.Gui.AddText("x470 yp+3 w20", "%")
        btnApplyFan := this.Gui.AddButton("x502 yp-3 w108 h25", "Apply Fans")
        btnApplyFan.OnEvent("Click", (*) => this.ApplyFanSpeed())

        this.sldFan.OnEvent("Change", (ctrl, *) => this.edtFan.Value := ctrl.Value)
        this.edtFan.OnEvent("Change", (ctrl, *) => this.OnEditFanChange(ctrl.Value))

        this.Gui.AddText("x34 yp+32 w125", "Target Temperature:")
        this.edtTargetTemp := this.Gui.AddEdit("x162 yp-3 w50 h25 Center Number", targetTemp)
        this.Gui.AddText("x218 yp+3 w75", "°C (60-90°C)")
        btnSetTemp := this.Gui.AddButton("x300 yp-3 w145 h25", "Set Target Temp")
        btnSetTemp.OnEvent("Click", (*) => this.ApplyTargetTemp())
        btnResetTemp := this.Gui.AddButton("x455 yp w155 h25", "↺ Reset Temp (80°C)")
        btnResetTemp.OnEvent("Click", (*) => this.ResetTargetTemp())

        btnFanAuto := this.Gui.AddButton("x34 yp+34 w160 h26", "↺ Restore Auto Fans")
        btnFanAuto.SetFont("Bold")
        btnFanAuto.OnEvent("Click", (*) => this.ResetFansToAuto())

        btnFan40 := this.Gui.AddButton("x+10 yp w90 h26", "40%")
        btnFan40.OnEvent("Click", (*) => this.SetFanPreset(40))

        btnFan60 := this.Gui.AddButton("x+10 yp w90 h26", "60%")
        btnFan60.OnEvent("Click", (*) => this.SetFanPreset(60))

        btnFan80 := this.Gui.AddButton("x+10 yp w90 h26", "80%")
        btnFan80.OnEvent("Click", (*) => this.SetFanPreset(80))

        btnFan100 := this.Gui.AddButton("x+10 yp w96 h26", "100%")
        btnFan100.OnEvent("Click", (*) => this.SetFanPreset(100))

        ; Section 5: Bottom Actions
        btnMinTray := this.Gui.AddButton(Format("x34 y+20 w{} h34", actionBtnW), "🗕 Minimize to Tray (Completely)")
        btnMinTray.OnEvent("Click", (*) => this.MinimizeToTray(true))

        btnQuitApp := this.Gui.AddButton(Format("x332 yp w{} h34", actionBtnW), "✕ Close Application")
        btnQuitApp.OnEvent("Click", (*) => ExitApp())

        ; Status Bar
        this.sb := this.Gui.AddStatusBar()
        if A_IsAdmin
            this.sb.SetText("Ready (Running as Administrator).")
        else
            this.sb.SetText("Ready (Read-Only: Administrator privileges required to change settings).")

        ; Window Events
        this.Gui.OnEvent("Size", (g, minMax, w, h) => this.OnWindowSize(minMax))
        this.Gui.OnEvent("Close", (*) => this.OnWindowClose())
        OnMessage(0x0112, (wp, lp, msg, hwnd) => this.OnSysCommand(wp, hwnd))
    }

    /**
     * Shows the main controller window at its remembered monitor coordinates.
     */
    Show() {
        if (this.LastX != "" && this.LastY != "")
            this.Gui.Show(Format("x{} y{} w{}", this.LastX, this.LastY, this.GroupWidth + 36))
        else
            this.Gui.Show(Format("w{}", this.GroupWidth + 36))
        this.RefreshStats()
        SetTimer(this.TimerCallback, 1000)
    }

    /**
     * Updates status bar text.
     * @param {String} msg - Status message.
     */
    SetStatus(msg) {
        this.sb.SetText(msg)
    }

    /**
     * Toggles Windows Startup registration.
     * Prompts for confirmation before enabling.
     * @param {Integer} enable - 1 to register, 0 to unregister.
     */
    ToggleStartup(enable) {
        if enable {
            res := MsgBox("Are you sure you want NVcontrol to start automatically with Windows?`n`n"
                . "The application will launch minimized to the background on system startup.",
                "NVcontrol - Start with Windows", "YesNo Icon? 256")
            if (res != "Yes") {
                this.chkStartup.Value := 0
                return
            }
        }
        success := StartupManager.SetEnabled(enable)
        if success {
            this.chkStartup.Value := enable ? 1 : 0
            this.SetStatus(enable ? "Enabled: Will start with Windows (minimized)." : "Disabled: Removed from Windows startup.")
        } else {
            this.chkStartup.Value := StartupManager.IsEnabled() ? 1 : 0
        }
    }

    /**
     * Toggles Windows Startup from Tray menu.
     */
    ToggleStartupFromTray() {
        newVal := !StartupManager.IsEnabled()
        this.ToggleStartup(newVal)
        try {
            if newVal
                A_TrayMenu.Check("Start with Windows")
            else
                A_TrayMenu.Uncheck("Start with Windows")
        }
    }

    /**
     * Synchronizes power slider and edit box.
     * @param {Integer} watts - Target wattage.
     */
    SetPowerSliderValue(watts) {
        this.sldPower.Value := watts
        this.edtPower.Value := watts
    }

    /**
     * Validates and reflects manual power edit box input onto the slider.
     * @param {String} val - Input value from edit box.
     */
    OnEditPowerChange(val) {
        num := Integer(val || 0)
        if (num >= this.pMin && num <= this.pMax)
            this.sldPower.Value := num
    }

    /**
     * Applies the power limit configured in the UI to the GPU with safety validation.
     */
    ApplyPowerLimit() {
        try {
            val := Safety.ValidatePower(this.edtPower.Value, this.pMin, this.pMax)
        } catch as valErr {
            this.edtPower.Value := this.pCur
            this.sldPower.Value := this.pCur
            MsgBox(valErr.Message, "Invalid Power Limit", "Icon!")
            return
        }

        this.SetStatus(Format("Applying power limit: {} W...", val))
        try {
            newVal := this.Gpu.SetPowerLimit(val)
            this.pCur := Round(newVal)
            this.SetStatus(Format("Success: Power limit set to {} W.", newVal))
            this.txtPowerRange.Text := Format("Range: {} W - {} W   |   VBIOS Default: {} W   |   Current: {} W", this.pMin, this.pMax, this.pDef, this.pCur)
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Applying Power Limit", "Iconx")
        }
    }

    /**
     * Restores the GPU power limit to its factory VBIOS default.
     */
    ResetPowerLimit() {
        this.SetStatus("Resetting power limit to VBIOS default...")
        try {
            newVal := this.Gpu.ResetPowerLimit()
            this.pCur := Round(newVal)
            this.sldPower.Value := this.pCur
            this.edtPower.Value := this.pCur
            this.txtPowerRange.Text := Format("Range: {} W - {} W   |   VBIOS Default: {} W   |   Current: {} W", this.pMin, this.pMax, this.pDef, this.pCur)
            this.SetStatus(Format("Power limit restored to VBIOS default: {} W.", newVal))
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Resetting Power Limit", "Iconx")
        }
    }

    /**
     * Reflects manual core offset input onto slider.
     * @param {String} val - Core offset in MHz.
     */
    OnEditCoreChange(val) {
        num := Integer(val || 0)
        if (num >= -500 && num <= 500)
            this.sldCoreOffset.Value := num
    }

    /**
     * Applies core clock offset to the GPU with safety verification.
     */
    ApplyCoreOffset() {
        try {
            val := Safety.ValidateCoreOffset(this.edtCoreOffset.Value)
        } catch as valErr {
            this.edtCoreOffset.Value := "0"
            this.sldCoreOffset.Value := 0
            if (valErr.Message != "Operation canceled by user.")
                MsgBox(valErr.Message, "Invalid Core Offset", "Icon!")
            return
        }

        this.SetStatus(Format("Applying Core Clock Offset: {} MHz...", val))
        try {
            this.Gpu.SetCoreClockOffset(val)
            this.SetStatus(Format("Success: Core Clock Offset set to {} MHz.", val))
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Setting Core Offset", "Iconx")
        }
    }

    /**
     * Reflects manual memory offset input onto slider.
     * @param {String} val - Memory offset in MHz.
     */
    OnEditMemChange(val) {
        num := Integer(val || 0)
        if (num >= -1000 && num <= 2000)
            this.sldMemOffset.Value := num
    }

    /**
     * Applies memory clock offset to the GPU with safety verification.
     */
    ApplyMemOffset() {
        try {
            val := Safety.ValidateMemOffset(this.edtMemOffset.Value)
        } catch as valErr {
            this.edtMemOffset.Value := "0"
            this.sldMemOffset.Value := 0
            if (valErr.Message != "Operation canceled by user.")
                MsgBox(valErr.Message, "Invalid Memory Offset", "Icon!")
            return
        }

        this.SetStatus(Format("Applying Memory Clock Offset: {} MHz...", val))
        try {
            this.Gpu.SetMemClockOffset(val)
            this.SetStatus(Format("Success: Memory Clock Offset set to {} MHz.", val))
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Setting Memory Offset", "Iconx")
        }
    }

    /**
     * Resets both core and memory clock offsets to 0 MHz.
     */
    ApplyResetOffsets() {
        this.SetStatus("Resetting Core and Memory offsets to 0 MHz...")
        try {
            this.Gpu.ResetClockOffsets()
            this.sldCoreOffset.Value := 0
            this.edtCoreOffset.Value := "0"
            this.sldMemOffset.Value := 0
            this.edtMemOffset.Value := "0"
            this.SetStatus("Clock offsets successfully reset to 0 MHz.")
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Resetting Offsets", "Iconx")
        }
    }

    /**
     * Locks core clock to a specified frequency cap.
     */
    ApplyLockClock() {
        val := Integer(this.edtLockClock.Value || 0)
        if (val < 210 || val > 2500) {
            MsgBox("Please enter a clock limit between 210 and 2500 MHz.", "Invalid Clock", "Icon!")
            return
        }

        this.SetStatus(Format("Locking core clock to {} MHz...", val))
        try {
            this.Gpu.LockGpuClocks(val)
            this.SetStatus(Format("GPU core clock successfully locked to {} MHz.", val))
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Locking Clock", "Iconx")
        }
    }

    /**
     * Unlocks core clock, restoring dynamic boost.
     */
    ApplyResetClock() {
        this.SetStatus("Resetting GPU clocks to dynamic boost curve...")
        try {
            this.Gpu.ResetGpuClocks()
            this.SetStatus("GPU clocks successfully unlocked.")
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Resetting Clocks", "Iconx")
        }
    }

    /**
     * Reflects manual fan edit input onto the fan slider.
     * @param {String} val - Fan speed percentage.
     */
    OnEditFanChange(val) {
        num := Integer(val || 0)
        if (num >= this.Gpu.MinFan && num <= this.Gpu.MaxFan)
            this.sldFan.Value := num
    }

    /**
     * Applies manual fan speed percentage to both GPU fans with stall protection.
     */
    ApplyFanSpeed() {
        try {
            val := Safety.ValidateFanSpeed(this.edtFan.Value, this.Gpu.MinFan, this.Gpu.MaxFan)
        } catch as valErr {
            this.edtFan.Value := "50"
            this.sldFan.Value := 50
            MsgBox(valErr.Message, "Invalid Fan Speed", "Icon!")
            return
        }

        this.SetStatus(Format("Applying manual fan speed: {}%...", val))
        try {
            this.Gpu.SetFanSpeed(val)
            this.SetStatus(Format("Success: Fans set to manual {}%.", val))
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Setting Fan Speed", "Iconx")
        }
    }

    /**
     * Sets slider and edit box to preset and applies it.
     * @param {Integer} percent - Fan percentage.
     */
    SetFanPreset(percent) {
        this.sldFan.Value := percent
        this.edtFan.Value := percent
        this.ApplyFanSpeed()
    }

    /**
     * Restores all fans to automatic VBIOS thermal management.
     */
    ResetFansToAuto() {
        this.SetStatus("Restoring fans to automatic VBIOS thermal curve...")
        try {
            this.Gpu.ResetFansToAuto()
            this.SetStatus("Fans restored to automatic VBIOS control.")
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Restoring Auto Fans", "Iconx")
        }
    }

    /**
     * Sets GPU target slowdown temperature with validation.
     */
    ApplyTargetTemp() {
        try {
            val := Safety.ValidateTargetTemp(this.edtTargetTemp.Value)
        } catch as valErr {
            this.edtTargetTemp.Value := "80"
            MsgBox(valErr.Message, "Invalid Target Temperature", "Icon!")
            return
        }

        this.SetStatus(Format("Setting target temperature to {} °C...", val))
        try {
            this.Gpu.SetTargetTemp(val)
            this.SetStatus(Format("Target temperature successfully set to {} °C.", val))
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Setting Target Temperature", "Iconx")
        }
    }

    /**
     * Resets target temperature to factory default (80 °C).
     */
    ResetTargetTemp() {
        this.SetStatus("Resetting target temperature to default (80 °C)...")
        try {
            this.Gpu.SetTargetTemp(80)
            this.edtTargetTemp.Value := "80"
            this.SetStatus("Target temperature restored to default 80 °C.")
            this.RefreshStats()
        } catch as err {
            this.SetStatus("Error: " err.Message)
            MsgBox(err.Message, "Error Resetting Target Temp", "Iconx")
        }
    }

    /**
     * Enables or disables background telemetry polling timer.
     * @param {Integer} enable - 1 to enable, 0 to disable.
     */
    ToggleAutoRefresh(enable) {
        if enable
            SetTimer(this.TimerCallback, 1000)
        else
            SetTimer(this.TimerCallback, 0)
    }

    /**
     * Hides widget if option unchecked.
     * @param {Integer} enable - Checkbox value.
     */
    ToggleTaskbarOption(enable) {
        if !enable && this.Widget
            this.Widget.Hide()
    }

    /**
     * Restarts script with elevated privileges via UAC prompt.
     */
    RestartAsAdmin() {
        try {
            if A_IsCompiled
                Run('*RunAs "' A_ScriptFullPath '" /restart')
            else
                Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
            ExitApp()
        }
    }

    /**
     * Minimizes application either to taskbar widget or completely to tray.
     * Trims working set memory to keep RAM usage minimal (~1.5 MB).
     * @param {Boolean} completely - If true, hides both GUI and taskbar widget.
     */
    MinimizeToTray(completely := false) {
        this.SavePosition()
        this.Gui.Hide()
        if (!completely && this.chkShowWidget.Value && this.Widget) {
            this.Widget.Show()
        } else if this.Widget {
            this.Widget.Hide()
        }
        TrimWorkingSet()
    }

    /**
     * Restores and focuses the main controller window at its remembered monitor coordinates.
     */
    Restore() {
        if this.Widget
            this.Widget.Hide()
        if (this.LastX != "" && this.LastY != "")
            this.Gui.Show(Format("x{} y{}", this.LastX, this.LastY))
        else
            this.Gui.Show()
        WinActivate("ahk_id " this.Gui.Hwnd)
    }

    /**
     * Intercepts WM_SYSCOMMAND to prevent Windows from minimizing the owned
     * window into a floating desktop title bar box.
     * @param {Integer} wp - WPARAM containing system command.
     * @param {Integer} hwnd - Window handle.
     * @returns {Integer|Undefined} 0 to suppress default handling, or undefined to allow.
     */
    OnSysCommand(wp, hwnd) {
        if (this.Gui && hwnd == this.Gui.Hwnd) {
            cmd := wp & 0xFFF0
            if (cmd == 0xF020) { ; SC_MINIMIZE
                this.MinimizeToTray(false)
                return 0 ; Suppress native Windows minimize to prevent floating title bar box
            }
            if (cmd == 0xF060) { ; SC_CLOSE
                ExitApp()
            }
        }
    }

    /**
     * Window resize event handler.
     * @param {Integer} minMax - -1 indicates minimized, 0 normal.
     */
    OnWindowSize(minMax) {
        if (minMax == -1) {
            this.MinimizeToTray(false)
        } else if (minMax == 0) {
            this.SavePosition()
        }
    }

    /**
     * Window close event handler. Exits the application cleanly.
     */
    OnWindowClose() {
        ExitApp()
    }

    /**
     * Performs a single in-memory telemetry read and refreshes all UI elements.
     */
    RefreshStats() {
        if this.IsUpdating
            return
        this.IsUpdating := true

        try {
            t := this.Gpu.GetTelemetry()
            if !t
                return

            ; Power
            pwrDraw := t["PowerDraw"]
            pwrLimit := t["PowerLimit"]
            this.txtPowerDraw.Text := Format("Power Draw: {:.1f} W / {:.1f} W", pwrDraw, pwrLimit)

            ; Temp & Fans
            temp := t["Temperature"]
            fans := t["FanSpeeds"]
            fan0Str := (fans.Length >= 1) ? fans[1] "%" : "--%"
            fan1Str := (fans.Length >= 2) ? fans[2] "%" : "--%"
            this.txtTemp.Text := Format("Temp: {} °C (Fans: {} / {})", temp, fan0Str, fan1Str)

            ; Clocks
            this.txtClocks.Text := Format("Clocks: Core {} MHz | Mem {} MHz", t["CoreClock"], t["MemoryClock"])

            ; VRAM
            this.txtVram.Text := Format("VRAM: {:.1f} / {:.1f} GB", t["MemoryUsedGB"], t["MemoryTotalGB"])

            ; Utilization & Bandwidth
            gpuLoad := t["GpuLoad"]
            memBW := t["MemUtil"]
            this.txtUtil.Text := Format("GPU Load: {} %", gpuLoad)
            this.txtBandwidth.Text := Format("Mem Controller / BW: {} %", memBW)

            ; Fan & Thermal Group status
            fanModeStr := this.Gpu.ManualFanActive ? "Manual Control" : "Auto (VBIOS Thermal Curve)"
            tTemp := this.Gpu.GetTargetTemp()
            this.txtFanStatus.Text := Format("Status: {}  |  Speeds: Fan 0: {}, Fan 1: {}  |  Target: {} °C", fanModeStr, fan0Str, fan1Str, tTemp)

            ; Update Taskbar Widget
            if this.Widget
                this.Widget.Update(t)

            ; Update Tray Tooltip
            A_IconTip := Format("RTX 3090: {}°C | {}% Load | {:.0f}W / {:.0f}W", temp, gpuLoad, pwrDraw, pwrLimit)

            ; Periodic memory trim every 60 seconds
            static pollCount := 0
            pollCount++
            if (Mod(pollCount, 60) == 0)
                TrimWorkingSet()
        } finally {
            this.IsUpdating := false
        }
    }
}

/**
 * Configures and manages the Windows system notification area tray icon and menu.
 */
class TrayController {
    /**
     * Binds tray menu items to controller and widget actions.
     * @param {NvControlGui} controller - Active controller instance.
     * @param {TaskbarWidget} widget - Active widget instance.
     */
    static Setup(controller, widget) {
        A_IconTip := "NVcontrol - GPU Hardware & Power Controller"
        tray := A_TrayMenu
        tray.Delete()
        tray.Add("Open Controller", (*) => controller.Restore())
        tray.Default := "Open Controller"
        tray.Add("Start with Windows", (*) => controller.ToggleStartupFromTray())
        if StartupManager.IsEnabled()
            tray.Check("Start with Windows")
        tray.Add("Minimize Completely to Tray", (*) => controller.MinimizeToTray(true))
        tray.Add("Show / Hide Taskbar Widget", (*) => widget.Toggle())
        tray.Add()
        tray.Add("Restore Auto Fans", (*) => controller.ResetFansToAuto())
        tray.Add("Refresh Stats", (*) => controller.RefreshStats())
        tray.Add()
        tray.Add("Exit Application", (*) => ExitApp())
    }
}

/**
 * Handles command-line arguments for headless execution (e.g., from batch scripts or shortcuts).
 * @param {NvmlDevice} gpu - The GPU controller instance.
 * @returns {Boolean} True if a CLI command was processed and script should exit.
 */
HandleCommandLine(gpu) {
    if (A_Args.Length < 1)
        return false

    arg := Trim(A_Args[1])
    targetWatts := ""

    if (arg = "reset" || arg = "--reset") {
        try {
            res := gpu.ResetPowerLimit()
            MsgBox("Power limit reset to VBIOS default: " res " W", "NVcontrol", "Iconi")
        } catch as err {
            MsgBox(err.Message, "Error Resetting Power Limit", "Iconx")
        }
        return true
    } else if RegExMatch(arg, "^\d+(\.\d+)?$") {
        targetWatts := arg
    } else if (A_Args.Length >= 2 && (arg = "-pl" || arg = "--power-limit")) {
        targetWatts := Trim(A_Args[2])
    }

    if (targetWatts != "") {
        try {
            res := gpu.SetPowerLimit(targetWatts)
            MsgBox("Power limit successfully set to: " res " W", "NVcontrol", "Iconi")
        } catch as err {
            MsgBox(err.Message, "Error Setting Power Limit", "Iconx")
        }
        return true
    }

    return false
}

/**
 * Safety cleanup handler called on script exit.
 * Automatically restores fans to VBIOS auto control, flushes window positions, and shuts down NVML.
 * @param {NvmlDevice} gpu - Active GPU device instance.
 * @param {TaskbarWidget} widget - Active widget instance.
 * @param {NvControlGui} controller - Active controller instance.
 * @param {String} ExitReason - Reason for exit.
 * @param {Integer} ExitCode - Application exit code.
 */
OnScriptExit(gpu, widget, controller, ExitReason, ExitCode) {
    InstanceManager.Close()
    try {
        if (IsSet(widget) && widget && widget.IsVisible())
            widget.UpdatePosition(true)
        if (IsSet(controller) && controller)
            controller.SavePosition()
    }
    Safety.ClearCanary()
    try {
        if (IsSet(gpu) && gpu.ManualFanActive)
            gpu.ResetFansToAuto()
    }
    try NVML.Shutdown()
}

/**
 * Main application entry point.
 */
Main() {
    ; If an instance is already running, wake it to the foreground and exit cleanly
    if !InstanceManager.Init()
        ExitApp(0)

    EnsureAdmin()

    try {
        gpu := NvmlDevice(0)
    } catch as initErr {
        MsgBox("Unable to initialize NVIDIA Management Library (NVML):`n`n" initErr.Message, "NVcontrol - Error", "Iconx")
        InstanceManager.Close()
        ExitApp(1)
    }

    if HandleCommandLine(gpu) {
        InstanceManager.Close()
        ExitApp()
    }

    ; Perform Safe-Boot crash check (reverts to safe factory VBIOS defaults if previous session crashed)
    Safety.CheckSafeBoot(gpu)

    widget := TaskbarWidget()
    controller := NvControlGui(gpu, widget)
    widget.SetController(controller)

    ; Register wake listener so subsequent launches restore this running instance
    InstanceManager.RegisterListener(controller)

    OnExit((reason, code) => OnScriptExit(gpu, widget, controller, reason, code))

    TrayController.Setup(controller, widget)

    ; Check if launched with /minimized or /startup flag
    startMinimized := false
    for arg in A_Args {
        cleanArg := StrLower(Trim(arg))
        if (cleanArg = "/minimized" || cleanArg = "-minimized" || cleanArg = "/startup" || cleanArg = "-startup") {
            startMinimized := true
            break
        }
    }

    if startMinimized {
        controller.MinimizeToTray(false)
    } else {
        controller.Show()
    }

    ; Trim startup initialization memory baggage down to bare active working set
    TrimWorkingSet()
}

; Execute application
Main()

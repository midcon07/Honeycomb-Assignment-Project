<#
.SYNOPSIS
    Reports the live axis and button state of Honeycomb Alpha / Bravo hardware,
    read directly from the HID input report, so per-aircraft profiles can be
    written against real identifiers instead of guesses.

.DESCRIPTION
    Addresses README Issue #2 ("Bravo axis/button identifiers").

    Reads the HID input report directly (CreateFile + ReadFile on the device
    interface, decoded with the hid.dll HidP_* parsing functions). Axis names
    come from the device's own HID report descriptor, so they describe what the
    hardware actually reports.

    Why not the simpler APIs -- both were tried and neither works here:

      * The legacy WinMM joystick API (joyGetPosEx) enumerates the Bravo and
        returns success, but reports every axis stuck at centre (32767)
        regardless of lever position. It returns defaults, not hardware state.
      * WinRT Windows.Gaming.Input.RawGameController returns an empty device
        list from a console host, as it expects a foreground app with a message
        pump.

    Direct HID reading works regardless of focus, has no 32-button ceiling, and
    reports the true logical range of each axis.

    No dependencies: Windows PowerShell 5.1, no modules, no admin rights.

.PARAMETER Watch
    Live display. Refreshes continuously so you can move one lever at a time and
    see which axis responds. Ctrl+C to stop. This is the mode that answers
    "which lever is which".

.PARAMETER Sample
    Print one line of axis values per device and exit. Useful for scripted
    before/after comparison.

.PARAMETER Json
    Write a full report to this path as JSON, suitable for committing as a
    record of a particular machine's configuration.

.PARAMETER All
    Include every HID game controller, not just Honeycomb hardware.

.PARAMETER IntervalMs
    Refresh interval for -Watch. Default 80.

.EXAMPLE
    .\Probe-HoneycombDevices.ps1
    Inventory of detected Honeycomb devices, with a current reading.

.EXAMPLE
    .\Probe-HoneycombDevices.ps1 -Watch
    Live view. Move each Bravo lever in turn to identify its axis.

.EXAMPLE
    .\Probe-HoneycombDevices.ps1 -Json .\bravo-report.json -All
    Write a committable report covering every controller.

.NOTES
    The axis names reported here (X, Y, Z, Rx, Ry, Rz, Slider...) are HID usage
    names from the device descriptor. FSUIPC7 shows its own axis letters, which
    are assigned by DirectInput and do not map to HID usages by a rule worth
    guessing at. Use this tool to learn which physical lever moves which axis,
    then confirm the corresponding FSUIPC letter in FSUIPC7's own axis scanner.

    The GUID reported is the DirectInput *product* GUID derived from VID/PID.
    FSUIPC7's [JoyNames] section stores per-*instance* GUIDs, which DirectInput
    generates at enumeration time and does not cache in the registry; capture
    those by running FSUIPC7 once and reading its FSUIPC7.ini.
#>
[CmdletBinding()]
param(
    [switch] $Watch,
    [switch] $Sample,
    [string] $Json,
    [switch] $All,
    [int]    $IntervalMs = 80,
    # Guided capture: walks through data/bravo-buttons.json asking for each
    # control to be pressed, records the button number it sees, and writes
    # the file back with that control marked verified. Pass the file's path.
    [string] $Capture = '',
    # Re-ask for controls already verified.
    [switch] $Recapture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Honeycomb Aeronautical USB vendor ID, and the product IDs for its two units.
# Confirmed against the Windows joystick OEM registry, which names 0x1900
# "Alpha Flight Controls" and 0x1901 "Bravo Throttle Quadrant".
$HoneycombVid = 0x294B
$HoneycombPids = @{
    0x1900 = 'Honeycomb Alpha Flight Controls'
    0x1901 = 'Honeycomb Bravo Throttle Quadrant'
}

# HID Generic Desktop usages that represent an analogue axis.
# Deliberately a plain hashtable, not [ordered]: an OrderedDictionary indexed by
# an integer does a positional lookup, so $AxisUsageNames[0x30] would ask for
# element 48 rather than the usage keyed 0x30.
$AxisUsageNames = @{
    0x30 = 'X'
    0x31 = 'Y'
    0x32 = 'Z'
    0x33 = 'Rx'
    0x34 = 'Ry'
    0x35 = 'Rz'
    0x36 = 'Slider'
    0x37 = 'Dial'
    0x38 = 'Wheel'
}

if (-not ('Honeycomb.HidDevice' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Honeycomb {

    [StructLayout(LayoutKind.Sequential)]
    public struct HidpValueCaps {
        public ushort UsagePage;
        public byte   ReportID;
        [MarshalAs(UnmanagedType.U1)] public bool IsAlias;
        public ushort BitField;
        public ushort LinkCollection;
        public ushort LinkUsage;
        public ushort LinkUsagePage;
        [MarshalAs(UnmanagedType.U1)] public bool IsRange;
        [MarshalAs(UnmanagedType.U1)] public bool IsStringRange;
        [MarshalAs(UnmanagedType.U1)] public bool IsDesignatorRange;
        [MarshalAs(UnmanagedType.U1)] public bool IsAbsolute;
        [MarshalAs(UnmanagedType.U1)] public bool HasNull;
        public byte   Reserved;
        public ushort BitSize;
        public ushort ReportCount;
        public ushort Reserved2a, Reserved2b, Reserved2c, Reserved2d, Reserved2e;
        public uint   UnitsExp;
        public uint   Units;
        public int    LogicalMin, LogicalMax;
        public int    PhysicalMin, PhysicalMax;
        // Union: the NotRange.Usage field aliases Range.UsageMin, so reading
        // UsageMin is correct for both layouts when IsRange is false.
        public ushort UsageMin, UsageMax;
        public ushort StringMin, StringMax;
        public ushort DesignatorMin, DesignatorMax;
        public ushort DataIndexMin, DataIndexMax;
    }

    public class AxisInfo {
        public ushort Usage;
        public int    LogicalMin;
        public int    LogicalMax;
        public int    BitSize;
    }

    public class HidDevice : IDisposable {

        const uint  GENERIC_READ    = 0x80000000;
        const uint  FILE_SHARE_RW   = 0x00000003;
        const uint  OPEN_EXISTING   = 3;
        const uint  FILE_OVERLAPPED = 0x40000000;
        const int   ERROR_IO_PENDING = 997;
        const int   HIDP_STATUS_SUCCESS = unchecked((int)0x00110000);
        const int   HidP_Input = 0;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadFile(IntPtr h, byte[] buf, uint n, IntPtr read, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr CreateEventW(IntPtr attr, bool manualReset, bool initialState, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetOverlappedResult(IntPtr h, IntPtr overlapped, out uint transferred, bool wait);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CancelIo(IntPtr h);

        [DllImport("hid.dll", SetLastError = true)]
        static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
        [DllImport("hid.dll", SetLastError = true)]
        static extern bool HidD_FreePreparsedData(IntPtr pp);
        [DllImport("hid.dll", CharSet = CharSet.Unicode)]
        static extern bool HidD_GetProductString(IntPtr h, byte[] buf, uint len);
        [DllImport("hid.dll")]
        static extern int HidP_GetCaps(IntPtr pp, byte[] caps);
        [DllImport("hid.dll")]
        static extern int HidP_GetValueCaps(int type, [Out] HidpValueCaps[] caps, ref ushort length, IntPtr pp);
        [DllImport("hid.dll")]
        static extern int HidP_GetUsageValue(int type, ushort page, ushort link, ushort usage, out uint value, IntPtr pp, byte[] report, uint reportLen);
        [DllImport("hid.dll")]
        static extern int HidP_GetUsages(int type, ushort page, ushort link, [Out] ushort[] list, ref uint length, IntPtr pp, byte[] report, uint reportLen);
        [DllImport("hid.dll")]
        static extern uint HidP_MaxUsageListLength(int type, ushort page, IntPtr pp);

        IntPtr handle    = IntPtr.Zero;
        IntPtr preparsed = IntPtr.Zero;
        IntPtr readEvent = IntPtr.Zero;
        IntPtr overlapped = IntPtr.Zero;

        public int    InputReportLength;
        public int    NumberInputValueCaps;
        public string ProductString = "";

        public static HidDevice Open(string path) {
            var d = new HidDevice();
            d.handle = CreateFileW(path, GENERIC_READ, FILE_SHARE_RW, IntPtr.Zero, OPEN_EXISTING, FILE_OVERLAPPED, IntPtr.Zero);
            if (d.handle == new IntPtr(-1)) { return null; }

            if (!HidD_GetPreparsedData(d.handle, out d.preparsed)) { d.Dispose(); return null; }

            // HIDP_CAPS: InputReportByteLength is the USHORT at offset 4.
            var caps = new byte[68];
            if (HidP_GetCaps(d.preparsed, caps) != HIDP_STATUS_SUCCESS) { d.Dispose(); return null; }
            d.InputReportLength = BitConverter.ToUInt16(caps, 4);
            // HIDP_CAPS layout: Usage(0) UsagePage(2) InputReportByteLength(4)
            // OutputReportByteLength(6) FeatureReportByteLength(8)
            // Reserved[17](10..43) NumberLinkCollectionNodes(44)
            // NumberInputButtonCaps(46) NumberInputValueCaps(48).
            d.NumberInputValueCaps = BitConverter.ToUInt16(caps, 48);

            var name = new byte[256];
            if (HidD_GetProductString(d.handle, name, (uint)name.Length)) {
                d.ProductString = System.Text.Encoding.Unicode.GetString(name).TrimEnd('\0');
            }

            d.readEvent  = CreateEventW(IntPtr.Zero, true, false, null);
            // OVERLAPPED is 32 bytes on x64; hEvent sits at offset 24.
            d.overlapped = Marshal.AllocHGlobal(32);
            return d;
        }

        // Reads one input report, giving up after timeoutMs so a quiet device
        // never hangs the caller.
        public byte[] TryRead(int timeoutMs) {
            if (InputReportLength <= 0) { return null; }
            var buf = new byte[InputReportLength];

            for (int i = 0; i < 32; i++) { Marshal.WriteByte(overlapped, i, 0); }
            Marshal.WriteIntPtr(overlapped, 24, readEvent);

            bool ok = ReadFile(handle, buf, (uint)InputReportLength, IntPtr.Zero, overlapped);
            if (!ok) {
                if (Marshal.GetLastWin32Error() != ERROR_IO_PENDING) { return null; }
                if (WaitForSingleObject(readEvent, (uint)timeoutMs) != 0) { CancelIo(handle); return null; }
            }
            uint got;
            if (!GetOverlappedResult(handle, overlapped, out got, false)) { return null; }
            return buf;
        }

        public List<AxisInfo> GetAxes() {
            var result = new List<AxisInfo>();
            if (NumberInputValueCaps == 0) { return result; }

            ushort count = (ushort)NumberInputValueCaps;
            var caps = new HidpValueCaps[count];
            if (HidP_GetValueCaps(HidP_Input, caps, ref count, preparsed) != HIDP_STATUS_SUCCESS) { return result; }

            foreach (var c in caps) {
                if (c.UsagePage != 0x01) { continue; }   // Generic Desktop only
                int lo = c.IsRange ? c.UsageMin : c.UsageMin;
                int hi = c.IsRange ? c.UsageMax : c.UsageMin;
                for (int u = lo; u <= hi; u++) {
                    result.Add(new AxisInfo {
                        Usage      = (ushort)u,
                        LogicalMin = c.LogicalMin,
                        LogicalMax = c.LogicalMax,
                        BitSize    = c.BitSize
                    });
                }
            }
            return result;
        }

        public bool TryGetAxisValue(ushort usage, byte[] report, out uint value) {
            value = 0;
            return HidP_GetUsageValue(HidP_Input, 0x01, 0, usage, out value, preparsed, report, (uint)report.Length) == HIDP_STATUS_SUCCESS;
        }

        public ushort[] GetPressedButtons(byte[] report) {
            uint max = HidP_MaxUsageListLength(HidP_Input, 0x09, preparsed);
            if (max == 0) { return new ushort[0]; }
            var list = new ushort[max];
            uint len = max;
            if (HidP_GetUsages(HidP_Input, 0x09, 0, list, ref len, preparsed, report, (uint)report.Length) != HIDP_STATUS_SUCCESS) {
                return new ushort[0];
            }
            var outp = new ushort[len];
            Array.Copy(list, outp, (int)len);
            return outp;
        }

        public void Dispose() {
            if (overlapped != IntPtr.Zero) { Marshal.FreeHGlobal(overlapped); overlapped = IntPtr.Zero; }
            if (readEvent  != IntPtr.Zero) { CloseHandle(readEvent);  readEvent  = IntPtr.Zero; }
            if (preparsed  != IntPtr.Zero) { HidD_FreePreparsedData(preparsed); preparsed = IntPtr.Zero; }
            if (handle     != IntPtr.Zero && handle != new IntPtr(-1)) { CloseHandle(handle); handle = IntPtr.Zero; }
        }
    }
}
"@
}

function Get-DirectInputProductGuid {
    <#
        DirectInput derives a product GUID for HID devices as
        {PPPPVVVV-0000-0000-0000-504944564944}, where the trailing bytes spell
        "PIDVID" in ASCII. Stable per product, unlike the instance GUID.
    #>
    param([int] $Vid, [int] $ProductId)
    return '{{{0:X4}{1:X4}-0000-0000-0000-504944564944}}' -f $ProductId, $Vid
}

function Get-CandidateDevices {
    <#
        Enumerates HID nodes and builds the device interface path each one is
        reachable at. The interface path is the instance ID with backslashes
        replaced by '#', wrapped in \\?\ and suffixed with the HID class GUID.
    #>
    param([switch] $IncludeAll)

    $hidGuid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
    $found = @()

    foreach ($d in Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue) {
        if ($d.DeviceID -notmatch '^HID\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { continue }

        $vid = [Convert]::ToInt32($Matches[1], 16)
        $prodId = [Convert]::ToInt32($Matches[2], 16)
        $isHoneycomb = ($vid -eq $HoneycombVid)

        if (-not $isHoneycomb -and -not $IncludeAll) { continue }

        if ($isHoneycomb -and $HoneycombPids.ContainsKey($prodId)) {
            $label = $HoneycombPids[$prodId]
        } else {
            $label = $d.Name
        }

        $found += [pscustomobject]@{
            Name        = $label
            InstanceId  = $d.DeviceID
            Path        = '\\?\' + ($d.DeviceID -replace '\\', '#') + '#' + $hidGuid
            Vid         = $vid
            Pid         = $prodId
            IsHoneycomb = $isHoneycomb
            ProductGuid = Get-DirectInputProductGuid -Vid $vid -ProductId $prodId
        }
    }
    return $found
}

function ConvertTo-DeviceState {
    <#
        Decodes one raw input report into named axes and a pressed-button list,
        using the device's own report descriptor.
    #>
    param($Device, [byte[]] $Report)

    $axes = [ordered]@{}
    foreach ($a in $Device.GetAxes()) {
        if (-not $AxisUsageNames.ContainsKey([int]$a.Usage)) { continue }
        $value = [uint32]0
        if (-not $Device.TryGetAxisValue($a.Usage, $Report, [ref]$value)) { continue }

        $name = $AxisUsageNames[[int]$a.Usage]
        # A descriptor may list the same usage more than once; keep them distinct.
        $key = $name
        $n = 2
        while ($axes.Contains($key)) { $key = "$name#$n"; $n++ }

        $axes[$key] = [pscustomobject]@{
            Usage = '0x{0:X2}' -f $a.Usage
            Value = [int]$value
            Min   = $a.LogicalMin
            Max   = $a.LogicalMax
            Bits  = $a.BitSize
        }
    }

    return [pscustomobject]@{
        ProductString = $Device.ProductString
        ReportLength  = $Device.InputReportLength
        ReportHex     = ($Report | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        Axes          = $axes
        Buttons       = @($Device.GetPressedButtons($Report))
    }
}

function Read-DeviceState {
    <#
        Opens a device, reads one input report and decodes it. Returns $null
        when the device cannot be opened or sends nothing within the timeout.

        The default timeout allows for an idle device: the Bravo emits a
        heartbeat report about once a second when nothing is moving, so a
        one-shot read needs to wait longer than that to be reliable.
    #>
    param([string] $Path, [int] $TimeoutMs = 1500)

    $dev = [Honeycomb.HidDevice]::Open($Path)
    if ($null -eq $dev) { return $null }

    try {
        $report = $dev.TryRead($TimeoutMs)
        if ($null -eq $report) { return $null }
        return ConvertTo-DeviceState -Device $dev -Report $report
    } finally {
        $dev.Dispose()
    }
}

function Format-AxisBar {
    param([int] $Value, [int] $Minimum, [int] $Maximum, [int] $Width = 28)

    $span = $Maximum - $Minimum
    if ($span -le 0) { $span = 1 }

    $fraction = ($Value - $Minimum) / $span
    if ($fraction -lt 0) { $fraction = 0 }
    if ($fraction -gt 1) { $fraction = 1 }

    $filled = [int][math]::Round($fraction * $Width)
    $bar = ('#' * $filled).PadRight($Width, '.')
    return '{0} {1,5:N1}%  {2,5}' -f $bar, ($fraction * 100), $Value
}

function Write-Inventory {
    param($Devices)

    Write-Host ''
    Write-Host 'Honeycomb device probe' -ForegroundColor Cyan
    Write-Host ('-' * 74)

    $any = $false
    foreach ($d in $Devices) {
        $state = Read-DeviceState -Path $d.Path
        if ($null -eq $state) { continue }   # non-input HID collection, or busy
        $any = $true

        $colour = if ($d.IsHoneycomb) { 'Green' } else { 'Gray' }
        Write-Host ("{0}" -f $d.Name) -ForegroundColor $colour
        if ($state.ProductString) { Write-Host ("  Reported name  {0}" -f $state.ProductString) }
        Write-Host ("  VID/PID        0x{0:X4} / 0x{1:X4}" -f $d.Vid, $d.Pid)
        Write-Host ("  Product GUID   {0}" -f $d.ProductGuid)
        Write-Host ("  Input report   {0} bytes" -f $state.ReportLength)
        Write-Host ("  Axes           {0}" -f $state.Axes.Count)
        Write-Host ("  Buttons down   {0}" -f $(if ($state.Buttons.Count) { $state.Buttons -join ', ' } else { '(none)' }))

        foreach ($name in $state.Axes.Keys) {
            $a = $state.Axes[$name]
            $bar = Format-AxisBar -Value $a.Value -Minimum $a.Min -Maximum $a.Max
            Write-Host ("    {0,-8} {1}  [{2}, {3}] {4}-bit" -f $name, $bar, $a.Min, $a.Max, $a.Bits)
        }
        Write-Host ''
    }

    if (-not $any) {
        Write-Host 'No readable Honeycomb hardware found. Check it is plugged in and powered.' -ForegroundColor Yellow
        Write-Host 'Use -All to list every HID controller.' -ForegroundColor DarkGray
        Write-Host ''
    }
}

function Start-WatchLoop {
    param($Devices)

    # Open each device once and keep the handle for the life of the loop.
    # Reopening every frame would drop reports and add latency; a held handle
    # receives each report the moment the device sends it.
    $sessions = @()
    foreach ($d in $Devices) {
        $dev = [Honeycomb.HidDevice]::Open($d.Path)
        if ($null -eq $dev) { continue }

        $first = $dev.TryRead(1500)
        if ($null -eq $first) { $dev.Dispose(); continue }

        $sessions += [pscustomobject]@{
            Info   = $d
            Device = $dev
            State  = (ConvertTo-DeviceState -Device $dev -Report $first)
        }
    }

    if ($sessions.Count -eq 0) {
        Write-Host 'Nothing to watch - no readable devices.' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host 'Move ONE lever, switch or button at a time and note which line reacts.' -ForegroundColor Cyan
    Write-Host 'Names shown are HID usages; confirm the FSUIPC letter in FSUIPC7 itself.' -ForegroundColor DarkGray
    Write-Host 'Press Ctrl+C to stop.' -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 900

    try {
        while ($true) {
            foreach ($s in $sessions) {
                # Short timeout keeps the display responsive between the
                # device's roughly 1 Hz idle heartbeat. When nothing arrives we
                # simply keep showing the last known values.
                $r = $s.Device.TryRead([math]::Max($IntervalMs, 30))
                if ($null -ne $r) {
                    $s.State = ConvertTo-DeviceState -Device $s.Device -Report $r
                }
            }

            $frame = New-Object System.Text.StringBuilder
            [void]$frame.AppendLine("Honeycomb live monitor    $(Get-Date -Format 'HH:mm:ss')")
            [void]$frame.AppendLine(('=' * 74))

            foreach ($s in $sessions) {
                [void]$frame.AppendLine('')
                [void]$frame.AppendLine($s.Info.Name)

                foreach ($name in $s.State.Axes.Keys) {
                    $a = $s.State.Axes[$name]
                    $bar = Format-AxisBar -Value $a.Value -Minimum $a.Min -Maximum $a.Max
                    [void]$frame.AppendLine(("  {0,-8} {1}" -f $name, $bar))
                }
                $btn = if ($s.State.Buttons.Count) { $s.State.Buttons -join ', ' } else { '(none)' }
                [void]$frame.AppendLine("  Buttons down: $btn")
            }

            Clear-Host
            Write-Host $frame.ToString()
        }
    } finally {
        foreach ($s in $sessions) { $s.Device.Dispose() }
        Write-Host ''
        Write-Host 'Monitor stopped.' -ForegroundColor DarkGray
    }
}

# --- main -------------------------------------------------------------------

$devices = @(Get-CandidateDevices -IncludeAll:$All)

if ($devices.Count -eq 0) {
    Write-Host 'No matching HID devices found.' -ForegroundColor Yellow
    return
}

function Start-CaptureSession {
    <#
        Guided capture of the Bravo's button numbers into a JSON table.

        For each control in the table that is not yet verified (or all of
        them with -Recapture), it asks for that control to be operated, then
        watches the device until a button appears that was not down a moment
        before. That new button is the answer. It diffs against the CURRENT
        pressed set rather than looking for "any button", because the Bravo
        always reports its switch and gear positions as held buttons - nine
        of them at rest on this unit - and a fresh press has to be told apart
        from those.

        After each capture it waits for the pressed set to settle and takes
        that as the new baseline. A momentary button returns the set to what
        it was; a latching switch or the mode selector leaves a new button
        down. Both work without the table having to say which is which.

        Writes back after every control, so an interrupted session loses
        nothing already measured. Numbers are stored twice: the prober's
        1-based count, and FSUIPC's number for the same button (one less, and
        from 132 when above 31 - the rule in the FSUIPC User Guide, checked
        against a measurement on this unit: prober 33 was FSUIPC 132).

        Keys: S skips the current control, Q stops.
    #>
    param([string] $Path, [switch] $All)

    if (-not (Test-Path -LiteralPath $Path)) { throw "No button table at $Path" }
    $table = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    $dev = @($devices | Where-Object { $_.Name -match '(?i)bravo' } | Select-Object -First 1)
    if ($dev.Count -eq 0) { Write-Host 'The Bravo is not connected. Plug it in and run this again.' -ForegroundColor Red; return 2 }
    $dev = $dev[0]

    function Get-Pressed {
        $s = Read-DeviceState -Path $dev.Path -TimeoutMs 400
        if ($null -eq $s) { return $null }
        return @($s.Buttons | ForEach-Object { [int]$_ })
    }
    function Wait-Settled {
        # The pressed set unchanged for 600 ms.
        $last = Get-Pressed; $since = Get-Date
        while (((Get-Date) - $since).TotalMilliseconds -lt 600) {
            Start-Sleep -Milliseconds 100
            $now = Get-Pressed
            if ($null -eq $now) { continue }
            if (($now -join ',') -ne ($last -join ',')) { $last = $now; $since = Get-Date }
        }
        return $last
    }
    function Save {
        [System.IO.File]::WriteAllText($Path, (($table | ConvertTo-Json -Depth 10) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    function To-Fsuipc { param([int] $Prober) $f = $Prober - 1; if ($f -gt 31) { $f += 100 }; return $f }

    $names = @($table.controls.PSObject.Properties | ForEach-Object { $_.Name })
    $todo  = @($names | Where-Object { $All -or -not [bool]$table.controls.$_.verified })
    if ($todo.Count -eq 0) { Write-Host 'Every control is already verified. Use -Recapture to measure again.' -ForegroundColor Green; return 0 }

    Write-Host ''
    Write-Host ('Capturing {0} control(s) from the {1}.' -f $todo.Count, $dev.Name) -ForegroundColor Cyan
    Write-Host 'Do exactly what each line asks, then leave it. S = skip this one, Q = stop.' -ForegroundColor Cyan
    Write-Host ''

    $baseline = Wait-Settled
    if ($null -eq $baseline) { Write-Host 'Could not read the Bravo.' -ForegroundColor Red; return 2 }
    Write-Host ('At rest, these buttons are held: {0}' -f $(if ($baseline.Count) { $baseline -join ', ' } else { 'none' })) -ForegroundColor DarkGray

    $done = 0
    foreach ($name in $todo) {
        $c = $table.controls.$name
        Write-Host ''
        Write-Host ('>> {0}: {1}' -f $name, $c.label) -ForegroundColor Yellow
        # A latching control that is ALREADY in the asked-for position shows
        # nothing new against the baseline, and the next thing moved gets
        # recorded under this name. That shifted three detent numbers once.
        # Saying what is held right now lets the person see it before acting.
        if ($c.kind -eq 'latching' -and $baseline.Count) {
            Write-Host ('   held right now: {0} - if this control is already in that position, move it OUT first, wait a second, then do it' -f ($baseline -join ', ')) -ForegroundColor DarkGray
        }

        $hit = $null
        while ($null -eq $hit) {
            # KeyAvailable throws when input is redirected (no console). That
            # only means the skip/stop keys are unavailable; the capture itself
            # needs no keyboard, so carry on rather than fall over.
            $k = $null
            try { if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true) } } catch { $k = $null }
            if ($null -ne $k) {
                if ($k.Key -eq 'S') { Write-Host '   skipped' -ForegroundColor DarkGray; break }
                if ($k.Key -eq 'Q') { Write-Host ('Stopped. {0} captured this session; the file is saved.' -f $done) -ForegroundColor Yellow; return 0 }
            }
            Start-Sleep -Milliseconds 60
            $now = Get-Pressed
            if ($null -eq $now) { continue }
            $new = @($now | Where-Object { $baseline -notcontains $_ })
            if ($new.Count -eq 1 -and $c.kind -eq 'latching') {
                # A rotary passes THROUGH positions on the way to the one asked
                # for, and each is a button. Recording the first one seen gave
                # IAS and CRS the same number. So for latching controls, wait
                # for the selector or switch to come to rest, then read what is
                # new against the baseline.
                $settled = Wait-Settled
                $new = @($settled | Where-Object { $baseline -notcontains $_ })
            }
            if ($new.Count -eq 1) { $hit = [int]$new[0] }
            elseif ($new.Count -gt 1) {
                Write-Host ('   more than one new button appeared ({0}) - release everything and do just that one' -f ($new -join ', ')) -ForegroundColor Red
                $baseline = Wait-Settled
            }
        }
        if ($null -eq $hit) { continue }

        $fs = To-Fsuipc $hit
        $c.prober = $hit; $c.fsuipc = $fs; $c.verified = $true
        Save
        $done++
        Write-Host ('   captured: prober button {0} = FSUIPC button {1}   (saved)' -f $hit, $fs) -ForegroundColor Green

        # Momentary buttons return to the old baseline; latching ones leave a
        # new one down. Either way, whatever it settles to is the baseline now.
        $baseline = Wait-Settled
    }

    Write-Host ''
    Write-Host ('Finished: {0} control(s) captured and saved to {1}' -f $done, $Path) -ForegroundColor Green
    return 0
}

if ($Capture) {
    $rc = Start-CaptureSession -Path $Capture -All:$Recapture
    exit $rc
}

if ($Sample) {
    foreach ($d in $devices) {
        $s = Read-DeviceState -Path $d.Path
        if ($null -eq $s) { continue }
        $pairs = foreach ($n in $s.Axes.Keys) { '{0}={1}' -f $n, $s.Axes[$n].Value }
        '{0}: {1}  buttons=[{2}]' -f $d.Name, ($pairs -join ' '), ($s.Buttons -join ',')
    }
    return
}

if ($Watch) {
    Start-WatchLoop -Devices $devices
    return
}

Write-Inventory -Devices $devices

if ($Json) {
    $report = [ordered]@{
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
        MachineName  = $env:COMPUTERNAME
        OsVersion    = [System.Environment]::OSVersion.VersionString
        Devices      = @()
        Caveats      = @(
            'Axis names are HID usages from the device descriptor, not FSUIPC axis letters. Confirm FSUIPC letters in FSUIPC7 itself.',
            'ProductGuid is the DirectInput product GUID derived from VID/PID, not the per-instance GUID FSUIPC7 stores in [JoyNames].'
        )
    }
    foreach ($d in $devices) {
        $s = Read-DeviceState -Path $d.Path
        if ($null -eq $s) { continue }
        $report.Devices += [ordered]@{
            Name          = $d.Name
            ProductString = $s.ProductString
            InstanceId    = $d.InstanceId
            Vid           = '0x{0:X4}' -f $d.Vid
            Pid           = '0x{0:X4}' -f $d.Pid
            ProductGuid   = $d.ProductGuid
            ReportLength  = $s.ReportLength
            ReportHex     = $s.ReportHex
            Axes          = $s.Axes
            ButtonsDown   = $s.Buttons
        }
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $Json -Encoding UTF8
    Write-Host "Report written to $Json" -ForegroundColor Green
}

if (-not $Watch) {
    Write-Host 'Re-run with -Watch to identify individual levers and buttons.' -ForegroundColor DarkGray
    Write-Host ''
}

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
    # Print every game controller as Windows decodes it: buttons down (1-based,
    # as the Game Controllers panel numbers them), hat direction, axes.
    [switch] $WindowsView,
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







function Get-GamingControllers {
    <#
        Every game controller as Windows itself decodes it (Windows.Gaming.Input,
        in-box since Windows 10): buttons by index, hat switches as directions,
        axes normalised 0..1. This is the view the Game Controllers panel shows.

        Why this and not the raw USB report: measured 2026-09-07 on the Alpha,
        the raw report read by hand never showed a button change under a hand
        that the panel saw perfectly, and the yoke's hat is a HAT SWITCH, not
        eight buttons - it does not exist in a button list at all. Windows'
        0-based button index is FSUIPC's button number (the panel shows it
        plus one). Works with FSUIPC running; needs no simulator.
    #>
    try { [Windows.Gaming.Input.RawGameController, Windows.Gaming.Input, ContentType=WindowsRuntime] | Out-Null } catch { return @() }
    $list = @([Windows.Gaming.Input.RawGameController]::RawGameControllers)
    if ($list.Count -eq 0) { Start-Sleep -Milliseconds 400; $list = @([Windows.Gaming.Input.RawGameController]::RawGameControllers) }
    # Warm-up: the first reading after enumeration can be empty (seen
    # 2026-09-07: "buttons down: none" two seconds before a real read showed
    # ten held). Read each once, wait, and let the callers read live.
    foreach ($c in $list) { try { $null = Read-GamingController -Controller $c } catch { } }
    Start-Sleep -Milliseconds 250
    return $list
}

function Read-GamingController {
    # One reading. Buttons come back 1-BASED (index + 1) so they line up with
    # the tables' "prober" numbers and the single To-Fsuipc rule.
    param($Controller)
    $b = New-Object bool[] $Controller.ButtonCount
    $h = New-Object Windows.Gaming.Input.GameControllerSwitchPosition[] $Controller.SwitchCount
    $a = New-Object double[] $Controller.AxisCount
    $null = $Controller.GetCurrentReading($b, $h, $a)
    $down = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i]) { [void]$down.Add($i + 1) } }
    [pscustomobject]@{
        Buttons = @($down)
        Hats    = @($h | ForEach-Object { $_.ToString() })
        Axes    = @($a)
    }
}

# FSUIPC's numbering for a hat (POV): buttons 32 to 39, forward (north) first,
# then clockwise every 45 degrees. Confirmed 2026-09-07 against the FSUIPC7
# User Guide (May 2026, "Buttons & Switch Assignments") and the Advanced Users
# guide; not yet seen in a FSUIPC7.log line, which is why a hat entry is saved
# as "assumed" rather than "verified".
$HAT_FSUIPC = [ordered]@{ Up = 32; UpRight = 33; Right = 34; DownRight = 35; Down = 36; DownLeft = 37; Left = 38; UpLeft = 39 }
$HAT_SOURCE = 'FSUIPC7 User Guide (May 2026), Buttons & Switch Assignments: a POV hat is buttons 32 (forward) to 39, clockwise in 45-degree steps. Not yet seen in FSUIPC7.log.'

function Start-CaptureSession {
    <#
        Guided capture of a unit's button numbers into its JSON table.

        For each control in the table that is not yet measured (or all of them
        with -Recapture) it asks for that control to be operated and records
        the button Windows reports for it. Four kinds:

          momentary  press it; the first NEW button against the resting set is
                     the answer, and the capture waits for that button to be
                     let go before moving on.
          latching   two steps with Enter after each: first put the control in
                     a DIFFERENT position (so the asked-for one is never where
                     it already is), which becomes the baseline; then move it
                     to the asked-for position and, once it has settled (a
                     rotary passes through positions), exactly one new button
                     must have appeared. Anything else is said, and the step
                     repeats.
          held       hold it, press Enter, one reading: exactly one new button.
                     Used for anything that springs back on its own, such as
                     the ignition key's START, which would otherwise be read
                     on the way through the positions before it.
          hat        hold it, press Enter, one reading of the hat DIRECTION,
                     which must be the direction the line asked for. The FSUIPC
                     number comes from the manual, not from a measurement, and
                     the entry says so ("assumed").

        The table is written after every control, so an interrupted session
        loses nothing. Numbers are stored twice: the 1-based count the Game
        Controllers panel shows ("prober"), and FSUIPC's number for the same
        button: one less, and from 132 when above 31 (FSUIPC7 User Guide;
        checked on a Bravo: panel 33 was FSUIPC 132).

        Keys: S skips the current control, Q stops - on every prompt and
        during every wait. Both need a real console.
    #>
    param([string] $Path, [switch] $All)

    if (-not (Test-Path -LiteralPath $Path)) { throw "No button table at $Path" }
    # Absolute from here on. Save writes through .NET, which resolves a relative
    # path against the process directory, not PowerShell's current location -
    # "-Capture data/alpha-buttons.json" from a shell opened elsewhere would
    # load the table and then fail, or write it somewhere else, on the first
    # save (found in review, 2026-09-07).
    $Path  = (Resolve-Path -LiteralPath $Path).ProviderPath
    $table = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    # Which unit the table describes. Its root "device" is an object
    # {name, vid, pid} (both tables now); a bare word "bravo" / "alpha" is
    # accepted as well. Absent means the Bravo.
    $want = $null; $wantPid = $null
    if ($table.PSObject.Properties['device'] -and $null -ne $table.device) {
        $d = $table.device
        if ($d -is [string]) { $want = $d.Trim().ToLower() }
        elseif ($d.PSObject.Properties['pid'] -and $d.pid) { $wantPid = [Convert]::ToInt32(([string]$d.pid).Trim(), 16) }
    }
    if ($null -eq $wantPid) {
        if (-not $want) { $want = 'bravo' }
        if ($want -notin @('bravo', 'alpha')) { Write-Host ('The table says device "{0}"; only bravo or alpha are known.' -f $want) -ForegroundColor Red; return 2 }
        $wantPid = if ($want -eq 'alpha') { 0x1900 } else { 0x1901 }
    }
    if (-not $want) { $want = if ($wantPid -eq 0x1900) { 'alpha' } elseif ($wantPid -eq 0x1901) { 'bravo' } else { ('product 0x{0:X4}' -f $wantPid) } }

    $ctl = @(Get-GamingControllers | Where-Object { $_.HardwareVendorId -eq 0x294B -and $_.HardwareProductId -eq $wantPid } | Select-Object -First 1)
    if ($ctl.Count -eq 0) {
        Write-Host ('Windows does not list the {0} as a game controller. Plug it in, check it shows in joy.cpl, and run this again.' -f $want) -ForegroundColor Red
        return 2
    }
    $ctl = $ctl[0]
    $unitName = '{0} - {1} buttons, {2} hat(s), {3} axes, as Windows sees it' -f $want, $ctl.ButtonCount, $ctl.SwitchCount, $ctl.AxisCount

    # ---- readers. Every one returns an ARRAY (possibly empty) or $null for
    # "could not read"; the leading comma keeps an empty array from being
    # unrolled to nothing on the way out of the function.
    function Get-Pressed {
        try { $r = Read-GamingController -Controller $ctl; return ,@($r.Buttons | ForEach-Object { [int]$_ }) } catch { return $null }
    }
    function Get-Hat {
        try {
            $r = Read-GamingController -Controller $ctl
            if ($r.Hats.Count) { return [string]$r.Hats[0] } else { return $null }
        } catch { return $null }
    }
    function Wait-Settled {
        # The pressed set unchanged for 600 ms. $null only if nothing readable.
        $last = Get-Pressed; $since = Get-Date
        while (((Get-Date) - $since).TotalMilliseconds -lt 600) {
            Start-Sleep -Milliseconds 100
            $now = Get-Pressed
            if ($null -eq $now) { continue }
            if (($now -join ',') -ne ($last -join ',')) { $last = $now; $since = Get-Date }
        }
        if ($null -eq $last) { return $null }
        return ,@($last)
    }
    function Read-Key {
        # Blocking key read. $null when there is no console to read from.
        try { return [Console]::ReadKey($true) } catch { return $null }
    }
    function Read-KeyIfAny {
        try { if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) } } catch { }
        return $null
    }
    function Drain-Keys {
        # Empty the keyboard buffer. An Enter tapped twice, or held, stays
        # queued through the waits (which read no keys) and would answer the
        # next prompt by itself (review, 2026-09-07).
        while ($null -ne (Read-KeyIfAny)) { }
    }
    function Wait-ButtonUp {
        # Until one specific button is no longer held. Says so every two
        # seconds while it is; Q returns $false (stop). The rest of the set is
        # not examined: a latched switch moved by mistake is the next
        # control's business, not this one's (review, 2026-09-07).
        param([int] $Button)
        $said = Get-Date
        while ($true) {
            $k = Read-KeyIfAny
            if ($null -ne $k -and $k.Key -eq 'Q') { return $false }
            $now = Get-Pressed
            if ($null -ne $now -and ($now -notcontains $Button)) { return $true }
            if (((Get-Date) - $said).TotalSeconds -ge 2) { Write-Host ('   still held: button {0} - let go of it' -f $Button) -ForegroundColor DarkGray; $said = Get-Date }
            Start-Sleep -Milliseconds 100
        }
    }
    function Wait-BackToRest {
        # Until nothing beyond the given set is held. Names what is still held
        # every two seconds so a switch flipped by mistake can be put back;
        # Q returns $false (stop). The set itself is never replaced by what is
        # held meanwhile.
        param([int[]] $Base)
        $said = Get-Date
        while ($true) {
            $k = Read-KeyIfAny
            if ($null -ne $k -and $k.Key -eq 'Q') { return $false }
            $now = Get-Pressed
            if ($null -ne $now) {
                $extra = @($now | Where-Object { $Base -notcontains $_ })
                if ($extra.Count -eq 0) { return $true }
                if (((Get-Date) - $said).TotalSeconds -ge 2) {
                    Write-Host ('   still held beyond the resting set: {0} - let go, and if it is a switch, put it back' -f ($extra -join ', ')) -ForegroundColor DarkGray
                    $said = Get-Date
                }
            }
            Start-Sleep -Milliseconds 100
        }
    }
    function Save {
        [System.IO.File]::WriteAllText($Path, (($table | ConvertTo-Json -Depth 10) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    function To-Fsuipc { param([int] $Prober) $f = $Prober - 1; if ($f -gt 31) { $f += 100 }; return $f }

    $names = @($table.controls.PSObject.Properties | ForEach-Object { $_.Name })
    $todo  = @($names | Where-Object {
        $e = $table.controls.$_
        $All -or (-not [bool]$e.verified -and -not ($e.PSObject.Properties['hat'] -and $e.hat))
    })
    if ($todo.Count -eq 0) { Write-Host 'Every control is already measured. Use -Recapture to measure again.' -ForegroundColor Green; return 0 }

    Write-Host ''
    Write-Host ('Capturing {0} control(s) from the {1}.' -f $todo.Count, $unitName) -ForegroundColor Cyan
    Write-Host 'Before the first one: put every switch and the key where they normally rest, and hold nothing.' -ForegroundColor Cyan
    Write-Host 'Do exactly what each line asks. S = skip this one, Q = stop.' -ForegroundColor Cyan
    Write-Host ''
    # The resting set is read only after the person says everything is at
    # rest. Read it straight away and the tidying itself - a switch flipped
    # down, the key turned back - lands in the first control (review,
    # 2026-09-07). No console (input redirected) means no gate.
    Write-Host 'When everything is at rest and you are holding nothing, press ENTER   (Q = stop)' -ForegroundColor Cyan
    Drain-Keys
    while ($true) {
        $k = Read-Key
        if ($null -eq $k) { break }
        if ($k.Key -eq 'Q') { Write-Host 'Stopped before the first control; nothing was changed.' -ForegroundColor Yellow; return 0 }
        if ($k.Key -eq 'Enter') { break }
    }

    # Wait for a real reading. Right after enumeration Windows can report
    # nothing held for a moment, and every Honeycomb unit holds buttons at
    # rest (switch and selector positions), so "nothing" means "not yet".
    $t0 = Get-Date; $first = $null
    while (((Get-Date) - $t0).TotalSeconds -lt 5) {
        $first = Get-Pressed
        if ($null -ne $first -and $first.Count -gt 0) { break }
        Start-Sleep -Milliseconds 150
    }
    if ($null -eq $first -or $first.Count -eq 0) {
        Write-Host 'Windows reports nothing held at rest. A Honeycomb unit always holds something (switch positions), so it may not be reading yet - continuing anyway; if the first control does not register, stop with Q and run again.' -ForegroundColor Yellow
    }
    $baseline = Wait-Settled
    if ($null -eq $baseline) { Write-Host ('Could not read the {0}.' -f $want) -ForegroundColor Red; return 2 }
    Write-Host ('At rest, these buttons are held: {0}' -f $(if ($baseline.Count) { $baseline -join ', ' } else { 'none' })) -ForegroundColor DarkGray
    Drain-Keys

    $done = 0
    $stopMsg = { Write-Host ('Stopped. {0} captured this session; the file is saved.' -f $done) -ForegroundColor Yellow }

    foreach ($name in $todo) {
        $c = $table.controls.$name
        Write-Host ''
        Write-Host ('>> {0}: {1}' -f $name, $c.label) -ForegroundColor Yellow

        $hit = $null
        $skipped = $false
        $kind = if ($c.PSObject.Properties['kind'] -and $c.kind) { [string]$c.kind } else { 'momentary' }

        if ($kind -eq 'hat') {
            # ---- hat: direction, read once on Enter, and it must be the
            # direction this line asked for (review, 2026-09-07: any direction
            # was accepted, so a 4-way hat or a slipped thumb would have filed
            # one direction under another's name).
            $expected = (($name -replace '^HAT_', '') -split '_' | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1).ToLower() }) -join ''
            $strict = $HAT_FSUIPC.Contains($expected)
            if ($ctl.SwitchCount -lt 1) { Write-Host '   Windows reports no hat switch on this unit - skipped' -ForegroundColor Red; $skipped = $true }
            else { Write-Host '   HOLD the hat in that direction, then press ENTER   (S = skip, Q = stop)' -ForegroundColor Cyan }
            Drain-Keys
            $pos = $null
            while (-not $skipped -and $null -eq $pos) {
                $k = Read-Key
                if ($null -eq $k) { Write-Host '   no keyboard on this console - a hat needs one; skipped' -ForegroundColor Red; $skipped = $true; break }
                if ($k.Key -eq 'S') { Write-Host '   skipped' -ForegroundColor DarkGray; $skipped = $true; break }
                if ($k.Key -eq 'Q') { & $stopMsg; return 0 }
                if ($k.Key -ne 'Enter') { continue }
                $h = Get-Hat
                if ($null -eq $h) { Write-Host '   could not read the hat - try again' -ForegroundColor Red; continue }
                if ($h -eq 'Center') { Write-Host '   the hat is centred - hold it in the direction, then press ENTER' -ForegroundColor Red; continue }
                if (-not $HAT_FSUIPC.Contains($h)) { Write-Host ('   unexpected hat direction "{0}" - try again, or S to skip' -f $h) -ForegroundColor Red; continue }
                if ($strict -and $h -ne $expected) {
                    Write-Host ('   seen: hat {0}, but this line asks for {1} - hold it exactly in that direction and press ENTER, or S if this hat has no such direction' -f $h, $expected) -ForegroundColor Red
                    continue
                }
                $pos = $h
            }
            if (-not $skipped) {
                $c.prober   = $null
                $c.fsuipc   = [int]$HAT_FSUIPC[$pos]
                $c.verified = $false
                $c | Add-Member -NotePropertyName hat       -NotePropertyValue $pos -Force
                $c | Add-Member -NotePropertyName assumed   -NotePropertyValue $true -Force
                $c | Add-Member -NotePropertyName numbering -NotePropertyValue $HAT_SOURCE -Force
                Save
                $done++
                Write-Host ('   seen: hat {0} - saved. FSUIPC number {1} comes from the FSUIPC7 manual, not from a measurement here; the first flight with it confirms it. Let go now.' -f $pos, $c.fsuipc) -ForegroundColor Green
                Start-Sleep -Milliseconds 800
            }
        }
        elseif ($kind -eq 'held') {
            # ---- held: one reading on Enter ----------------------------------
            Write-Host '   HOLD it there, then press ENTER while still holding it   (S = skip, Q = stop)' -ForegroundColor Cyan
            Drain-Keys
            while ($null -eq $hit) {
                $k = Read-Key
                if ($null -eq $k) { Write-Host '   no keyboard on this console - a held control needs one; skipped' -ForegroundColor Red; $skipped = $true; break }
                if ($k.Key -eq 'S') { Write-Host '   skipped' -ForegroundColor DarkGray; $skipped = $true; break }
                if ($k.Key -eq 'Q') { & $stopMsg; return 0 }
                if ($k.Key -ne 'Enter') { continue }
                $now = Get-Pressed
                if ($null -eq $now) { Write-Host '   could not read the unit - try again' -ForegroundColor Red; continue }
                $new = @($now | Where-Object { $baseline -notcontains $_ })
                if ($new.Count -eq 1) { $hit = [int]$new[0] }
                elseif ($new.Count -eq 0) { Write-Host '   nothing is held - hold it in position, then press ENTER while still holding it' -ForegroundColor Red }
                else { Write-Host ('   more than one button is held ({0}) - let go of everything, hold just that one, then press ENTER' -f ($new -join ', ')) -ForegroundColor Red }
            }
        }
        elseif ($kind -eq 'latching') {
            # ---- latching: two steps, fresh baseline in between --------------
            # Step 1 puts the control in a different position, so the asked-for
            # position is never where it already is - the failure that once
            # shifted three detent numbers, and that a printed "move it out
            # first" hint would have turned into recording the wrong position
            # (review, 2026-09-07). Step 2 reads once the set has settled, so a
            # rotary passing through positions is read at rest.
            while ($null -eq $hit) {
                Write-Host '   Step 1: put it in a DIFFERENT position (any other one), then press ENTER   (S = skip, Q = stop)' -ForegroundColor Cyan
                Drain-Keys
                $k = Read-Key
                if ($null -eq $k) { Write-Host '   no keyboard on this console - a switch needs one; skipped' -ForegroundColor Red; $skipped = $true; break }
                if ($k.Key -eq 'S') { Write-Host '   skipped' -ForegroundColor DarkGray; $skipped = $true; break }
                if ($k.Key -eq 'Q') { & $stopMsg; return 0 }
                if ($k.Key -ne 'Enter') { continue }
                $base = Wait-Settled
                if ($null -eq $base) { Write-Host '   could not read the unit - try again' -ForegroundColor Red; continue }

                Write-Host ('   Step 2: now move it to: {0}   then press ENTER' -f $c.label) -ForegroundColor Cyan
                Drain-Keys
                $k = $null
                while ($true) {
                    $k = Read-Key
                    if ($null -eq $k -or $k.Key -in @('Enter', 'S', 'Q')) { break }
                    Write-Host '   press ENTER once it is in that position   (S = skip, Q = stop)' -ForegroundColor Cyan
                }
                if ($null -eq $k) { $skipped = $true; break }
                if ($k.Key -eq 'S') { Write-Host '   skipped' -ForegroundColor DarkGray; $skipped = $true; break }
                if ($k.Key -eq 'Q') { & $stopMsg; return 0 }
                if ($k.Key -ne 'Enter') { continue }
                $settled = Wait-Settled
                if ($null -eq $settled) { Write-Host '   could not read the unit - starting this one again' -ForegroundColor Red; continue }
                $new = @($settled | Where-Object { $base -notcontains $_ })
                if ($new.Count -eq 1) { $hit = [int]$new[0]; $baseline = $settled }
                elseif ($new.Count -eq 0) { Write-Host '   nothing changed - it is still where it was. Starting this one again.' -ForegroundColor Red }
                else { Write-Host ('   more than one new button ({0}) - only that one control should move between the two steps. Starting this one again.' -f ($new -join ', ')) -ForegroundColor Red }
            }
        }
        else {
            # ---- momentary: the first new button against the resting set ----
            Write-Host '   PRESS it once and let go   (S = skip, Q = stop)' -ForegroundColor Cyan
            while ($null -eq $hit) {
                $k = Read-KeyIfAny
                if ($null -ne $k) {
                    if ($k.Key -eq 'S') { Write-Host '   skipped' -ForegroundColor DarkGray; $skipped = $true; break }
                    if ($k.Key -eq 'Q') { & $stopMsg; return 0 }
                }
                Start-Sleep -Milliseconds 60
                $now = Get-Pressed
                if ($null -eq $now) { continue }
                $new = @($now | Where-Object { $baseline -notcontains $_ })
                if ($new.Count -eq 0) { continue }
                if ($new.Count -gt 1) {
                    Write-Host ('   more than one new button appeared ({0}) - let go of everything, then press just that one' -f ($new -join ', ')) -ForegroundColor Red
                    if (-not (Wait-BackToRest -Base $baseline)) { & $stopMsg; return 0 }
                    continue
                }
                # One new button. Not saved yet: it is watched until it is let
                # go, and nothing else may appear meanwhile - two fingers
                # landing a few milliseconds apart would otherwise file the
                # first one under this name (review, 2026-09-07). A button
                # that never lets go is a switch position, not a press.
                $cand = [int]$new[0]; $t0 = Get-Date; $outcome = $null
                while ($null -eq $outcome) {
                    $k = Read-KeyIfAny
                    if ($null -ne $k -and $k.Key -eq 'Q') { & $stopMsg; return 0 }
                    Start-Sleep -Milliseconds 40
                    $now = Get-Pressed
                    if ($null -eq $now) { continue }
                    $extra = @($now | Where-Object { $baseline -notcontains $_ })
                    if ($extra.Count -eq 0) { $outcome = 'clean'; break }
                    if (@($extra | Where-Object { $_ -ne $cand }).Count -gt 0) { $outcome = 'more'; break }
                    if (((Get-Date) - $t0).TotalSeconds -ge 8) { $outcome = 'stuck'; break }
                }
                if ($outcome -eq 'clean') { $hit = $cand }
                elseif ($outcome -eq 'more') {
                    Write-Host ('   more than one button was pressed ({0}) - let go of everything, then press just that one' -f ($extra -join ', ')) -ForegroundColor Red
                    if (-not (Wait-BackToRest -Base $baseline)) { & $stopMsg; return 0 }
                }
                else {
                    Write-Host ('   button {0} is still held after 8 seconds. If that was a switch, it is a position, not a press: put it back where it was. Then press this control once and let go.' -f $cand) -ForegroundColor Red
                    if (-not (Wait-BackToRest -Base $baseline)) { & $stopMsg; return 0 }
                }
            }
        }

        # ---- record ----------------------------------------------------------
        if ($null -ne $hit) {
            $fs = To-Fsuipc $hit
            $c.prober = $hit; $c.fsuipc = $fs; $c.verified = $true
            Save
            $done++
            Write-Host ('   captured: panel button {0} = FSUIPC button {1}   (saved)' -f $hit, $fs) -ForegroundColor Green
            if ($kind -eq 'held') {
                # A held control must be let go before the next control, or it
                # would sit in the next baseline. Only THAT button is waited
                # for: a sprung key lands on another position, and that is fine.
                # (A momentary capture has already seen its button released.)
                Write-Host '   let go now' -ForegroundColor DarkGray
                if (-not (Wait-ButtonUp -Button $hit)) { & $stopMsg; return 0 }
            }
        }

        # New resting set for the next control - after a capture, and after a
        # skip too, since a skipped step 1 may have moved a switch. Kept as it
        # was if nothing could be read.
        $nb = Wait-Settled
        if ($null -ne $nb) { $baseline = $nb }
    }

    Write-Host ''
    Write-Host ('Finished: {0} control(s) captured and saved to {1}' -f $done, $Path) -ForegroundColor Green
    return 0
}

if ($WindowsView) {
    $ctrls = @(Get-GamingControllers)
    if ($ctrls.Count -eq 0) { Write-Host 'Windows lists no game controllers.' -ForegroundColor Yellow; exit 2 }
    foreach ($c in $ctrls) {
        $r = Read-GamingController -Controller $c
        Write-Host ('{0}  vid=0x{1:X4} pid=0x{2:X4}  buttons={3} hats={4} axes={5}' -f $c.DisplayName, $c.HardwareVendorId, $c.HardwareProductId, $c.ButtonCount, $c.SwitchCount, $c.AxisCount)
        Write-Host ('   buttons down (panel numbering, 1-based): {0}' -f $(if ($r.Buttons.Count) { $r.Buttons -join ', ' } else { 'none' }))
        if ($r.Hats.Count) { Write-Host ('   hat: {0}' -f ($r.Hats -join ', ')) }
        Write-Host ('   axes: {0}' -f (($r.Axes | ForEach-Object { [math]::Round($_, 3) }) -join ', '))
    }
    exit 0
}

if ($Capture) {
    $rc = Start-CaptureSession -Path $Capture -All:$Recapture
    exit $rc
}

$devices = @(Get-CandidateDevices -IncludeAll:$All)

if ($devices.Count -eq 0) {
    Write-Host 'No matching HID devices found.' -ForegroundColor Yellow
    return
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

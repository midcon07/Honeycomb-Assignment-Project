<#
    Preflight check: is there a usable internet connection, and are the
    services this program actually depends on reachable.

    NOTHING HERE IS BLOCKING. Flying does not require the internet. Losing it
    costs the flight plan and the chart underlays, and nothing else. Refusing to
    start the simulator because a website is down would be absurd, and would
    train the user to distrust the gate.

    Two things this deliberately does not do:

      * It does not test DNS alone. A captive portal - hotel wifi, a router
        that has dropped its connection - resolves names perfectly and answers
        every request with a login page. The generic probe therefore checks the
        RESPONSE CONTENT, which is how Windows itself detects this.
      * It does not report three failures for one cause. If the internet is
        down, the service probes are skipped rather than each reporting its own
        problem. One problem, one message.

    Kept fast, because it runs on every launch: the generic probe is tried
    first with a short timeout, and everything else is skipped if it fails.
    Worst case is a few seconds, not a stack of timeouts.

    Read-only.
#>

@{
    Name        = 'Internet'
    Description = 'Internet reachability and the services this program uses'

    Run = {

        # PowerShell wraps an exception thrown by a .NET method call inside a
        # MethodInvocationException, so the WebException that actually carries
        # the HTTP response sits one or more levels down. Reading
        # $_.Exception.Response directly always yields nothing, which turned a
        # perfectly healthy 400 into "SimBrief cannot be reached".
        function Get-HttpStatus {
            param($Err)
            $e = $Err.Exception
            for ($i = 0; $i -lt 5 -and $e; $i++) {
                if ($e.PSObject.Properties['Response'] -and $e.Response) {
                    try { return [int]$e.Response.StatusCode } catch { }
                }
                $e = $e.InnerException
            }
            return 0
        }

        function Test-Endpoint {
            param([string] $Uri, [int] $TimeoutMs = 3500, [string] $MustContain)
            try {
                $req = [System.Net.HttpWebRequest]::Create($Uri)
                $req.Timeout          = $TimeoutMs
                $req.ReadWriteTimeout = $TimeoutMs
                $req.AllowAutoRedirect = $false      # a redirect is the captive-portal tell
                $req.UserAgent = 'HoneycombPreflight/1.0'
                $resp = $req.GetResponse()
                $code = [int]$resp.StatusCode
                $body = ''
                if ($MustContain) {
                    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                    $body = $sr.ReadToEnd(); $sr.Close()
                }
                $resp.Close()
                if ($MustContain -and ($body -notlike "*$MustContain*")) {
                    return @{ Ok = $false; Why = 'captive'; Code = $code }
                }
                return @{ Ok = ($code -ge 200 -and $code -lt 400); Why = ''; Code = $code }
            } catch {
                $code = Get-HttpStatus $_
                # A 4xx means we reached the service; it simply did not like the
                # request. That is still proof the connection works - the bare
                # SimBrief endpoint answers 400 because no user was named.
                if ($code -ge 400 -and $code -lt 500) { return @{ Ok = $true; Why = ''; Code = $code } }
                return @{ Ok = $false; Why = 'unreachable'; Code = $code }
            }
        }

        # 1. Is there a network at all? Instant, no timeout risk.
        $adapter = $false
        try { $adapter = [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable() } catch { }
        if (-not $adapter) {
            Add-Result 'Internet connection' 'WARN' `
                'This computer is not connected to any network.' `
                'Flying still works. The flight plan and the chart backgrounds will be unavailable until the connection is back.'
            return
        }

        # 2. Real connectivity, content-checked so a captive portal cannot pass.
        #    This is the endpoint Windows itself uses for the same purpose.
        $net = Test-Endpoint -Uri 'http://www.msftconnecttest.com/connecttest.txt' -MustContain 'Microsoft Connect Test'
        if (-not $net.Ok) {
            if ($net.Why -eq 'captive') {
                Add-Result 'Internet connection' 'WARN' `
                    'Connected to a network, but something is intercepting the connection - usually a wifi login page.' `
                    'Open a web browser and complete the network sign-in, then start this again. Flying works either way.'
            } else {
                Add-Result 'Internet connection' 'WARN' `
                    'Connected to a network, but the internet cannot be reached.' `
                    'Flying still works. The flight plan and the chart backgrounds will be unavailable until the connection is back.'
            }
            # One problem, one message: do not also report the service that
            # obviously cannot be reached either.
            Add-Result 'SimBrief' 'SKIP' 'Not checked - there is no internet connection.'
            return
        }
        Add-Result 'Internet connection' 'PASS' 'Reachable'

        # 3. The services this program actually uses. Each failure is scoped to
        #    what it costs, so the user knows what still works.
        $sb = Test-Endpoint -Uri 'https://www.simbrief.com/api/xml.fetcher.php'
        if ($sb.Ok) {
            Add-Result 'SimBrief' 'PASS' 'Reachable'
        } else {
            Add-Result 'SimBrief' 'WARN' `
                'SimBrief cannot be reached at the moment.' `
                'Everything else works. You will need to pick the aircraft yourself instead of it being read from your flight plan.'
        }

        # Nothing else is probed. Chart underlays were considered and dropped -
        # see notes/chart_underlays.md - so there is no FAA tile service to
        # check. A probe for something the program does not use can only ever
        # produce a warning about a thing that does not matter, which is the
        # fastest way to teach someone to ignore the whole report.
        #
        # Add a probe here when a new dependency is added, not before.
    }
}

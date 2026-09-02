# Preflight

The gate that runs **every time the program starts**, not only during setup.

Setup discovers and records. The launcher re-verifies against that record on
every launch. A check that only runs during setup is a check that stops being
true, and the machine then drifts quietly until something breaks on a day when
nobody is available to fix it.

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Invoke-Preflight.ps1
```

Read-only. Verified byte-identical across a run. The only thing it ever writes
is the report named by `-Json`.

## Verdicts

| Exit | Verdict | Meaning |
|---|---|---|
| 0 | `GO` | Nothing blocking. Safe to start the simulator. |
| 1 | `NO-GO` | A blocking check failed. **Do not start the simulator.** |
| 2 | `CANNOT RUN` | The gate could not verify anything. Never treat this as a pass. |
| 3 | `SETUP NEEDED` | Nothing is broken, but this machine has not been set up yet. |

`CANNOT RUN` exists because a gate that verified nothing must never report
success. Zero results is not zero problems.

## The phases, and why the order is what it is

Fail first: everything cheap and foundational is checked before anything
expensive, and **nothing writes until every check has passed**.

| File | Phase | Blocking |
|---|---|---|
| `00-Config` | Simulator not already running; configuration present, readable, current schema | yes |
| `05-Honeycomb` | Alpha and Bravo connected and healthy | yes |
| `07-Simulator` | Install still valid; Community folder taken from `UserCfg.opt` | yes |
| `10-FSUIPC` | Installed, registered, knows both devices | yes |
| `20-Internet` | Internet and SimBrief reachable | **no** |
| `30-Fleet` | Has the installed fleet changed since it was last classified | **no** |

Config comes first because nothing later can be compared against anything
without it, and because rewriting settings underneath a running simulator makes
a mess that is hard to explain afterwards.

Hardware comes second, ahead of the configuration checks, because it is
independent of all of them, instant to test, and **the thing most likely to be
wrong on any given day**. A USB cable is what changes; an install path is not.
Putting it early means the user is plugging the yoke in while the rest runs.

## Verify, then work

The gate is read-only. Checks answer questions; they never fix, write or scan.

That is what makes failing early worth anything: when a check fails, nothing has
been changed yet. A sequence that verified four things and then wrote a profile
halfway through a fifth would leave the machine in a state nobody asked for.

So a check may report that the Community folder has moved and say what the new
value should be — but writing it back is setup's job, after the gate passes and
after a snapshot. The same goes for classifying aircraft: `30-Fleet` takes a
cheap fingerprint to decide whether a scan is *needed*; the scan itself happens
later, because it writes.

## Adding a check

Drop a `.ps1` in `Checks\`. It is dot-sourced and must return one hashtable:

```powershell
@{
    Name        = 'GSX'
    Description = 'GSX ground services'
    Run = {
        Add-Result 'GSX installed' 'PASS' 'Found at C:\...'
    }
}
```

Files run in filename order, so the `NN-` prefix controls sequence. The host
knows nothing about any particular add-on; `Invoke-Preflight.ps1` should never
need editing to add one.

Because checks are dot-sourced into the host scope, these are available:
`Add-Result`, `Join-PathSafe`, `Test-PathSafe`, `Get-FirstMatch`,
`Find-Msfs2024`, `Get-InstalledPackagesPath`.

### Add-Result

```powershell
Add-Result <Check> <State> [Detail] [Remedy] [-Blocking]
```

States are not interchangeable:

| State | Means |
|---|---|
| `PASS` | Verified good. |
| `FAIL` | Broken. `-Blocking` decides whether it stops the launch. |
| `WARN` | Works, but something is off and someone should look. |
| `TODO` | Not configured **yet**. The expected state of a machine this project has not been set up on. |
| `SKIP` | A precondition was absent, so the check could not run. **Not** a pass. |
| `INFO` | Context, no judgement. |

**`TODO` is the one people get wrong.** A machine with no lever assignments and
no aircraft profiles is not broken — it is new. Reporting that as a failure
teaches the user that the report is noise, and a report that gets ignored is
worse than no report at all.

Use `-Blocking` only where continuing would produce a broken or misleading
flight. It is the difference between "worth knowing" and "stop".

### Writing a Remedy

`Remedy` is read by the person sitting at the machine. They may be alone, they
may be reading it down a telephone to someone trying to help, and they will read
it literally.

- One action, in plain words.
- Name what they can see and touch, not what the software calls it.
- No jargon, no error codes, no "should".

Good: *"Check the quadrant is plugged in and its lights are on, then start
FSUIPC7 again."*

Bad: *"HID enumeration returned no matching VID/PID; verify device
connectivity."*

## One problem, one message

Checks run in filename order, and a later check often fails *only because* an
earlier one did — FSUIPC has no record of the yoke because the yoke is
unplugged. Reporting both hands the user two things to do when there is one
thing wrong, and the second is impossible until the first is done.

A check that would be reporting a consequence asks first:

```powershell
} elseif (Test-AlreadyFailed 'Alpha yoke connected') {
    Add-Result 'FSUIPC knows the yoke' 'SKIP' `
        'Not checked - the yoke is not plugged in, which is already reported above.'
}
```

`SKIP` rather than silence: we genuinely did not verify it, and the report
should say so. It just is not a second instruction.

## Waiting for the user to fix something

`-Retry` prints the blocking problems with their remedies, then re-checks every
few seconds until they clear or `-RetryTimeoutSeconds` expires.

Deliberately **no keypress**. "Press any key to continue" is one more thing to
explain to somebody who is already stuck, and it invites pressing a key without
doing the thing. Remedy text can therefore promise that the program will notice
by itself — *"This screen will notice on its own, there is nothing to press."*

## Live state must be checked live

Do not infer presence from another program's configuration file. FSUIPC's
`[JoyNames]` is a snapshot from whenever it last ran and will report a quadrant
that was unplugged yesterday.

The Honeycomb check asks Windows directly (`Win32_PnPEntity`, about a second, no
admin), which also distinguishes *not plugged in* from *plugged in but Windows
reports a problem* — two different faults with two different remedies.

## Never wrap a block of work in a silent catch

Guarding one optional read is fine, because a failure genuinely means "absent"
and the fallback is correct:

```powershell
try { $when = $cfg.generatedUtc } catch { }     # fine - absent is a real answer
```

Wrapping a *block of work* is not:

```powershell
try { ...twenty lines of searching... } catch { }   # never
```

This already cost a real defect. The stray-folder search threw, the empty catch
swallowed it, the search silently stopped finding anything, and the gate went on
reporting that all was well. A check that quietly stops working is worse than
one that fails loudly, because nobody goes looking for it.

Report it as `SKIP` with the message, and say it is a fault in the program
rather than in the user's setup.

## PowerShell traps for check authors

**`-f` inside a method call.** The comma is an argument separator there, not an
array constructor, so the format string receives one value for two placeholders
and throws. This is what caused the silent failure above.

```powershell
$list.Add('{0} ({1})' -f $path, $n)      # throws
$list.Add(('{0} ({1})' -f $path, $n))    # correct
```

**`+` resolves by the type of the left operand.** A number followed by a string
tries to parse the string as a number. Use format strings.

```powershell
$total + ' packages'                      # throws
'{0} packages' -f $total                  # correct
```

**Array parameters through `-File`.** PowerShell does not split a comma-separated
value into an array when the script is invoked with `-File`, so `-Only A,B`
arrives as a single string matching nothing. The host splits it defensively.



The host runs under `Set-StrictMode -Version 2.0`. A function returning `@(...)`
with exactly **one** element has that element unwrapped on return, so
`(Get-Thing).Count` throws rather than returning 1. Return `,@(...)` and wrap
call sites in `@(...)`.

This is not academic: it killed the gate mid-run, and because the script died
with exit code 1 it was indistinguishable from a legitimate NO-GO — a crash
wearing the costume of a verdict. A script-scope `trap` now converts any
unexpected error into `CANNOT RUN` (exit 2), which is the honest answer when
nothing was verified.

## Two traps already hit here

Both produced a *healthy* machine reported as broken, which is the failure this
gate can least afford.

- Scanning the FSUIPC log for `unregistered` matches `Hot key unregistered`,
  which it writes during a completely normal shutdown. Test **positively** for
  the thing you want (`Key is provided`) rather than negatively for a word that
  appears in benign lines.
- Scanning for `***` matches FSUIPC's own banner and its harmless preset
  notices. Match whole words, and be specific.

A gate that cries wolf gets ignored. Prefer a missed warning to a false alarm
when the person reading it cannot tell the difference.

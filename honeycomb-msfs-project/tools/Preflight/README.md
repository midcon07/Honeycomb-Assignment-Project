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

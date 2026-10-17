# scripts/hardware/phone-claim.ps1 - the lease over the one physical test phone.
#
# Why this exists: the Galaxy Z Flip4 is one handset shared by three agents, and in practice two of them
# drove it at the same time. One run left the phone held by the parental lock overlay and its owner went
# unreachable; the other needed the handset for the Phase 1 gate and could not tell "free" from "stranded".
# A lease turns "who may touch it" into a fact on disk: claim before the first adb call, heartbeat while
# you run, release when you are done. A holder who disappears loses the claim when it expires, so the
# phone comes back to the pool without anyone having to find that agent first.
#
# This script never calls adb and never touches the phone. It records permission, not hygiene: the holder
# still owns AGENTS.md section 7 (uninstall, `adb reverse --remove-all`, no leftover overlay or lock), and
# whether a run is approved at all remains the human's call (docs/TESTING.md section 5).
#
# Store: $env:OSRA_PHONE_CLAIM_STORE if set, else %LOCALAPPDATA%\OSRA\phone-claims. It sits outside every
# checkout on purpose: a claim must not show up in `git status`, and two clones of the repo must see one
# record. Every agent on this Windows host runs as the same user, so they share the directory. A remote
# agent, or a second host, needs -Store pointing at a share both sides can write - a local file cannot
# stop a process that never reads it. That limit is real; see "honest limits" below.
#
# Protocol (version 1) - three file operations, so a non-PowerShell agent can honour it without this script:
#   <serial>.json   the lease: owner, purpose, token, claimedAt, heartbeatAt, expiresAt
#   journal.log     append-only, one line per CLAIM / EXPIRE / BREAK / RELEASE
#   CLAIM     create <serial>.json with FileMode.CreateNew: exactly one of two racers wins
#   TAKEOVER  when the file is past expiresAt, rename it aside first and re-read what was renamed; never
#             delete-then-create, because two racers both deleting "the expired file" can have the slower
#             one delete the winner's fresh claim between its read and its delete
#   RELEASE   rename aside, re-check the token, then delete - same race, same reason
#
# Honest limits: the lease is coordination, not access control. Anyone who can write the store can edit
# or delete a claim, and nothing here proves that the holder is the person named in it. What it does
# prove is that two cooperating agents will not both believe they own the phone, and that a claim has an
# end. A remote agent that does not run this (or read the board) still has to be governed on
# docs/QA/TEST-REQUESTS.md; say who has the phone there when you claim it.
#
# Usage (PowerShell 5.1, ASCII):
#   .\phone-claim.ps1 -Action Claim -Owner "Kimi Code" -Purpose "TR-15 bypass probe"
#   .\phone-claim.ps1 -Action Heartbeat -Owner "Kimi Code"           # before a build or a long section
#   .\phone-claim.ps1 -Action Release -Owner "Kimi Code" -LeftState Clean -Note "app uninstalled"
#   .\phone-claim.ps1 -Action Status                                 # holder, time left, last events
#   .\phone-claim.ps1 -Action Status -All                            # every lease in the store
#   .\phone-claim.ps1 -Action Status -Json                           # same, for a wrapper
#   .\phone-claim.ps1 -Action Wait -Owner "Antigravity" -Purpose "TR-16 walk" -WaitMinutes 20
#   .\phone-claim.ps1 -Action Break -Owner "Kimi Code" -Purpose "recover the handset" `
#       -Reason "holder silent 90 min, phone left locked" -Force
#
# -Minutes is 5..240 (default 60). Renew with Heartbeat; a claim you forgot is a phone the next tester
# cannot use. -LeftState is mandatory on Release: Clean (uninstalled, reverse removed, no overlay),
# Locked (the OSRA lock overlay is still up) or Unknown (you did not check). A Locked handover prints the
# recovery step and is noted in the journal, because that is exactly the state that stranded the phone
# once: the overlay outlives the run that raised it.
#
# Exit codes: 0 ok / free, 1 busy (someone else holds it, or Wait timed out), 2 error or bad usage,
#             3 not the holder (Release/Heartbeat under a different owner, or the claim expired).
#
# Traps met while writing this (same family as docs/TESTING.md section 6):
#   - Test-Path then Set-Content is not a lock: two agents both see "free", both write, the last wins.
#     Only [IO.File]::Open(..., CreateNew) decides that race.
#   - Get-Date -UFormat %s returns a local epoch in Windows PowerShell 5.1. Every timestamp here is a
#     DateTimeOffset in ISO 8601 with an offset, parsed culture-invariantly, so a Dubai host and a UTC
#     host read the same expiry.
#   - [IO.File]::Replace($tmp, $lease, $null) throws "The path is not of a legal form" in 5.1: PowerShell
#     binds $null to a [string] parameter as "", and an empty backup path is illegal. [NullString]::Value
#     is the real null; the heartbeat uses that (and prints the exception if the replace still fails).
#   - Nothing renews a claim in the background: no timer, no watcher, no child process (a child started by
#     an agent's shell dies with the shell here). Heartbeat is the caller's job, before the first build
#     and between long probe sections.

[CmdletBinding()]
param(
    [ValidateSet("Claim", "Release", "Heartbeat", "Status", "Wait", "Break")]
    [string]$Action = "Status",
    [string]$Owner = "",
    [string]$Purpose = "",
    [string]$Serial = "R5CW116Y6GF",
    [string]$Store = "",
    [int]$Minutes = 60,
    [int]$WaitMinutes = 15,
    [ValidateSet("Clean", "Locked", "Unknown")]
    [string]$LeftState = "Unknown",
    [string]$Note = "",
    [string]$Reason = "",
    [switch]$Force,
    [switch]$All,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$LeftStateGiven = $PSBoundParameters.ContainsKey("LeftState")

$Dir = if ($Store) { $Store }
       elseif ($env:OSRA_PHONE_CLAIM_STORE) { $env:OSRA_PHONE_CLAIM_STORE }
       elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "OSRA\phone-claims" }
       else { Join-Path $env:TEMP "osra-phone-claims" }
$Serial = $Serial.Trim()
$Key = ($Serial -replace "[^A-Za-z0-9._-]", "_")
$LeasePath = Join-Path $Dir ($Key + ".json")
$Journal = Join-Path $Dir "journal.log"

function Say([string]$s) { [Console]::Out.WriteLine($s) }
function Fail([string]$msg, [int]$code = 2) { [Console]::Error.WriteLine("ERROR: " + $msg); exit $code }

# The journal is one line per event; a multi-line -Purpose or -Note from a caller would break that.
function OneLine([string]$s) { return (($s -replace "\r?\n", " ").Trim()) }

function Format-Time([DateTimeOffset]$t) { return $t.ToString("yyyy-MM-dd HH:mm:ss zzz", $Inv) }

function Parse-Time([string]$s) { return [DateTimeOffset]::Parse($s, $Inv) }

function Get-Ago([string]$iso) {
    if (-not $iso) { return "-" }
    try { $d = Parse-Time $iso } catch { return "-" }
    return ("{0} min ago" -f [int][math]::Floor(([DateTimeOffset]::Now - $d).TotalMinutes))
}

function Format-Stamp([string]$iso) {
    if (-not $iso) { return "-" }
    try { return Format-Time (Parse-Time $iso) } catch { return "-" }
}

function Get-HeldMinutes([string]$iso) {
    if (-not $iso) { return "?" }
    try { return [string]([int][math]::Floor(([DateTimeOffset]::Now - (Parse-Time $iso)).TotalMinutes)) } catch { return "?" }
}

function Get-Left([DateTimeOffset]$exp) {
    $min = [int][math]::Floor(($exp - [DateTimeOffset]::Now).TotalMinutes)
    if ($min -lt 0) { return ("overdue by {0} min" -f (-$min)) }
    return ("{0} min left" -f $min)
}

function Write-Journal([string]$kind, [string]$detail) {
    $line = "{0} | {1} | {2} | {3}" -f ([DateTimeOffset]::Now.ToString("yyyy-MM-ddTHH:mm:sszzz", $Inv)), $kind, $Serial, $detail
    [IO.File]::AppendAllText($Journal, $line + "`r`n", $Utf8)
}

function Ensure-Store {
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
}

function Read-LeaseJson([string]$path) {
    $raw = [IO.File]::ReadAllText($path, $Utf8)
    try { $o = $raw | ConvertFrom-Json } catch { throw "cannot parse $path ($($_.Exception.Message)); use -Action Break -Force -Reason <why> if it is wedged" }
    if (-not $o.owner -or -not $o.token -or -not $o.expiresAt) { throw "the lease in $path is missing owner, token or expiresAt; use -Action Break -Force -Reason <why> if it is wedged" }
    return $o
}

function Get-LeaseExpiry($lease) {
    try { return Parse-Time ([string]$lease.expiresAt) }
    catch { throw ("expiresAt is not an ISO 8601 timestamp: " + $lease.expiresAt) }
}

function Test-LeaseExpired($lease) { return ((Get-LeaseExpiry $lease) -le [DateTimeOffset]::Now) }

function New-LeaseRecord([string]$token) {
    $now = [DateTimeOffset]::Now
    return [pscustomobject]@{
        version      = 1
        serial       = $Serial
        owner        = OneLine $Owner
        purpose      = OneLine $Purpose
        token        = $token
        claimedAt    = $now.ToString("o")
        heartbeatAt  = $now.ToString("o")
        expiresAt    = $now.AddMinutes($Minutes).ToString("o")
        leaseMinutes = $Minutes
        host         = $(if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName })
        pid          = $PID
        note         = $Note.Trim()
    }
}

function Try-CreateLease($record) {
    $json = $record | ConvertTo-Json -Depth 4
    try {
        $fs = [IO.File]::Open($LeasePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    } catch {
        if (Test-Path -LiteralPath $LeasePath) { return $false }
        throw
    }
    try {
        $bytes = $Utf8.GetBytes($json)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
    } finally { $fs.Dispose() }
    return $true
}

function Move-LeaseAside([string]$tag) {
    $dst = "{0}.{1}-{2}" -f $LeasePath, $tag, ([guid]::NewGuid().ToString("N"))
    try { [IO.File]::Move($LeasePath, $dst); return $dst } catch { return $null }
}

function Test-Owner($lease) { return (($lease.owner.Trim()) -eq $Owner.Trim()) }

function Show-Busy($lease) {
    $exp = Get-LeaseExpiry $lease
    Say ("busy: {0} is claimed by {1}" -f $Serial, $lease.owner)
    Say ("  purpose  {0}" -f $lease.purpose)
    Say ("  since    {0} ({1})" -f (Format-Stamp ([string]$lease.claimedAt)), (Get-Ago ([string]$lease.claimedAt)))
    Say ("  expires  {0} ({1})" -f (Format-Time $exp), (Get-Left $exp))
    if ((Test-Owner $lease) -and $Owner.Trim()) {
        Say ("  this is your own claim: -Action Heartbeat to renew it, or -Action Release -Owner ""{0}"" -LeftState Clean|Locked|Unknown to hand it back" -f $lease.owner)
    } else {
        Say "  -> -Action Wait to queue for it, or agree a slot on docs/QA/TEST-REQUESTS.md"
    }
}

function Show-Claimed {
    $lease = Read-LeaseJson $LeasePath
    $exp = Get-LeaseExpiry $lease
    Say ("claimed {0} for {1}" -f $Serial, $lease.owner)
    Say ("  purpose  {0}" -f $lease.purpose)
    Say ("  expires  {0} ({1})" -f (Format-Time $exp), (Get-Left $exp))
    Say ("  store    {0}" -f $Dir)
    Say ("  release when done: -Action Release -Owner ""{0}"" -LeftState Clean|Locked|Unknown" -f $lease.owner)
}

function Show-StatusObject($lease) {
    if (-not $lease) {
        return [pscustomobject]@{ serial = $Serial; state = "FREE" }
    }
    $exp = Get-LeaseExpiry $lease
    return [pscustomobject]@{
        serial            = $lease.serial
        state             = $(if (Test-LeaseExpired $lease) { "EXPIRED" } else { "HELD" })
        holder            = $lease.owner
        purpose           = $lease.purpose
        claimedAt         = $lease.claimedAt
        expiresAt         = $lease.expiresAt
        remainingMinutes  = [int][math]::Floor(($exp - [DateTimeOffset]::Now).TotalMinutes)
        host              = $lease.host
        pid               = $lease.pid
        note              = $lease.note
    }
}

function Show-Recent {
    if (-not (Test-Path -LiteralPath $Journal)) { return }
    $lines = @(Get-Content -LiteralPath $Journal -Tail 200 -Encoding UTF8 |
        Where-Object { $_ -match ("\| " + [regex]::Escape($Serial) + " \|") } |
        Select-Object -Last 5)
    if ($lines.Count -eq 0) { return }
    Say "recent:"
    foreach ($l in $lines) { Say ("  " + $l) }
}

function Test-LastHandoverLocked {
    if (-not (Test-Path -LiteralPath $Journal)) { return $false }
    $lines = @(Get-Content -LiteralPath $Journal -Tail 200 -Encoding UTF8 |
        Where-Object { $_ -match ("\| " + [regex]::Escape($Serial) + " \|") })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match "\| (CLAIM|BREAK) \|") { return $false }
        if ($lines[$i] -match "\| RELEASE \|") { return ($lines[$i] -match "left=Locked") }
    }
    return $false
}

function Invoke-Acquire([switch]$Quiet) {
    for ($i = 0; $i -lt 5; $i++) {
        $rec = New-LeaseRecord ([guid]::NewGuid().ToString("N"))
        if (Try-CreateLease $rec) {
            Write-Journal "CLAIM" ("{0} | {1} | lease {2} min" -f $rec.owner, $rec.purpose, $rec.leaseMinutes)
            if (-not $Quiet) { Show-Claimed }
            return 0
        }
        if (-not (Test-Path -LiteralPath $LeasePath)) { continue }
        $lease = Read-LeaseJson $LeasePath
        if (-not (Test-LeaseExpired $lease)) {
            if (-not $Quiet) { Show-Busy $lease }
            return 1
        }
        # Expired. Rename it aside first so two takers cannot both delete "the expired file" and one of
        # them delete the other's fresh claim.
        $side = Move-LeaseAside "expired"
        if (-not $side) { continue }
        $old = $null
        try { $old = Read-LeaseJson $side } catch { $old = $null }
        if ($old -and -not (Test-LeaseExpired $old)) {
            # A heartbeat landed between our read and the rename: it is not ours to take.
            if (-not (Test-Path -LiteralPath $LeasePath)) { try { [IO.File]::Move($side, $LeasePath) } catch {} }
            if (-not $Quiet) { Show-Busy $old }
            return 1
        }
        if ($old) {
            # "cleared by", not "taken by": between this rename and our CreateNew another racer can win
            # (verified: the loser's EXPIRE line once named the winner), and the CLAIM line names the holder.
            Write-Journal "EXPIRE" ("{0} | {1} | expired {2} | cleared by {3}" -f $old.owner, $old.purpose, $old.expiresAt, $Owner.Trim())
            Remove-Item -LiteralPath $side -Force
            if (-not $Quiet) { Say ("the claim by {0} had expired at {1}; the phone is free to take" -f $old.owner, (Format-Time (Get-LeaseExpiry $old))) }
        } else {
            Remove-Item -LiteralPath $side -Force -ErrorAction SilentlyContinue
        }
    }
    throw "could not settle the lease after 5 attempts; run -Action Status, then -Action Break -Force -Reason <why> if it is wedged"
}

function Invoke-Release {
    if (-not $LeftStateGiven) { Fail "say what state you are handing the phone over in: -LeftState Clean|Locked|Unknown" }
    if (-not (Test-Path -LiteralPath $LeasePath)) {
        Say ("no claim on {0}; nothing to release" -f $Serial)
        return 0
    }
    $lease = Read-LeaseJson $LeasePath
    if (-not $Owner.Trim()) { Fail "pass -Owner with the same name you claimed under" 3 }
    if (-not (Test-Owner $lease)) {
        Fail ("{0} is held by {1}; -Owner does not match, nothing was released" -f $Serial, $lease.owner) 3
    }
    $held = Get-HeldMinutes ([string]$lease.claimedAt)
    $side = Move-LeaseAside "released"
    if (-not $side) { Fail "the claim changed while releasing; run -Action Status and try again" 3 }
    $moved = $null
    try { $moved = Read-LeaseJson $side } catch { $moved = $null }
    if (-not $moved -or $moved.token -ne $lease.token) {
        # Someone replaced the claim between our read and the rename: put it back untouched.
        if (-not (Test-Path -LiteralPath $LeasePath)) { try { [IO.File]::Move($side, $LeasePath) } catch {} }
        Fail "the claim changed while releasing; nothing was released" 3
    }
    Remove-Item -LiteralPath $side -Force
    $detail = "{0} | left={1} | held {2} min" -f $lease.owner, $LeftState, $held
    if ($Note.Trim()) { $detail = $detail + " | " + $Note.Trim() }
    Write-Journal "RELEASE" $detail
    Say ("released {0} ({1}, held {2} min)" -f $Serial, $lease.owner, $held)
    Say ("  left     {0}" -f $LeftState)
    if ($Note.Trim()) { Say ("  note     {0}" -f $Note.Trim()) }
    if ($LeftState -eq "Locked") {
        [Console]::Error.WriteLine("WARNING: the phone was released with the OSRA lock overlay still up. Send ""unlock"" from a parent session (POST /v1/devices/<id>/command) and confirm the status screen is reachable before the next run claims it; the overlay survives the process that raised it (docs/TESTING.md 5a).")
    }
    if ($LeftState -eq "Unknown") {
        Say "  note: handover state was not checked; AGENTS.md section 7 asks for uninstall, reverse removed and no overlay left."
    }
    return 0
}

function Invoke-Heartbeat {
    if (-not $Owner.Trim()) { Fail "pass -Owner with the name the claim was made under" 3 }
    if (-not (Test-Path -LiteralPath $LeasePath)) { Fail ("no claim on {0}; claim it first (-Action Claim -Owner ... -Purpose ...)" -f $Serial) 3 }
    $lease = Read-LeaseJson $LeasePath
    if (-not (Test-Owner $lease)) { Fail ("{0} is held by {1}; -Owner does not match, nothing was renewed" -f $Serial, $lease.owner) 3 }
    if (Test-LeaseExpired $lease) {
        Fail ("the claim expired at {0}; it is free (or already taken), so claim it again" -f (Format-Time (Get-LeaseExpiry $lease))) 3
    }
    $span = $Minutes
    if ($lease.leaseMinutes) { $span = [int]$lease.leaseMinutes }
    $now = [DateTimeOffset]::Now
    $lease.heartbeatAt = $now.ToString("o")
    $lease.expiresAt = $now.AddMinutes($span).ToString("o")
    $json = $lease | ConvertTo-Json -Depth 4
    $tmp = "{0}.tmp-{1}" -f $LeasePath, ([guid]::NewGuid().ToString("N"))
    [IO.File]::WriteAllText($tmp, $json, $Utf8)
    try {
        # [NullString]::Value, not $null: 5.1 passes $null to a [string] parameter as "" and Replace then
        # fails with "The path is not of a legal form" (see the header note).
        [IO.File]::Replace($tmp, $LeasePath, [NullString]::Value)
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Fail ("could not renew the claim: " + $_.Exception.Message + "; run -Action Status") 3
    }
    Say ("renewed {0} for {1} until {2} ({3})" -f $Serial, $lease.owner, (Format-Time (Get-LeaseExpiry $lease)), (Get-Left (Get-LeaseExpiry $lease)))
    return 0
}

function Invoke-Status {
    if ($All) {
        $files = @()
        if (Test-Path -LiteralPath $Dir) { $files = @(Get-ChildItem -LiteralPath $Dir -Filter *.json -File) }
        if ($Json) {
            $items = @()
            foreach ($f in $files) {
                try { $items += Show-StatusObject (Read-LeaseJson $f.FullName) }
                catch { $items += [pscustomobject]@{ serial = $f.BaseName; state = "UNREADABLE"; error = $_.Exception.Message } }
            }
            Say (ConvertTo-Json -InputObject @($items) -Depth 4)
            return 0
        }
        Say ("store    {0}" -f $Dir)
        if ($files.Count -eq 0) { Say "no lease is present (none made yet, or all released)"; return 0 }
        Say ("{0,-16} {1,-8} {2,-18} {3,-14} {4}" -f "SERIAL", "STATE", "HOLDER", "LEFT", "PURPOSE")
        foreach ($f in $files) {
            try {
                $l = Read-LeaseJson $f.FullName
                $expired = Test-LeaseExpired $l
                $left = "-"
                if (-not $expired) { $left = Get-Left (Get-LeaseExpiry $l) }
                $p = [string]$l.purpose
                if ($p.Length -gt 48) { $p = $p.Substring(0, 45) + "..." }
                Say ("{0,-16} {1,-8} {2,-18} {3,-14} {4}" -f $l.serial, $(if ($expired) { "EXPIRED" } else { "HELD" }), $l.owner, $left, $p)
            } catch {
                Say ("{0,-16} {1}" -f $f.BaseName, "UNREADABLE")
            }
        }
        return 0
    }

    $lease = $null
    if (Test-Path -LiteralPath $LeasePath) { $lease = Read-LeaseJson $LeasePath }

    if ($Json) { Say (ConvertTo-Json -InputObject (Show-StatusObject $lease) -Depth 4); return 0 }

    Say ("phone    {0}" -f $Serial)
    Say ("store    {0}" -f $Dir)
    if (-not $lease) {
        Say "state    FREE"
        Say 'anyone may claim it: -Action Claim -Owner <name> -Purpose <what you are running>'
        if (Test-LastHandoverLocked) {
            [Console]::Error.WriteLine('WARNING: the last handover of this phone recorded left=Locked. The OSRA lock overlay may still be up; send "unlock" from a parent session before the first adb call (docs/TESTING.md 5a).')
        }
        return 0
    }
    $exp = Get-LeaseExpiry $lease
    $expired = Test-LeaseExpired $lease
    Say ("state    {0}" -f $(if ($expired) { "EXPIRED" } else { "HELD" }))
    if ($expired) { Say "         the holder is gone; anyone may claim it - but check the handset for a leftover lock overlay first" }
    Say ("holder   {0}" -f $lease.owner)
    Say ("purpose  {0}" -f $lease.purpose)
    Say ("since    {0} ({1})" -f (Format-Stamp ([string]$lease.claimedAt)), (Get-Ago ([string]$lease.claimedAt)))
    Say ("expires  {0} ({1})" -f (Format-Time $exp), (Get-Left $exp))
    Say ("host     {0} (pid {1})" -f $lease.host, $lease.pid)
    if ($lease.note) { Say ("note     {0}" -f $lease.note) }
    Show-Recent
    return 0
}

function Invoke-Wait {
    $deadline = [DateTimeOffset]::Now.AddMinutes($WaitMinutes)
    $announced = $false
    while ($true) {
        $rc = Invoke-Acquire -Quiet
        if ($rc -eq 0) {
            if (-not $announced) { Say ("{0} was free" -f $Serial) }
            Show-Claimed
            return 0
        }
        if ([DateTimeOffset]::Now -ge $deadline) {
            $lease = $null
            if (Test-Path -LiteralPath $LeasePath) { $lease = Read-LeaseJson $LeasePath }
            if ($lease) { Say ("gave up after {0} min: still held by {1} until {2}" -f $WaitMinutes, $lease.owner, (Format-Time (Get-LeaseExpiry $lease))) }
            else { Say ("gave up after {0} min: no claim, but the lease kept changing" -f $WaitMinutes) }
            return 1
        }
        if (-not $announced) {
            $lease = $null
            if (Test-Path -LiteralPath $LeasePath) { $lease = Read-LeaseJson $LeasePath }
            if ($lease) { Show-Busy $lease }
            $announced = $true
        }
        $nap = 20 + (Get-Random -Maximum 6)
        Say ("  retrying in {0} s (deadline {1})" -f $nap, (Format-Time $deadline))
        Start-Sleep -Seconds $nap
    }
}

function Invoke-Break {
    if ($Reason.Trim().Length -lt 10) { Fail "pass -Reason (at least 10 characters) saying why the current claim is being broken; it goes in the journal" }
    if (-not (Test-Path -LiteralPath $LeasePath)) {
        Say ("break-glass on {0}: no claim was present" -f $Serial)
        return Invoke-Acquire
    }
    # A wedged or hand-edited lease must not be able to block the break-glass path that exists for it.
    $lease = $null
    $expired = $true
    try {
        $lease = Read-LeaseJson $LeasePath
        $expired = Test-LeaseExpired $lease
    } catch {
        $lease = $null
    }
    if ($lease -and (-not $expired) -and (-not $Force)) {
        Fail ("{0} is still held by {1} until {2}; breaking a live claim needs -Force and a reason" -f $Serial, $lease.owner, (Format-Time (Get-LeaseExpiry $lease)))
    }
    $prev = "an unreadable lease file"
    if ($lease) { $prev = "{0} ({1}), {2}, expires {3}" -f $lease.owner, $lease.purpose, $(if ($expired) { "expired" } else { "live" }), (Format-Time (Get-LeaseExpiry $lease)) }
    $side = Move-LeaseAside "broken"
    if (-not $side) { Fail "the claim changed while breaking it; run -Action Status and try again" }
    if ($lease) {
        $moved = $null
        try { $moved = Read-LeaseJson $side } catch { $moved = $null }
        if ($moved -and $moved.token -ne $lease.token) {
            if (-not (Test-Path -LiteralPath $LeasePath)) { try { [IO.File]::Move($side, $LeasePath) } catch {} }
            Fail "the claim changed while breaking it; nothing was broken"
        }
    } else {
        $moved = $null
        $liveMoved = $false
        try { $moved = Read-LeaseJson $side; $liveMoved = -not (Test-LeaseExpired $moved) } catch { $moved = $null }
        if ($moved -and $liveMoved -and (-not $Force)) {
            if (-not (Test-Path -LiteralPath $LeasePath)) { try { [IO.File]::Move($side, $LeasePath) } catch {} }
            Fail "the lease became readable and is live; breaking it needs -Force"
        }
    }
    Remove-Item -LiteralPath $side -Force
    Write-Journal "BREAK" ("{0} | previous={1} | reason={2}" -f $Owner.Trim(), $prev, $Reason.Trim())
    Say ("break-glass on {0}" -f $Serial)
    Say ("  previous  {0}" -f $prev)
    Say ("  reason    {0}" -f $Reason.Trim())
    Say '  check the handset before the first adb call: a lock overlay or a half-finished setup survives its sender.'
    return Invoke-Acquire
}

$Owner = OneLine $Owner
$Purpose = OneLine $Purpose
$Note = OneLine $Note
$Reason = OneLine $Reason

if (-not $Serial) { Fail "pass -Serial (the adb serial of the phone, e.g. R5CW116Y6GF)" }
if ($Minutes -lt 5 -or $Minutes -gt 240) { Fail "-Minutes must be 5..240; a claim longer than 4 h on a shared phone needs Heartbeat, not a bigger number" }
if ($WaitMinutes -lt 1 -or $WaitMinutes -gt 120) { Fail "-WaitMinutes must be 1..120" }

$rc = 0
try {
    switch ($Action) {
        "Claim" {
            if (-not $Owner.Trim()) { Fail 'pass -Owner with the agent or person claiming the phone (e.g. -Owner "Kimi Code")' }
            if (-not $Purpose.Trim()) { Fail 'pass -Purpose with what the phone is for (e.g. -Purpose "TR-15 bypass probe")' }
            Ensure-Store
            $rc = Invoke-Acquire
        }
        "Wait" {
            if (-not $Owner.Trim()) { Fail 'pass -Owner with the agent or person waiting for the phone' }
            if (-not $Purpose.Trim()) { Fail 'pass -Purpose with what the phone is for' }
            Ensure-Store
            $rc = Invoke-Wait
        }
        "Heartbeat" { Ensure-Store; $rc = Invoke-Heartbeat }
        "Release" { Ensure-Store; $rc = Invoke-Release }
        "Break" {
            if (-not $Owner.Trim()) { Fail 'pass -Owner with who is breaking the claim' }
            if (-not $Purpose.Trim()) { Fail 'pass -Purpose with what the phone is needed for now' }
            Ensure-Store
            $rc = Invoke-Break
        }
        "Status" { $rc = Invoke-Status }
    }
} catch {
    Fail $_.Exception.Message
}
exit $rc

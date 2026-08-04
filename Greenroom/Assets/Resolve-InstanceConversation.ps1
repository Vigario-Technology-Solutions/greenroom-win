# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Which conversation an instance launches with.

  Dot-sourced by greenroom-launch.ps1 rather than imported from the module. The launcher
  finds this file next to itself via $PSScriptRoot, the same way the .vbs finds the
  watchdog and the watchdog finds the launcher, so the whole chain relocates together.
  `Import-Module Greenroom` would have been the obvious alternative and is wrong here: the
  task hard-codes a VERSIONED asset path, so an import could resolve to a different
  version than the assets being run -- the exact drift Get-InstanceAssetVersion exists to
  catch.

  Kept free of side effects on purpose. It reads, it decides, it returns; the caller does
  the writing. That is what makes it testable without a running instance, and the asset
  layer had no behavioural coverage at all before it.
#>

function Resolve-InstanceConversation {
    <#
      .SYNOPSIS
        Decide which conversation to launch with, and whether to record the choice.

      .OUTPUTS
        SessionId - the id to pass to claude
        Action    - 'resume' (--resume, conversation exists) or 'create' (--session-id)
        Persist   - whether the caller should write SessionId to StatePath
        Reason    - one line for the log, explaining which branch was taken
    #>
    [CmdletBinding()]
    param(
        # The project store for this instance's working directory.
        [Parameter(Mandatory)][string]$Store,
        # conversation.json for this instance.
        [Parameter(Mandatory)][string]$StatePath
    )

    # A transcript is named for its session id. Anything else in the store is not a
    # conversation and must never reach --resume: a bogus id exits 1, and the launcher
    # runs in a hidden window, so the watchdog would crash-loop with nothing on screen.
    $uuid = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    $pinned = $null
    if (Test-Path -LiteralPath $StatePath) {
        try   { $pinned = (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).sessionId }
        catch { $pinned = $null }   # unreadable state reads as no state, never fatal
    }

    # The pin gets the SAME rule as the store listing. conversation.json is a file on
    # disk and is hand-written during a deliberate cutover, so it is untrusted input: a
    # value that is not a session id must never reach --resume. A bare existence check is
    # not enough, because the way a malformed pin survives one is by naming a file that
    # happens to exist. A malformed pin reads as no pin, and says so in the log rather
    # than being dropped quietly -- the window is hidden, so silence is the failure mode.
    $note = ''
    if ($null -ne $pinned -and ($pinned -isnot [string] -or $pinned -notmatch $uuid)) {
        $note   = "ignoring malformed pin '$pinned' -- "
        $pinned = $null
    }

    if ($pinned) {
        if (Test-Path -LiteralPath (Join-Path $Store "$pinned.jsonl")) {
            return [pscustomobject]@{
                SessionId = $pinned
                Action    = 'resume'
                Persist   = $false
                Reason    = "resuming pinned conversation $pinned"
            }
        }
        # Pinned but gone -- store cleared, instance relocated, transcript deleted. Mint
        # rather than resume something that is not there.
        $fresh = [guid]::NewGuid().ToString()
        return [pscustomobject]@{
            SessionId = $fresh
            Action    = 'create'
            Persist   = $true
            Reason    = "pinned conversation $pinned has no transcript -- pinning new $fresh"
        }
    }

    # No pin yet. Adopt the newest conversation already in this working directory and pin
    # it from here on.
    #
    # This is BOOTSTRAP, not migration. It is not here to carry old installs across a
    # version boundary -- it is how an instance installed into a directory that already
    # holds conversations picks one up, which is as true of a fresh install in two years
    # as it is of an upgrade today. Recency is used exactly once, to choose a starting
    # point; identity governs every launch after it.
    $existing = @(Get-ChildItem -LiteralPath $Store -Filter *.jsonl -ErrorAction SilentlyContinue |
                  Where-Object { $_.BaseName -match $uuid } |
                  Sort-Object LastWriteTime)
    if ($existing.Count -gt 0) {
        $adopt = $existing[-1].BaseName
        return [pscustomobject]@{
            SessionId = $adopt
            Action    = 'resume'
            Persist   = $true
            Reason    = "$note" + "adopting newest of $($existing.Count) existing conversation(s) and pinning it: $adopt"
        }
    }

    $fresh = [guid]::NewGuid().ToString()
    return [pscustomobject]@{
        SessionId = $fresh
        Action    = 'create'
        Persist   = $true
        Reason    = "$note" + "no existing conversation -- pinning new $fresh"
    }
}

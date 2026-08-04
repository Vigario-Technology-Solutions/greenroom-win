# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Which conversation an instance launches with.

  This is the first behavioural coverage of anything under Assets/. It exists because the
  failure mode is invisible: the launcher runs in a hidden Windows Terminal window, so a
  decision that resolves to a session id claude will not accept exits 1 with nothing on
  screen and the watchdog crash-loops. Every branch below was verified once by hand
  against a live instance; this is what keeps it verified.

  Hermetic on purpose -- filesystem only, no module, no scheduled task, no claude. The
  helper is dot-sourced exactly the way greenroom-launch.ps1 dot-sources it.
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Assets\Resolve-InstanceConversation.ps1')

    $script:UUID = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    # A transcript, with its mtime pinned so ordering never depends on how fast the test
    # host writes files.
    function FakeTranscript {
        param([string]$Store, [string]$Id, [datetime]$When)
        if (-not (Test-Path $Store)) { New-Item -ItemType Directory -Path $Store -Force | Out-Null }
        $p = Join-Path $Store "$Id.jsonl"
        Set-Content -LiteralPath $p -Value '{"type":"session"}' -Encoding UTF8
        (Get-Item -LiteralPath $p).LastWriteTime = $When
        $p
    }

    function FakePin {
        param([string]$Path, [string]$Id)
        [pscustomobject]@{ sessionId = $Id; pinned = '2026-08-03T00:00:00.0000000-07:00' } |
            ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

Describe 'Resolve-InstanceConversation' {

    Context 'a pin that resolves' {
        It 'resumes the pinned conversation and does not rewrite the pin' {
            $store = Join-Path $TestDrive 'store1'
            $pin   = Join-Path $TestDrive 'conv1.json'
            $id    = '34f1855b-076a-46a7-80b6-12406932e6e1'
            FakeTranscript -Store $store -Id $id -When ([datetime]'2026-08-01') | Out-Null
            FakePin -Path $pin -Id $id

            $r = Resolve-InstanceConversation -Store $store -StatePath $pin
            $r.SessionId | Should -Be $id
            $r.Action    | Should -Be 'resume'
            $r.Persist   | Should -BeFalse
        }

        It 'holds the pin even when a NEWER conversation exists' {
            # The bug this whole change exists to close: a hand-started claude in the same
            # working directory leaves a newer transcript, and -c adopted it.
            $store = Join-Path $TestDrive 'store2'
            $pin   = Join-Path $TestDrive 'conv2.json'
            $mine  = '34f1855b-076a-46a7-80b6-12406932e6e1'
            $newer = 'bd2745c1-bcfd-465f-a831-92e78f3d9735'
            FakeTranscript -Store $store -Id $mine  -When ([datetime]'2026-08-01') | Out-Null
            FakeTranscript -Store $store -Id $newer -When ([datetime]'2026-08-02') | Out-Null
            FakePin -Path $pin -Id $mine

            (Resolve-InstanceConversation -Store $store -StatePath $pin).SessionId |
                Should -Be $mine
        }
    }

    Context 'a pin that does not resolve' {
        It 'mints a new id rather than resuming a transcript that is gone' {
            # --resume on a missing conversation exits 1, inside a hidden window.
            $store = Join-Path $TestDrive 'store3'
            $pin   = Join-Path $TestDrive 'conv3.json'
            New-Item -ItemType Directory -Path $store -Force | Out-Null
            FakePin -Path $pin -Id '34f1855b-076a-46a7-80b6-12406932e6e1'

            $r = Resolve-InstanceConversation -Store $store -StatePath $pin
            $r.Action    | Should -Be 'create'
            $r.Persist   | Should -BeTrue
            $r.SessionId | Should -Not -Be '34f1855b-076a-46a7-80b6-12406932e6e1'
            $r.SessionId | Should -Match $script:UUID
        }

        It 'treats an unreadable pin as no pin instead of throwing' {
            $store = Join-Path $TestDrive 'store4'
            $pin   = Join-Path $TestDrive 'conv4.json'
            New-Item -ItemType Directory -Path $store -Force | Out-Null
            Set-Content -LiteralPath $pin -Value 'not json at all' -Encoding UTF8

            { Resolve-InstanceConversation -Store $store -StatePath $pin } | Should -Not -Throw
            (Resolve-InstanceConversation -Store $store -StatePath $pin).Action |
                Should -Be 'create'
        }
    }

    Context 'bootstrap -- no pin yet' {
        It 'adopts the newest existing conversation and pins it' {
            $store = Join-Path $TestDrive 'store5'
            $pin   = Join-Path $TestDrive 'conv5.json'
            $old   = '5a606571-7050-41b1-96ce-351d07393dda'
            $new   = 'f8f9f0de-fdf4-4387-82ca-8e58512529e4'
            FakeTranscript -Store $store -Id $old -When ([datetime]'2026-07-27') | Out-Null
            FakeTranscript -Store $store -Id $new -When ([datetime]'2026-08-03') | Out-Null

            $r = Resolve-InstanceConversation -Store $store -StatePath $pin
            $r.SessionId | Should -Be $new
            $r.Action    | Should -Be 'resume'
            $r.Persist   | Should -BeTrue
        }

        It 'picks by mtime, not by name order' {
            # The newest sorts FIRST by name and the oldest sorts LAST, so anything
            # ordering by name instead of mtime picks the wrong one.
            $store   = Join-Path $TestDrive 'store6'
            $pin     = Join-Path $TestDrive 'conv6.json'
            $newest  = 'aaaaaaaa-0000-4000-8000-000000000000'
            $oldest  = 'ffffffff-0000-4000-8000-000000000000'
            FakeTranscript -Store $store -Id $newest -When ([datetime]'2026-08-03') | Out-Null
            FakeTranscript -Store $store -Id $oldest -When ([datetime]'2026-07-01') | Out-Null

            (Resolve-InstanceConversation -Store $store -StatePath $pin).SessionId |
                Should -Be $newest
        }

        It 'ignores files that are not conversations' {
            # A non-uuid name is not a session id. Passing one to --resume exits 1.
            $store = Join-Path $TestDrive 'store7'
            $pin   = Join-Path $TestDrive 'conv7.json'
            $real  = '34f1855b-076a-46a7-80b6-12406932e6e1'
            FakeTranscript -Store $store -Id $real -When ([datetime]'2026-07-01') | Out-Null
            $junk = Join-Path $store 'notes.jsonl'
            Set-Content -LiteralPath $junk -Value '{}' -Encoding UTF8
            (Get-Item -LiteralPath $junk).LastWriteTime = [datetime]'2026-08-03'

            (Resolve-InstanceConversation -Store $store -StatePath $pin).SessionId |
                Should -Be $real
        }

        It 'mints a fresh id when the store is empty' {
            $store = Join-Path $TestDrive 'store8'
            New-Item -ItemType Directory -Path $store -Force | Out-Null

            $r = Resolve-InstanceConversation -Store $store -StatePath (Join-Path $TestDrive 'conv8.json')
            $r.Action    | Should -Be 'create'
            $r.Persist   | Should -BeTrue
            $r.SessionId | Should -Match $script:UUID
        }

        It 'mints a fresh id when the store does not exist at all' {
            # First install into a brand new working directory: Claude Code has not
            # created the project store yet.
            $r = Resolve-InstanceConversation `
                    -Store    (Join-Path $TestDrive 'no-such-store') `
                    -StatePath (Join-Path $TestDrive 'conv9.json')
            $r.Action    | Should -Be 'create'
            $r.SessionId | Should -Match $script:UUID
        }
    }

    Context 'every branch' {
        It 'always returns an id claude could accept' {
            $store = Join-Path $TestDrive 'store10'
            FakeTranscript -Store $store -Id '34f1855b-076a-46a7-80b6-12406932e6e1' -When ([datetime]'2026-08-01') | Out-Null

            $bad = Join-Path $TestDrive 'conv10-unreadable.json'
            Set-Content -LiteralPath $bad -Value '{ truncated' -Encoding UTF8
            $gone = Join-Path $TestDrive 'conv10-missingpin.json'
            FakePin -Path $gone -Id '00000000-0000-4000-8000-000000000000'

            $cases = @(
                (Join-Path $TestDrive 'conv10-absent.json')   # bootstrap
                $bad                                          # unreadable pin
                $gone                                         # pin with no transcript
            )
            foreach ($c in $cases) {
                (Resolve-InstanceConversation -Store $store -StatePath $c).SessionId |
                    Should -Match $script:UUID
            }
        }
    }
}

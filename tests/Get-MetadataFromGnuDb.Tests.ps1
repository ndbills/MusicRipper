<#
.SYNOPSIS
    Unit tests for the GnuDB metadata provider (Phase 5.2 follow-on).

.DESCRIPTION
    Covers:
      - Get-GnuDbDiscId  (pure disc-id arithmetic on a known TOC)
      - ConvertFrom-GnuDbQueryResponse (200 / 210 / 211 / 202)
      - ConvertFrom-XmcdEntry (happy path, empty-drop, VA detection)
      - Invoke-GnuDbMetadataProvider (full flow, mocked HTTP)
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\metadata\Get-MetadataFromGnuDb.ps1')
}

Describe 'Get-GnuDbDiscId' {

    It 'computes the 8-hex disc-id, frame offsets, and total seconds from a TOC' {
        # A tiny 3-audio-track disc. LBAs chosen so the math is easy to eyeball:
        #   track 1: LBA 0,     length 22500  (5:00)  -> offset 150,    start-sec 2
        #   track 2: LBA 22500, length 15000  (3:20)  -> offset 22650,  start-sec 302
        #   track 3: LBA 37500, length 15000  (3:20)  -> offset 37650,  start-sec 502
        # leadout = 52500 + 150 = 52650 frames. nsecs = (52650-150)/75 = 700.
        # checksum digit-sums: 2 + (3+0+2) + (5+0+2) = 14. xx = 14 % 255 = 14 (0x0e).
        # disc-id = 0e + 02bc + 03 = 0e02bc03.
        $disc = [pscustomobject]@{
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$true; StartSector=0;     LengthSectors=22500 }
                [pscustomobject]@{ Number=2; IsAudio=$true; StartSector=22500; LengthSectors=15000 }
                [pscustomobject]@{ Number=3; IsAudio=$true; StartSector=37500; LengthSectors=15000 }
            )
        }

        $q = Get-GnuDbDiscId -DiscIdInfo $disc
        $q.DiscId  | Should -Be '0e02bc03'
        $q.NTracks | Should -Be 3
        $q.Nsecs   | Should -Be 700
        $q.Offsets | Should -Be @(150, 22650, 37650)
    }

    It 'ignores data tracks when computing the disc-id' {
        # Mixed-mode disc: data track last should not appear in offsets.
        $disc = [pscustomobject]@{
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$true;  StartSector=0;     LengthSectors=22500 }
                [pscustomobject]@{ Number=2; IsAudio=$true;  StartSector=22500; LengthSectors=15000 }
                [pscustomobject]@{ Number=3; IsAudio=$false; StartSector=37500; LengthSectors=99999 }
            )
        }
        $q = Get-GnuDbDiscId -DiscIdInfo $disc
        $q.NTracks | Should -Be 2
        $q.Offsets.Count | Should -Be 2
    }

    It 'throws when the disc has no audio tracks' {
        $disc = [pscustomobject]@{
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$false; StartSector=0; LengthSectors=100 }
            )
        }
        { Get-GnuDbDiscId -DiscIdInfo $disc } | Should -Throw '*no audio tracks*'
    }
}

Describe 'ConvertFrom-GnuDbQueryResponse' {

    It 'parses a 200 single exact match line' {
        $body = "200 rock 9a09348a Pink Floyd / The Wall`r`n"
        $r = @(ConvertFrom-GnuDbQueryResponse -Text $body)
        $r.Count | Should -Be 1
        $r[0].Category | Should -Be 'rock'
        $r[0].DiscId   | Should -Be '9a09348a'
        $r[0].DTitle   | Should -Be 'Pink Floyd / The Wall'
    }

    It 'parses a 210 exact-matches list up to the terminating dot' {
        $body = @(
            "210 Found exact matches, list follows (until terminating `".`")"
            "rock 9a09348a Pink Floyd / The Wall"
            "misc 9a09348b Pink Floyd / The Wall (Remastered)"
            "."
        ) -join "`r`n"
        $r = @(ConvertFrom-GnuDbQueryResponse -Text $body)
        $r.Count | Should -Be 2
        $r[1].DTitle | Should -Be 'Pink Floyd / The Wall (Remastered)'
    }

    It 'parses a 211 inexact-matches list the same way as 210' {
        $body = @(
            "211 Close matches, list follows"
            "folk 12345678 Bob Dylan / Blood on the Tracks"
            "."
        ) -join "`r`n"
        $r = @(ConvertFrom-GnuDbQueryResponse -Text $body)
        $r.Count | Should -Be 1
    }

    It 'returns an empty array on 202 no match' {
        $body = "202 No match found`r`n"
        $r = @(ConvertFrom-GnuDbQueryResponse -Text $body)
        $r.Count | Should -Be 0
    }

    It 'throws on unexpected response codes' {
        { ConvertFrom-GnuDbQueryResponse -Text "500 Syntax error`r`n" } |
            Should -Throw '*500*'
    }
}

Describe 'ConvertFrom-XmcdEntry' {

    BeforeAll {
        $script:disc3 = [pscustomobject]@{
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$true; StartSector=0;     LengthSectors=22500 }
                [pscustomobject]@{ Number=2; IsAudio=$true; StartSector=22500; LengthSectors=15000 }
                [pscustomobject]@{ Number=3; IsAudio=$true; StartSector=37500; LengthSectors=15000 }
            )
        }
    }

    It 'parses a well-formed xmcd body into a candidate' {
        $xmcd = @(
            "# xmcd"
            "# Track frame offsets:"
            "#    150"
            "#    22650"
            "#    37650"
            "#"
            "# Disc length: 700 seconds"
            "#"
            "DISCID=0e02bc03"
            "DTITLE=Pink Floyd / The Wall"
            "DYEAR=1979"
            "DGENRE=Rock"
            "TTITLE0=In the Flesh?"
            "TTITLE1=The Thin Ice"
            "TTITLE2=Another Brick in the Wall Part 1"
            "EXTD="
            "PLAYORDER="
            "."
        ) -join "`r`n"

        $c = ConvertFrom-XmcdEntry -Text $xmcd -Category 'rock' -DiscIdInfo $script:disc3
        $c                   | Should -Not -BeNullOrEmpty
        $c.Source            | Should -Be 'GnuDB'
        $c.AlbumArtist       | Should -Be 'Pink Floyd'
        $c.Album             | Should -Be 'The Wall'
        $c.Year              | Should -Be 1979
        $c.Genre             | Should -Be 'Rock'
        $c.Tracks.Count      | Should -Be 3
        $c.Tracks[0].Title   | Should -Be 'In the Flesh?'
        $c.Tracks[2].Title   | Should -Be 'Another Brick in the Wall Part 1'
        $c.IsCompilation     | Should -BeFalse
    }

    It 'concatenates multiple TTITLE lines with the same index (long-title wrap)' {
        $xmcd = @(
            "DTITLE=A / B"
            "TTITLE0=A Very Long Title"
            "TTITLE0= That Wraps Across Two Lines"
            "TTITLE1=Short"
            "TTITLE2=Also Short"
            "."
        ) -join "`r`n"
        $c = ConvertFrom-XmcdEntry -Text $xmcd -Category 'misc' -DiscIdInfo $script:disc3
        $c.Tracks[0].Title | Should -Be 'A Very Long Title That Wraps Across Two Lines'
    }

    It 'falls back to Category when DGENRE is empty' {
        $xmcd = @(
            "DTITLE=X / Y"
            "DYEAR="
            "DGENRE="
            "TTITLE0=t"
            "."
        ) -join "`r`n"
        $c = ConvertFrom-XmcdEntry -Text $xmcd -Category 'soundtrack' -DiscIdInfo $script:disc3
        $c.Genre | Should -Be 'soundtrack'
    }

    It 'flags Various Artists discs as compilations' {
        foreach ($artist in 'Various', 'Various Artists', 'VA', 'various artists') {
            $xmcd = "DTITLE=$artist / Summer Mix 2006`r`nTTITLE0=t`r`n."
            $c = ConvertFrom-XmcdEntry -Text $xmcd -Category 'misc' -DiscIdInfo $script:disc3
            $c.IsCompilation | Should -BeTrue
        }
    }

    It 'returns $null when every field is blank' {
        $xmcd = "DTITLE=`r`nDYEAR=`r`nDGENRE=`r`nTTITLE0=`r`n."
        $c = ConvertFrom-XmcdEntry -Text $xmcd -Category 'misc' -DiscIdInfo $script:disc3
        $c | Should -BeNullOrEmpty
    }

    It 'pads the Tracks array to the disc audio-track count' {
        # xmcd only had one TTITLE; we should still see 3 track slots.
        $xmcd = "DTITLE=A / B`r`nTTITLE0=first`r`n."
        $c = ConvertFrom-XmcdEntry -Text $xmcd -Category 'misc' -DiscIdInfo $script:disc3
        $c.Tracks.Count    | Should -Be 3
        $c.Tracks[1].Title | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-GnuDbMetadataProvider end-to-end (mocked HTTP)' {

    BeforeAll {
        $script:disc = [pscustomobject]@{
            DiscId = 'mb-id-here'
            Tracks = @(
                [pscustomobject]@{ Number=1; IsAudio=$true; StartSector=0;     LengthSectors=22500 }
                [pscustomobject]@{ Number=2; IsAudio=$true; StartSector=22500; LengthSectors=15000 }
                [pscustomobject]@{ Number=3; IsAudio=$true; StartSector=37500; LengthSectors=15000 }
            )
        }
    }

    It 'returns NoMatch when the query responds 202' {
        $fake = { param($Url) [pscustomobject]@{ Content = "202 No match`r`n" } }
        $r = Invoke-GnuDbMetadataProvider -DiscIdInfo $script:disc -InvokeWebRequest $fake
        $r.Source | Should -Be 'GnuDB'
        $r.Status | Should -Be 'NoMatch'
        $r.Candidates.Count | Should -Be 0
    }

    It 'returns a single Match when query is 200 and read parses cleanly' {
        $script:seen = @()
        $fake = {
            param($Url)
            $script:seen += $Url
            if ($Url -match 'cddb\+query') {
                return [pscustomobject]@{ Content = "200 rock 0e02bc03 Pink Floyd / The Wall`r`n" }
            }
            # The read call.
            return [pscustomobject]@{ Content = @(
                "210 rock 0e02bc03 CD database entry follows"
                "DTITLE=Pink Floyd / The Wall"
                "DYEAR=1979"
                "DGENRE=Rock"
                "TTITLE0=In the Flesh?"
                "TTITLE1=The Thin Ice"
                "TTITLE2=Another Brick in the Wall Part 1"
                "."
            ) -join "`r`n" }
        }

        $r = Invoke-GnuDbMetadataProvider -DiscIdInfo $script:disc -InvokeWebRequest $fake
        $r.Status              | Should -Be 'Match'
        $r.Candidates.Count    | Should -Be 1
        $r.BestMatch.AlbumArtist | Should -Be 'Pink Floyd'
        $r.BestMatch.Album       | Should -Be 'The Wall'
        $r.BestMatch.Tracks[0].Title | Should -Be 'In the Flesh?'
        # We should have issued exactly two HTTP calls (1 query + 1 read).
        $script:seen.Count | Should -Be 2
    }

    It 'returns MultiMatch and reads up to MaxCandidates entries on a 210 list' {
        $fake = {
            param($Url)
            if ($Url -match 'cddb\+query') {
                return [pscustomobject]@{ Content = @(
                    "210 Found exact matches, list follows"
                    "rock 0e02bc03 Pink Floyd / The Wall"
                    "misc 0e02bc04 Pink Floyd / The Wall (Remastered)"
                    "misc 0e02bc05 Pink Floyd / The Wall (Deluxe)"
                    "."
                ) -join "`r`n" }
            }
            # Any read: return a minimal valid xmcd body echoing the dtitle.
            if ($Url -match 'read\+(\w+)\+(\w+)') {
                $cat = $Matches[1]; $id = $Matches[2]
                return [pscustomobject]@{ Content = @(
                    "210 $cat $id CD database entry follows"
                    "DTITLE=Pink Floyd / The Wall variant $id"
                    "DYEAR=1979"
                    "TTITLE0=t1"
                    "TTITLE1=t2"
                    "TTITLE2=t3"
                    "."
                ) -join "`r`n" }
            }
            throw "unexpected url $Url"
        }

        $r = Invoke-GnuDbMetadataProvider -DiscIdInfo $script:disc -InvokeWebRequest $fake -MaxCandidates 2
        $r.Status           | Should -Be 'MultiMatch'
        $r.Candidates.Count | Should -Be 2
    }

    It 'returns Offline on network failure' {
        $fake = { param($Url) throw 'The remote name could not be resolved' }
        $r = Invoke-GnuDbMetadataProvider -DiscIdInfo $script:disc -InvokeWebRequest $fake
        $r.Status     | Should -Be 'Offline'
        $r.Diagnostic | Should -Match 'remote name'
    }
}

<#
.SYNOPSIS
    Unit tests for MusicBrainz text-search + the text-search orchestrator.

.DESCRIPTION
    Covers:
      - Invoke-MusicBrainzTextSearchProvider:
          * builds a Lucene query (artist / album / year, double-quote escape)
          * issues exactly one /release/?query=... request, then up to
            DetailLimit /release/{mbid}?inc=... follow-ups
          * returns the uniform provider contract with Source='MusicBrainz'
          * NoMatch on empty stub list, Offline on HTTP throw
      - Search-RipperMetadataByText (orchestrator):
          * dispatches to the named provider via the static switch
          * concatenates candidates across providers
          * returns NoMatch when nothing comes back, Offline when every
            provider was Offline/Error
          * surfaces the "needs at least artist or album" guard
      - Get-RipperTextSearchProviderNames:
          * intersects the configured chain with the supported set
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'src\core\Search-DiscMetadataByText.ps1')

    # A minimal MB /release/{mbid}?inc=... detail object that exercises
    # the parser's "first medium with tracks" fallback (no `discs` field).
    function script:New-FakeMbReleaseDetail {
        param(
            [string]$Id,
            [string]$Title,
            [string]$Artist,
            [string]$Date,
            [string]$Country = 'US'
        )
        [pscustomobject]@{
            id      = $Id
            title   = $Title
            date    = $Date
            country = $Country
            'artist-credit' = @(
                [pscustomobject]@{
                    name        = $Artist
                    joinphrase  = ''
                    artist      = [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000001'; 'sort-name' = $Artist }
                }
            )
            'release-group'      = [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000099'; 'primary-type' = 'Album'; 'first-release-date' = $Date; 'secondary-types' = @() }
            'cover-art-archive'  = [pscustomobject]@{ front = $false }
            media = @(
                [pscustomobject]@{
                    position = 1
                    format   = 'CD'
                    tracks   = @(
                        [pscustomobject]@{
                            position = 1
                            id       = '00000000-0000-0000-0000-000000000010'
                            title    = 'Track One'
                            length   = 215000
                            'artist-credit' = @(
                                [pscustomobject]@{
                                    name = $Artist; joinphrase = ''
                                    artist = [pscustomobject]@{ id='00000000-0000-0000-0000-000000000001'; 'sort-name'=$Artist }
                                }
                            )
                            recording = [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000020'; length = 215000 }
                        }
                    )
                }
            )
        }
    }
}

Describe 'Invoke-MusicBrainzTextSearchProvider' {

    It 'returns NoMatch with a diagnostic when neither artist nor album is given' {
        $r = Invoke-MusicBrainzTextSearchProvider -Artist '' -Album '' -InvokeMb { throw 'should not call' }
        $r.Source     | Should -Be 'MusicBrainz'
        $r.Status     | Should -Be 'NoMatch'
        $r.Candidates | Should -BeNullOrEmpty
        $r.Diagnostic | Should -Match 'artist or album'
    }

    It "builds an artist+album+year Lucene query and URL-encodes it" {
        $captured = New-Object System.Collections.Generic.List[string]
        $invoke = {
            param($Url)
            $captured.Add($Url)
            # First call is the search endpoint; reply with empty stubs
            # so the provider returns NoMatch without any follow-up.
            [pscustomobject]@{ releases = @() }
        }
        Invoke-MusicBrainzTextSearchProvider `
            -Artist 'Pink Floyd' -Album 'The Wall' -Year 1979 `
            -InvokeMb $invoke | Out-Null

        $captured.Count | Should -Be 1
        $captured[0]    | Should -Match '/ws/2/release/\?query='
        $captured[0]    | Should -Match 'fmt=json'
        # URL encoding of `artist:"Pink Floyd" AND release:"The Wall" AND date:1979`
        $captured[0]    | Should -Match 'artist%3A'
        $captured[0]    | Should -Match 'release%3A'
        $captured[0]    | Should -Match 'date%3A1979'
        $captured[0]    | Should -Match 'Pink%20Floyd'
    }

    It 'follows up on the top -DetailLimit stubs and returns parsed candidates' {
        $invoke = {
            param($Url)
            if ($Url -match '/release/\?query=') {
                # 3 stubs, each with an id we can detail-fetch.
                return [pscustomobject]@{
                    releases = @(
                        [pscustomobject]@{ id = 'r-aaa'; title = 'A' }
                        [pscustomobject]@{ id = 'r-bbb'; title = 'B' }
                        [pscustomobject]@{ id = 'r-ccc'; title = 'C' }
                    )
                }
            }
            if     ($Url -match '/release/r-aaa') { return New-FakeMbReleaseDetail -Id 'r-aaa' -Title 'A' -Artist 'X' -Date '1999' }
            elseif ($Url -match '/release/r-bbb') { return New-FakeMbReleaseDetail -Id 'r-bbb' -Title 'B' -Artist 'X' -Date '2000' }
            elseif ($Url -match '/release/r-ccc') { return New-FakeMbReleaseDetail -Id 'r-ccc' -Title 'C' -Artist 'X' -Date '2001' }
            throw "unexpected url: $Url"
        }

        $r = Invoke-MusicBrainzTextSearchProvider `
                -Artist 'X' -Album 'Y' -DetailLimit 2 -InvokeMb $invoke

        $r.Source        | Should -Be 'MusicBrainz'
        $r.Status        | Should -Be 'MultiMatch'
        $r.Candidates    | Should -HaveCount 2
        $r.Candidates[0].ReleaseMbid | Should -Be 'r-aaa'
        $r.Candidates[1].ReleaseMbid | Should -Be 'r-bbb'
        $r.Candidates[0].Tracks      | Should -HaveCount 1
        $r.BestMatch                 | Should -Be $r.Candidates[0]
    }

    It "returns Status=Match (not MultiMatch) when only one detail comes back" {
        $invoke = {
            param($Url)
            if ($Url -match '/release/\?query=') {
                return [pscustomobject]@{ releases = @([pscustomobject]@{ id = 'only-one'; title = 'A' }) }
            }
            New-FakeMbReleaseDetail -Id 'only-one' -Title 'A' -Artist 'X' -Date '1999'
        }
        (Invoke-MusicBrainzTextSearchProvider -Artist 'X' -InvokeMb $invoke).Status | Should -Be 'Match'
    }

    It 'returns Offline when the search endpoint throws' {
        $invoke = { param($Url) throw 'boom: timeout' }
        $r = Invoke-MusicBrainzTextSearchProvider -Artist 'X' -InvokeMb $invoke
        $r.Status     | Should -Be 'Offline'
        $r.Diagnostic | Should -Match 'boom'
    }

    It 'returns NoMatch when the search returns zero stubs (no follow-ups issued)' {
        $invoke = {
            param($Url)
            [pscustomobject]@{ releases = @() }
        }
        $r = Invoke-MusicBrainzTextSearchProvider -Artist 'X' -InvokeMb $invoke
        $r.Status | Should -Be 'NoMatch'
    }

    It 'escapes embedded double-quotes in the artist/album with a backslash' {
        $captured = $null
        $invoke = {
            param($Url) $script:captured = $Url
            [pscustomobject]@{ releases = @() }
        }
        Invoke-MusicBrainzTextSearchProvider -Artist 'AC"DC' -InvokeMb $invoke | Out-Null
        # URL-encoded form of `artist:"AC\"DC"` — backslash = %5C, quote = %22.
        $script:captured | Should -Match '%5C%22'
    }
}

Describe 'Search-RipperMetadataByText orchestrator' {

    It 'returns NoMatch when no artist/album is given' {
        Mock -CommandName Invoke-MusicBrainzTextSearchProvider -MockWith { throw 'should not call' }
        $r = Search-RipperMetadataByText -Artist '' -Album '' -Providers @('MusicBrainz')
        $r.Status     | Should -Be 'NoMatch'
        $r.Candidates | Should -BeNullOrEmpty
        $r.Diagnostic | Should -Match 'artist or album'
    }

    It 'dispatches to MusicBrainz and surfaces its candidates as MultiMatch' {
        Mock -CommandName Invoke-MusicBrainzTextSearchProvider -MockWith {
            [pscustomobject]@{
                Source     = 'MusicBrainz'
                Status     = 'MultiMatch'
                BestMatch  = [pscustomobject]@{ Source='MusicBrainz'; Album='A'; AlbumArtist='X'; Year=1999; ReleaseMbid='r-1' }
                Candidates = @(
                    [pscustomobject]@{ Source='MusicBrainz'; Album='A'; AlbumArtist='X'; Year=1999; ReleaseMbid='r-1' }
                    [pscustomobject]@{ Source='MusicBrainz'; Album='B'; AlbumArtist='X'; Year=2000; ReleaseMbid='r-2' }
                )
                Diagnostic = $null
            }
        }
        $r = Search-RipperMetadataByText -Artist 'X' -Providers @('MusicBrainz')
        $r.Status                 | Should -Be 'MultiMatch'
        $r.Candidates             | Should -HaveCount 2
        $r.ProviderResults.Count  | Should -Be 1
        Assert-MockCalled Invoke-MusicBrainzTextSearchProvider -Times 1 -Exactly
    }

    It 'returns Offline when every provider response is Offline/Error' {
        Mock -CommandName Invoke-MusicBrainzTextSearchProvider -MockWith {
            [pscustomobject]@{ Source='MusicBrainz'; Status='Offline'; BestMatch=$null; Candidates=@(); Diagnostic='down' }
        }
        $r = Search-RipperMetadataByText -Artist 'X' -Providers @('MusicBrainz')
        $r.Status     | Should -Be 'Offline'
        $r.Candidates | Should -BeNullOrEmpty
    }

    It 'skips unknown / unsupported provider names with a warning and returns NoMatch when nothing remains' {
        $r = Search-RipperMetadataByText -Artist 'X' -Providers @('CuetoolsDb', 'FloppyDisc')
        $r.Status     | Should -Be 'NoMatch'
        $r.Diagnostic | Should -Match 'No text-search-capable providers'
    }

    It 'reports Match (not MultiMatch) when exactly one candidate is returned across providers' {
        Mock -CommandName Invoke-MusicBrainzTextSearchProvider -MockWith {
            [pscustomobject]@{
                Source='MusicBrainz'; Status='Match'
                BestMatch=[pscustomobject]@{ Source='MusicBrainz'; Album='Solo'; AlbumArtist='X' }
                Candidates=@([pscustomobject]@{ Source='MusicBrainz'; Album='Solo'; AlbumArtist='X' })
                Diagnostic=$null
            }
        }
        (Search-RipperMetadataByText -Artist 'X' -Providers @('MusicBrainz')).Status | Should -Be 'Match'
    }
}

Describe 'Get-RipperTextSearchProviderNames' {

    It 'intersects the configured provider chain with the supported set (MusicBrainz only in Commit A)' {
        Mock -CommandName Import-RipperConfig -MockWith {
            [pscustomobject]@{ MetadataProviders = @('MusicBrainz', 'CuetoolsDb', 'GnuDb') }
        }
        $names = Get-RipperTextSearchProviderNames
        $names | Should -Be @('MusicBrainz')
    }

    It 'falls back to the default chain when config has no MetadataProviders field' {
        Mock -CommandName Import-RipperConfig -MockWith { [pscustomobject]@{} }
        $names = Get-RipperTextSearchProviderNames
        $names | Should -Contain 'MusicBrainz'
    }
}

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

    It 'lists configured disc-id providers (intersected with supported) followed by text-search-only providers' {
        Mock -CommandName Import-RipperConfig -MockWith {
            [pscustomobject]@{ MetadataProviders = @('MusicBrainz', 'CuetoolsDb', 'GnuDb') }
        }
        $names = Get-RipperTextSearchProviderNames
        # MusicBrainz first (from the configured chain), then the
        # text-search-only iTunes + Deezer (any order between them).
        $names[0]  | Should -Be 'MusicBrainz'
        $names     | Should -Contain 'iTunesSearch'
        $names     | Should -Contain 'Deezer'
        $names     | Should -Not -Contain 'CuetoolsDb'   # not text-search-capable
        $names     | Should -Not -Contain 'GnuDb'        # not yet (Commit C)
    }

    It 'still surfaces text-search-only providers when no MetadataProviders are configured' {
        Mock -CommandName Import-RipperConfig -MockWith { [pscustomobject]@{} }
        $names = Get-RipperTextSearchProviderNames
        $names | Should -Contain 'MusicBrainz'   # default chain default-includes it
        $names | Should -Contain 'iTunesSearch'
        $names | Should -Contain 'Deezer'
    }
}

Describe 'Invoke-ItunesSearchTextSearchProvider' {

    It 'returns NoMatch with a diagnostic when neither artist nor album is given' {
        $r = Invoke-ItunesSearchTextSearchProvider -Artist '' -Album '' -InvokeWebRequest { throw 'should not call' }
        $r.Source     | Should -Be 'iTunesSearch'
        $r.Status     | Should -Be 'NoMatch'
        $r.Diagnostic | Should -Match 'artist or album'
    }

    It 'searches /search?term=...&entity=album then /lookup?id=&entity=song per top-N hit' {
        $captured = New-Object System.Collections.Generic.List[string]
        $invoke = {
            param($Url)
            $captured.Add($Url)
            if ($Url -match '/search\?') {
                return [pscustomobject]@{
                    results = @(
                        [pscustomobject]@{ collectionId = 1001; collectionName = 'A' }
                        [pscustomobject]@{ collectionId = 1002; collectionName = 'B' }
                    )
                }
            }
            if ($Url -match 'id=1001') {
                return [pscustomobject]@{
                    results = @(
                        [pscustomobject]@{
                            wrapperType    = 'collection'
                            artistName     = 'Pink Floyd'
                            collectionName = 'The Wall'
                            releaseDate    = '1979-11-30T08:00:00Z'
                            country        = 'USA'
                            trackCount     = 2
                            artworkUrl100  = 'http://x/100x100bb.jpg'
                        }
                        [pscustomobject]@{
                            wrapperType     = 'track'
                            kind            = 'song'
                            trackNumber     = 1
                            trackName       = 'In the Flesh?'
                            artistName      = 'Pink Floyd'
                            trackTimeMillis = 199000
                        }
                        [pscustomobject]@{
                            wrapperType     = 'track'
                            kind            = 'song'
                            trackNumber     = 2
                            trackName       = 'The Thin Ice'
                            artistName      = 'Pink Floyd'
                            trackTimeMillis = 167000
                        }
                    )
                }
            }
            if ($Url -match 'id=1002') {
                return [pscustomobject]@{
                    results = @(
                        [pscustomobject]@{
                            wrapperType    = 'collection'
                            artistName     = 'Pink Floyd'
                            collectionName = 'The Wall (Deluxe)'
                            releaseDate    = '2011-01-01T00:00:00Z'
                            country        = 'USA'
                            trackCount     = 1
                        }
                        [pscustomobject]@{
                            wrapperType     = 'track'
                            kind            = 'song'
                            trackNumber     = 1
                            trackName       = 'In the Flesh?'
                            artistName      = 'Pink Floyd'
                            trackTimeMillis = 199000
                        }
                    )
                }
            }
            throw "unexpected url: $Url"
        }

        $r = Invoke-ItunesSearchTextSearchProvider `
                -Artist 'Pink Floyd' -Album 'The Wall' `
                -DetailLimit 2 -InvokeWebRequest $invoke

        $r.Status                       | Should -Be 'MultiMatch'
        $r.Candidates                   | Should -HaveCount 2
        $r.Candidates[0].Source         | Should -Be 'iTunesSearch'
        $r.Candidates[0].Album          | Should -Be 'The Wall'
        $r.Candidates[0].AlbumArtist    | Should -Be 'Pink Floyd'
        $r.Candidates[0].Year           | Should -Be 1979
        $r.Candidates[0].Tracks         | Should -HaveCount 2
        $r.Candidates[0].Tracks[0].Title    | Should -Be 'In the Flesh?'
        $r.Candidates[0].Tracks[0].LengthMs | Should -Be 199000
        # First call is the search; next two are the lookups.
        $captured.Count | Should -Be 3
        $captured[0]    | Should -Match '/search\?term=Pink%20Floyd'
        $captured[1]    | Should -Match 'id=1001'
        $captured[2]    | Should -Match 'id=1002'
    }

    It 'returns Offline when the search endpoint throws' {
        $r = Invoke-ItunesSearchTextSearchProvider -Artist 'X' -InvokeWebRequest { param($Url) throw 'down' }
        $r.Status | Should -Be 'Offline'
    }

    It 'returns NoMatch when the search returns zero hits' {
        $r = Invoke-ItunesSearchTextSearchProvider -Artist 'X' -InvokeWebRequest {
            param($Url) [pscustomobject]@{ results = @() }
        }
        $r.Status | Should -Be 'NoMatch'
    }

    It "flags Various Artists as IsCompilation" {
        $invoke = {
            param($Url)
            if ($Url -match '/search\?') {
                return [pscustomobject]@{ results = @([pscustomobject]@{ collectionId = 99 }) }
            }
            [pscustomobject]@{
                results = @(
                    [pscustomobject]@{
                        wrapperType    = 'collection'
                        artistName     = 'Various Artists'
                        collectionName = 'Comp'
                        releaseDate    = '2010-01-01T00:00:00Z'
                    }
                    [pscustomobject]@{
                        wrapperType = 'track'; kind = 'song'
                        trackNumber = 1; trackName = 'A'; artistName = 'X'; trackTimeMillis = 1000
                    }
                )
            }
        }
        $r = Invoke-ItunesSearchTextSearchProvider -Artist 'Various' -InvokeWebRequest $invoke
        $r.Candidates[0].IsCompilation | Should -BeTrue
    }
}

Describe 'Invoke-DeezerTextSearchProvider' {

    It 'returns NoMatch with a diagnostic when neither artist nor album is given' {
        $r = Invoke-DeezerTextSearchProvider -Artist '' -Album '' -InvokeWebRequest { throw 'should not call' }
        $r.Source     | Should -Be 'Deezer'
        $r.Status     | Should -Be 'NoMatch'
        $r.Diagnostic | Should -Match 'artist or album'
    }

    It 'builds an advanced artist:"X" album:"Y" query and follows up per top-N hit' {
        $captured = New-Object System.Collections.Generic.List[string]
        $invoke = {
            param($Url)
            $captured.Add($Url)
            if ($Url -match '/search/album\?') {
                return [pscustomobject]@{
                    data = @(
                        [pscustomobject]@{ id = 11; title = 'A' }
                        [pscustomobject]@{ id = 22; title = 'B' }
                    )
                }
            }
            if ($Url -match '/album/11') {
                return [pscustomobject]@{
                    title        = 'The Wall'
                    artist       = [pscustomobject]@{ name = 'Pink Floyd' }
                    release_date = '1979-11-30'
                    nb_tracks    = 2
                    record_type  = 'album'
                    label        = 'Harvest'
                    upc          = '00000001'
                    cover_xl     = 'http://img/xl.jpg'
                    tracks       = [pscustomobject]@{
                        data = @(
                            [pscustomobject]@{ track_position = 1; title = 'In the Flesh?'; duration = 199; artist = [pscustomobject]@{ name = 'Pink Floyd' } }
                            [pscustomobject]@{ track_position = 2; title = 'The Thin Ice';  duration = 167; artist = [pscustomobject]@{ name = 'Pink Floyd' } }
                        )
                    }
                }
            }
            if ($Url -match '/album/22') {
                return [pscustomobject]@{
                    title        = 'B'
                    artist       = [pscustomobject]@{ name = 'X' }
                    release_date = '2000-01-01'
                    nb_tracks    = 1
                    tracks       = [pscustomobject]@{ data = @([pscustomobject]@{ track_position=1; title='t'; duration=10 }) }
                }
            }
            throw "unexpected url: $Url"
        }

        $r = Invoke-DeezerTextSearchProvider `
                -Artist 'Pink Floyd' -Album 'The Wall' `
                -DetailLimit 2 -InvokeWebRequest $invoke

        $r.Status              | Should -Be 'MultiMatch'
        $r.Candidates          | Should -HaveCount 2
        $r.Candidates[0].Source       | Should -Be 'Deezer'
        $r.Candidates[0].Album        | Should -Be 'The Wall'
        $r.Candidates[0].AlbumArtist  | Should -Be 'Pink Floyd'
        $r.Candidates[0].Year         | Should -Be 1979
        $r.Candidates[0].LabelName    | Should -Be 'Harvest'
        $r.Candidates[0].Barcode      | Should -Be '00000001'
        $r.Candidates[0].Tracks       | Should -HaveCount 2
        $r.Candidates[0].Tracks[0].LengthMs | Should -Be 199000  # seconds * 1000
        # Search url first, then album detail per id, in order.
        $captured.Count | Should -Be 3
        $captured[0]    | Should -Match 'artist%3A'
        $captured[0]    | Should -Match 'album%3A'
        $captured[1]    | Should -Match '/album/11'
        $captured[2]    | Should -Match '/album/22'
    }

    It 'escapes embedded double-quotes in the artist/album with a backslash' {
        $captured = $null
        $invoke = {
            param($Url) $script:captured = $Url
            [pscustomobject]@{ data = @() }
        }
        Invoke-DeezerTextSearchProvider -Artist 'AC"DC' -InvokeWebRequest $invoke | Out-Null
        # URL-encoded `artist:"AC\"DC"` — backslash + quote -> %5C%22.
        $script:captured | Should -Match '%5C%22'
    }

    It 'returns Offline when the search endpoint throws' {
        $r = Invoke-DeezerTextSearchProvider -Artist 'X' -InvokeWebRequest { param($Url) throw 'down' }
        $r.Status | Should -Be 'Offline'
    }

    It 'returns NoMatch when the search returns zero hits' {
        $r = Invoke-DeezerTextSearchProvider -Artist 'X' -InvokeWebRequest {
            param($Url) [pscustomobject]@{ data = @() }
        }
        $r.Status | Should -Be 'NoMatch'
    }
}

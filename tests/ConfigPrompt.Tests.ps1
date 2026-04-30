# tests/ConfigPrompt.Tests.ps1
#
# Pester tests for src/lib/ConfigPrompt.psm1. Read-Host and the
# folder/file picker shims are all mocked at module scope so we can
# drive the decision tree without the real WPF/WinForms dialogs.

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src\lib\ConfigPrompt.psd1') -Force
}

Describe 'Read-RipperPathPrompt -- existing-value branch' {
    It 'returns the current value when the user presses Enter' {
        Mock -ModuleName ConfigPrompt Read-Host { '' }
        Mock -ModuleName ConfigPrompt Show-RipperFolderPicker { 'C:\should-not-be-called' }
        $r = Read-RipperPathPrompt -Label 'X' -Current 'C:\keep' -Type Folder
        $r | Should -Be 'C:\keep'
        Should -Invoke -ModuleName ConfigPrompt Show-RipperFolderPicker -Times 0
    }

    It "opens the picker when user types 'pick'" {
        Mock -ModuleName ConfigPrompt Read-Host { 'pick' }
        Mock -ModuleName ConfigPrompt Show-RipperFolderPicker { 'C:\new' }
        $r = Read-RipperPathPrompt -Label 'X' -Current 'C:\old' -Type Folder
        $r | Should -Be 'C:\new'
    }

    It "returns null on '-' when AllowClear is true" {
        Mock -ModuleName ConfigPrompt Read-Host { '-' }
        $r = Read-RipperPathPrompt -Label 'X' -Current 'C:\old' -Type Folder -AllowClear $true
        $r | Should -BeNullOrEmpty
    }

    It "rejects '-' when AllowClear is false (re-prompts then accepts Enter)" {
        # First call returns '-', second returns '' so we keep current and exit.
        $script:Calls = 0
        Mock -ModuleName ConfigPrompt Read-Host {
            $script:Calls++
            if ($script:Calls -eq 1) { return '-' }
            return ''
        }
        $r = Read-RipperPathPrompt -Label 'X' -Current 'C:\old' -Type Folder -AllowClear $false
        $r | Should -Be 'C:\old'
        $script:Calls | Should -Be 2
    }
}

Describe 'Read-RipperPathPrompt -- empty-value branch' {
    It 'opens the picker on bare Enter when no current value' {
        Mock -ModuleName ConfigPrompt Read-Host { '' }
        Mock -ModuleName ConfigPrompt Show-RipperFolderPicker { 'C:\picked' }
        $r = Read-RipperPathPrompt -Label 'X' -Current '' -Type Folder
        $r | Should -Be 'C:\picked'
        Should -Invoke -ModuleName ConfigPrompt Show-RipperFolderPicker -Times 1
    }

    It 'returns null when the user cancels the picker on a fresh field with AllowClear' {
        Mock -ModuleName ConfigPrompt Read-Host { '' }
        Mock -ModuleName ConfigPrompt Show-RipperFolderPicker { $null }
        $r = Read-RipperPathPrompt -Label 'X' -Current '' -Type Folder -AllowClear $true
        $r | Should -BeNullOrEmpty
    }

    It 'keeps re-prompting when the picker is cancelled on a required field' {
        # First Read-Host: ''; picker returns $null -> re-prompt.
        # Second Read-Host: ''; picker returns 'C:\eventually'.
        $script:Calls = 0
        Mock -ModuleName ConfigPrompt Read-Host { '' }
        Mock -ModuleName ConfigPrompt Show-RipperFolderPicker {
            $script:Calls++
            if ($script:Calls -eq 1) { return $null }
            return 'C:\eventually'
        }
        $r = Read-RipperPathPrompt -Label 'X' -Current '' -Type Folder -AllowClear $false
        $r | Should -Be 'C:\eventually'
        $script:Calls | Should -Be 2
    }
}

Describe 'Read-RipperPathPrompt -- typed path' {
    It 'accepts a typed path that exists' {
        Mock -ModuleName ConfigPrompt Read-Host { $env:TEMP }
        $r = Read-RipperPathPrompt -Label 'X' -Current '' -Type Folder
        $r | Should -Be $env:TEMP
    }

    It 'strips surrounding quotes from typed input' {
        Mock -ModuleName ConfigPrompt Read-Host { '"' + $env:TEMP + '"' }
        $r = Read-RipperPathPrompt -Label 'X' -Current '' -Type Folder
        $r | Should -Be $env:TEMP
    }

    It 'rejects a non-existent path when MustExist is set, then accepts a real one' {
        $script:Calls = 0
        Mock -ModuleName ConfigPrompt Read-Host {
            $script:Calls++
            if ($script:Calls -eq 1) { return 'C:\definitely-does-not-exist-zzz' }
            return $env:TEMP
        }
        $r = Read-RipperPathPrompt -Label 'X' -Current '' -Type Folder -MustExist $true
        $r | Should -Be $env:TEMP
        $script:Calls | Should -Be 2
    }

    It 'WARNs but accepts a non-existent path when MustExist is false' {
        Mock -ModuleName ConfigPrompt Read-Host { 'C:\does-not-exist-yet' }
        $r = Read-RipperPathPrompt -Label 'X' -Current '' -Type Folder -MustExist $false -WarningAction SilentlyContinue
        $r | Should -Be 'C:\does-not-exist-yet'
    }
}

Describe 'Read-RipperPathPrompt -- File type forwards FileFilter' {
    It 'invokes Show-RipperFilePicker (not Folder) and forwards the filter' {
        Mock -ModuleName ConfigPrompt Read-Host { 'pick' }
        Mock -ModuleName ConfigPrompt Show-RipperFilePicker { 'C:\file.conf' } -ParameterFilter {
            $FileFilter -like '*WireGuard*' -and $Description -like '*conf file*'
        }
        Mock -ModuleName ConfigPrompt Show-RipperFolderPicker { throw 'should not be called' }
        $r = Read-RipperPathPrompt -Label 'WireGuard .conf file' -Current '' -Type File `
                                   -FileFilter 'WireGuard config (*.conf)|*.conf|All files (*.*)|*.*'
        $r | Should -Be 'C:\file.conf'
        Should -Invoke -ModuleName ConfigPrompt Show-RipperFilePicker -Times 1
    }
}

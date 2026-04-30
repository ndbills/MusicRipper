<#
.SYNOPSIS
    Phase 6.6.D: small WPF username/password prompt.

.DESCRIPTION
    Drop-in replacement for `Get-Credential` when the host pwsh
    window is minimised to the tray (e.g. when invoked from
    Show-RipperConfigDialog's Sync tab "Set..." button). The
    built-in Get-Credential in pwsh 7 falls back to a console
    prompt that's invisible if the host is hidden, so we render
    our own modal instead.

    Returns a `[pscredential]` on OK, or `$null` on Cancel /
    window close. Uses the standard topmost-then-clear +
    dispatcher unhandled-exception sink pattern.

.PARAMETER Message
    Caption shown above the username field. Defaults to a generic
    prompt; callers should pass something specific
    (e.g. "Enter the username + password used to mount the NAS").

.PARAMETER Title
    Window title. Defaults to "MusicRipper - credential".

.PARAMETER UserName
    Optional pre-filled username (e.g. when re-entering after a
    typo). The password field is never pre-filled.

.PARAMETER Owner
    Optional parent Window for modality. When set, the dialog
    centres on the owner instead of the screen.
#>

Set-StrictMode -Version 3.0

function Show-RipperCredentialDialog {
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [string]$Message = 'Enter your credentials.',
        [string]$Title   = 'MusicRipper - credential',
        [string]$UserName = '',
        $Owner = $null
    )

    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore      | Out-Null

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$([System.Security.SecurityElement]::Escape($Title))"
        Width="420" SizeToContent="Height"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize" ShowInTaskbar="False">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Name="MessageText"
               TextWrapping="Wrap" Margin="0,0,0,12"/>
    <TextBlock Grid.Row="1" Text="User name" Margin="0,0,0,2"/>
    <TextBox   Grid.Row="2" Name="UserBox"
               Padding="4,3" Margin="0,0,0,8"/>
    <TextBlock Grid.Row="3" Text="Password" Margin="0,0,0,2"/>
    <PasswordBox Grid.Row="4" Name="PassBox"
                 Padding="4,3" Margin="0,0,0,12"/>
    <TextBlock Grid.Row="5" Name="ErrorText" Foreground="#B00020"
               TextWrapping="Wrap" Margin="0,0,0,8" Visibility="Collapsed"/>
    <StackPanel Grid.Row="6" Orientation="Horizontal"
                HorizontalAlignment="Right">
      <Button Name="OkBtn"     Content="OK"     Width="80"
              Margin="0,0,8,0" IsDefault="True"/>
      <Button Name="CancelBtn" Content="Cancel" Width="80"
              IsCancel="True"/>
    </StackPanel>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new(([xml]$xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)

    if ($Owner) {
        try { $window.Owner = $Owner } catch {}
    }

    # Dispatcher unhandled-exception sink (Phase-4 lesson).
    $sidecar = Join-Path $env:LOCALAPPDATA 'MusicRipper\logs\credential-dialog-dispatcher.log'
    $window.Dispatcher.add_UnhandledException({
        param($s, $e)
        try {
            $ex  = $e.Exception
            $msg = "`n=== $(Get-Date -Format o) ===`n$($ex.GetType().FullName): $($ex.Message)`n$($ex.StackTrace)"
            try {
                $dir = Split-Path -Parent $sidecar
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Add-Content -LiteralPath $sidecar -Value $msg -ErrorAction SilentlyContinue
            } catch {}
        } catch {}
        $e.Handled = $true
    })

    # Topmost-then-clear so we steal focus past the minimised host.
    $window.Topmost = $true
    $window.Add_Loaded({
        $this.Activate() | Out-Null
        $this.Topmost = $false
        # Focus the appropriate field.
        $u = $this.FindName('UserBox')
        $p = $this.FindName('PassBox')
        if ($u.Text) { $p.Focus() | Out-Null } else { $u.Focus() | Out-Null }
    }.GetNewClosure())

    $msgText  = $window.FindName('MessageText')
    $userBox  = $window.FindName('UserBox')
    $passBox  = $window.FindName('PassBox')
    $errText  = $window.FindName('ErrorText')
    $okBtn    = $window.FindName('OkBtn')
    $cancelBtn= $window.FindName('CancelBtn')

    $msgText.Text = $Message
    $userBox.Text = $UserName

    # Captured hashtable, not $script:* -- WPF closure gotcha:
    # $script:* writes from .GetNewClosure() handlers in dot-sourced
    # functions don't round-trip back to the function-level read.
    $resultBox = @{ Value = $null }

    $okBtn.Add_Click({
        $u = $userBox.Text
        $secure = $passBox.SecurePassword
        if ([string]::IsNullOrWhiteSpace($u)) {
            $errText.Text = 'User name is required.'
            $errText.Visibility = 'Visible'
            $userBox.Focus() | Out-Null
            return
        }
        if (-not $secure -or $secure.Length -eq 0) {
            $errText.Text = 'Password is required.'
            $errText.Visibility = 'Visible'
            $passBox.Focus() | Out-Null
            return
        }
        $resultBox.Value = [pscredential]::new($u, $secure)
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    $cancelBtn.Add_Click({
        $resultBox.Value = $null
        $window.DialogResult = $false
        $window.Close()
    }.GetNewClosure())

    [void]$window.ShowDialog()
    return $resultBox.Value
}

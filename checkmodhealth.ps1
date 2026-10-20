<#
Halo Mod Health Checker

Point it at a mods folder (one mod, or a folder holding several) and it reports what is wrong
with each mod before you upload it to the Steam Workshop, or put it on a Project Reclaimer
server: what will break, why, and how to fix it. It only reads: nothing is changed.

Run checkmodhealth.cmd. The report is shown and saved in logs\ next to it.

Where the checks come from (October 2026):
  - MCC's own mod loader and 343's uploader, Excession (its rules and limits, read from the
    copies installed with the MCC mod tools: game versions, GUIDs, images, map flags, team counts).
  - Project Reclaimer 0.9.21 (the Halo 3 server), tested against hand-made mods: how it pairs a
    .map with its description, the checks it makes on a map file before using it, its limits.
  - Real broken uploads: a map whose description named the wrong file, a leftover "-old" copy of
    a 2 GB map, a description listed but missing, a map whose tag index was damaged.

Windows only. Needs nothing but Windows PowerShell 5.1, which comes with Windows 10 and 11.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,
    [switch]$NoUpdateCheck,  # don't look for a newer version (tests, or no internet)
    [switch]$NoPause         # don't wait for Enter at the end
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$Repository = 'LittleGroove/Halo-Mod-Health-Checker'
$ToolFolder = $PSScriptRoot
$ProgramFiles = @('checkmodhealth.cmd', 'checkmodhealth.ps1', 'README.md', 'LICENSE')  # what an update replaces

# ------------------------------------------------------------------------------------------------
# What the checks know
# ------------------------------------------------------------------------------------------------

$Engines = @('Halo1', 'Halo2', 'Halo2A', 'Halo3', 'Halo3ODST', 'HaloReach', 'Halo4')
$DeepMapEngines = @('Halo3', 'Halo3ODST')  # maps the deep map checks understand (MCC cache version 13)
$MapFlags = @('DisableSavedFilms', 'HasNoRealGameplay', 'ForgeMap')
$InheritValues = @('FromMCC', 'FromExternalMod', 'Disabled')
# Halo 3's (and ODST's) game categories and the most teams each allows (Excession's Halo3.json).
$MaxTeams = [ordered]@{
    'GameCategory_CTF' = 2; 'GameCategory_Slayer' = 8; 'GameCategory_Oddball' = 8; 'GameCategory_KOTH' = 8
    'GameCategory_Sandbox' = 8; 'GameCategory_VIP' = 8; 'GameCategory_Juggernaut' = 8
    'GameCategory_Territories' = 4; 'GameCategory_Assault' = 2; 'GameCategory_Infection' = 8
    'GameCategory_GunGame' = 8
}
# Halo 3's weapons a map can start players with (Excession's Halo3.json), and "none / map default".
$Halo3Weapons = @(
    'assault_rifle', 'automag', 'battle_rifle', 'beam_rifle', 'brute_plasma_rifle', 'brute_shot', 'carbine',
    'energy_blade', 'excavator', 'flak_cannon', 'flame_thrower', 'flamethrower', 'gravity_hammer', 'magnum_pistol',
    'missle_launcher', 'needler', 'plasma_pistol', 'plasma_rifle', 'rocket_launcher', 'sentinal_gun', 'shotgun',
    'smg', 'smg_s', 'sniper_rifle', 'spartan_laser', 'spike_rifle', 'mauler', 'plasma_cannon', 'invalid'
) | ForEach-Object { "_damage_reporting_type_$_" }
# Halo 3's own multiplayer maps: file name -> map ID (Excession's Halo3.json).
$StockMapIds = @{
    construct = 300; salvation = 350; guardian = 320; deadlock = 310; isolation = 330; zanzibar = 30; chill = 380
    shrine = 400; snowbound = 360; cyberdyne = 390; riverworld = 340; bunkerworld = 410; armory = 580
    warehouse = 480; sidewinder = 470; lockout = 520; ghosttown = 590; chillout = 600; descent = 490
    spacecamp = 500; sandbox = 730; fortress = 740; midship = 720; docks = 440; s3d_waterfall = 706
    s3d_edge = 703; s3d_turf = 31; s3d_reactor = 700; s3d_powerhouse = 715; s3d_avalanche = 705
    s3d_lockout = 711; s3d_sky_bridgenew = 709
}
$NotMaps = @('shared', 'campaign', 'mainmenu')  # .map files that are a mod's own shared files, not maps
$ImageLimitKiB = 900          # Excession: the recommended most for a map's images
$LoadingImageLimitKiB = 3072  # Excession: the most for a loading screen image
$PrPerMod = @{ Maps = 8; Files = 512 }  # Project Reclaimer: what one mod can hold to be shared with players
$PrMapLimit = 4GB; $PrMediaLimit = 2GB; $PrImageLimit = 8MB
$PathLimit = 259  # Windows: longer paths fail to open in many programs

$MCC = 'MCC'; $PR = 'Project Reclaimer'; $BOTH = 'MCC and Project Reclaimer'; $UPLOAD = 'the Workshop upload'

# ------------------------------------------------------------------------------------------------
# Output: everything shown is also kept for the log
# ------------------------------------------------------------------------------------------------

$script:Log = New-Object 'System.Collections.Generic.List[string]'
$script:Width = 100
try { $script:Width = [Math]::Max(60, [Math]::Min(120, $Host.UI.RawUI.WindowSize.Width - 1)) } catch { }

function Say {
    param([string]$Text = '', [ConsoleColor]$Color = [ConsoleColor]::Gray, [int]$Indent = 0, [int]$Hanging = -1)
    if ($Hanging -lt 0) { $Hanging = $Indent }
    foreach ($line in (Format-Wrapped $Text $Indent $Hanging)) {
        Write-Host $line -ForegroundColor $Color
        $script:Log.Add($line)
    }
}

function Format-Wrapped([string]$Text, [int]$Indent, [int]$Hanging) {
    $lines = @()
    $first = $true
    foreach ($paragraph in ($Text -split "`n")) {
        $pad = ' ' * $(if ($first) { $Indent } else { $Hanging })
        $line = $pad
        foreach ($word in ($paragraph -split ' ')) {
            if ($line.Trim().Length -gt 0 -and ($line.Length + 1 + $word.Length) -gt $script:Width) {
                $lines += $line.TrimEnd()
                $first = $false
                $pad = ' ' * $Hanging
                $line = $pad + $word
            } elseif ($line.Trim().Length -eq 0) {
                $line = $pad + $word
            } else {
                $line += ' ' + $word
            }
        }
        $lines += $line.TrimEnd()
        $first = $false
    }
    return $lines
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

# ------------------------------------------------------------------------------------------------
# Updates: look once as it opens, and ask
# ------------------------------------------------------------------------------------------------

function Invoke-UpdateCheck {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = "HaloModHealthChecker/$Version"; 'Accept' = 'application/vnd.github+json' }
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers -TimeoutSec 8
    } catch {
        Say "(Couldn't look for a newer version: $($_.Exception.Message))" DarkGray
        return
    }
    $latest = ([string]$release.tag_name) -replace '^[vV]', ''
    try { if ([version]$latest -le [version]$Version) { return } } catch { return }
    Say "A new version is out: $latest (you have $Version)." Yellow
    $notes = @(([string]$release.body) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 6)
    foreach ($note in $notes) { Say $note DarkYellow 2 }
    $answer = Read-Host 'Update now? [Y/n]'
    if ($answer -match '^\s*n') { Say 'Carrying on with this version.' DarkGray; Say; return }
    $asset = @($release.assets | Where-Object { $_.name -like 'HaloModHealthChecker-*.zip' }) | Select-Object -First 1
    $url = if ($asset) { $asset.browser_download_url } else { $release.zipball_url }
    $work = Join-Path ([IO.Path]::GetTempPath()) ("modhealth-update-" + [Guid]::NewGuid().ToString('N'))
    $moved = @()
    try {
        New-Item -ItemType Directory -Path $work | Out-Null
        $zip = Join-Path $work 'update.zip'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -Headers $headers -TimeoutSec 120
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'new') -Force
        $script = Get-ChildItem -LiteralPath (Join-Path $work 'new') -Recurse -Filter 'checkmodhealth.ps1' | Select-Object -First 1
        if (-not $script) { throw 'the download has no checkmodhealth.ps1' }
        $found = [regex]::Match((Get-Content -LiteralPath $script.FullName -Raw), "\`$Version = '([^']+)'").Groups[1].Value
        if ($found -ne $latest) { throw "the download is version '$found', not $latest" }
        foreach ($name in $ProgramFiles) {
            $new = Join-Path $script.DirectoryName $name
            if (-not (Test-Path -LiteralPath $new)) { continue }
            $old = Join-Path $ToolFolder $name
            if (Test-Path -LiteralPath $old) {
                Move-Item -LiteralPath $old -Destination "$old.previous" -Force
                $moved += $old
            }
            Copy-Item -LiteralPath $new -Destination $old -Force
            Unblock-File -LiteralPath $old -ErrorAction SilentlyContinue
        }
    } catch {
        foreach ($old in $moved) { Move-Item -LiteralPath "$old.previous" -Destination $old -Force -ErrorAction SilentlyContinue }
        Say "The update didn't install ($($_.Exception.Message)); nothing was changed. Carrying on with $Version." Red
        Say
        return
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($old in $moved) { Remove-Item -LiteralPath "$old.previous" -Force -ErrorAction SilentlyContinue }
    Say "Updated to $latest. Starting it..." Green
    Say
    & (Join-Path $ToolFolder 'checkmodhealth.ps1') -Path $Path -NoUpdateCheck -NoPause:$NoPause
    exit $LASTEXITCODE
}

# ------------------------------------------------------------------------------------------------
# Reading files
# ------------------------------------------------------------------------------------------------

function Read-Json([string]$File) {
    # @{ Ok; Value; Problem } - the file's JSON, or what's wrong with it in words
    try {
        $text = [IO.File]::ReadAllText($File)
    } catch {
        return @{ Ok = $false; Value = $null; Problem = "it can't be read: $($_.Exception.Message)" }
    }
    if (-not $text.Trim()) { return @{ Ok = $false; Value = $null; Problem = 'the file is empty' } }
    try {
        return @{ Ok = $true; Value = ($text | ConvertFrom-Json); Problem = '' }
    } catch {
        $message = $_.Exception.Message -replace '\s+', ' '
        return @{ Ok = $false; Value = $null; Problem = "it isn't valid JSON ($message)" }
    }
}

function Get-Prop($Object, [string]$Name) {
    # A field by its exact name (MCC reads names exactly): the PSPropertyInfo, or $null
    if ($null -eq $Object -or $Object -isnot [psobject] -or $Object -is [string] -or $Object -is [array]) { return $null }
    foreach ($property in $Object.PSObject.Properties) { if ($property.Name -ceq $Name) { return $property } }
    return $null
}

function Get-PropOtherCase($Object, [string]$Name) {
    if ($null -eq $Object -or $Object -isnot [psobject] -or $Object -is [string] -or $Object -is [array]) { return $null }
    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -ieq $Name -and $property.Name -cne $Name) { return $property.Name }
    }
    return $null
}

function Get-Text($Value) {
    # A ModInfo text: { "Neutral": "..." } (or a plain string, as some mods write it)
    $neutral = Get-Prop $Value 'Neutral'
    if ($neutral) { $Value = $neutral.Value }
    if ($Value -is [string] -and $Value.Trim()) { return $Value.Trim() }
    return ''
}

function Get-Count($Value) {
    # How many items a JSON value holds (none for a missing one: @($null) would count 1)
    if ($null -eq $Value) { return 0 }
    return @($Value).Count
}

function Test-Guid([string]$Text) {
    $parsed = [Guid]::Empty
    return [Guid]::TryParseExact($Text, 'D', [ref]$parsed) -and $parsed -ne [Guid]::Empty
}

function Get-Head([string]$File, [int]$Count) {
    # The first bytes of a file ($null if it can't be read)
    try {
        $stream = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $buffer = New-Object byte[] $Count
            $read = $stream.Read($buffer, 0, $Count)
            if ($read -lt $Count) { $trimmed = New-Object byte[] $read; [Array]::Copy($buffer, $trimmed, $read); $buffer = $trimmed }
            return , $buffer
        } finally { $stream.Dispose() }
    } catch { return $null }
}

function Get-ImageInfo([string]$File) {
    # @{ Format = 'png' | 'jpg' | 'other'; Width; Height }
    $bytes = Get-Head $File 65536
    $info = @{ Format = 'other'; Width = 0; Height = 0 }
    if ($null -eq $bytes -or $bytes.Length -lt 24) { return $info }
    if ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) {
        $info.Format = 'png'
        $info.Width = ([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor $bytes[19]
        $info.Height = ([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor ([int]$bytes[22] -shl 8) -bor $bytes[23]
    } elseif ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) {
        $info.Format = 'jpg'
        $i = 2
        while ($i + 9 -lt $bytes.Length) {
            if ($bytes[$i] -ne 0xFF) { $i++; continue }
            $marker = $bytes[$i + 1]
            $length = ([int]$bytes[$i + 2] -shl 8) -bor $bytes[$i + 3]
            if ($marker -ge 0xC0 -and $marker -le 0xCF -and $marker -notin 0xC4, 0xC8, 0xCC) {
                $info.Height = ([int]$bytes[$i + 5] -shl 8) -bor $bytes[$i + 6]
                $info.Width = ([int]$bytes[$i + 7] -shl 8) -bor $bytes[$i + 8]
                break
            }
            $i += 2 + $length
        }
    }
    return $info
}

# ------------------------------------------------------------------------------------------------
# A Halo 3 map file, read the way MCC and Project Reclaimer read it before using it
# ------------------------------------------------------------------------------------------------
# A Halo 3 map as MCC ships it (cache version 13), little-endian:
#   0x0000 "head" ("daeh" on disk), version, the length the file should be; 0x00A0 build; 0x00C0 name;
#   0x00E0 the scenario's path; 0x02E0 the tag data's address in memory (64-bit); 0x02E8 the tag index
#   header's; 0x04CC section offsets, 0x04DC sections {address, size}: debug, resources, tags,
#   localization (the tags start in the file at 0x4EC + 0x4D4, 0x4F0 long); 0x3FFC "foot".
# Project Reclaimer 0.9.21 reads the tag index header, the group table, the tag table and the first
# 16 bytes of the scenario tag, each wholly inside the tag data and the file: outside the tag data is
# "its tag index is damaged", past the file's end "its cache is damaged".

$MapCut = 'its cache is damaged'
$MapIndex = 'its tag index is damaged'
$MapNotHalo = 'it is not a Halo 3 cache'
$MapNoScenario = 'it has no scenario'

function New-MapFault([string]$Reason, [string]$Detail) {
    return New-Object System.IO.InvalidDataException ("$Reason`n$Detail")
}

function Read-MapBytes($State, [long]$Offset, [long]$Length, [string]$What) {
    if ($Offset + $Length -gt $State.Size) { throw (New-MapFault $MapCut (Get-ShortText $State $What ($Offset + $Length))) }
    $buffer = New-Object byte[] $Length
    $State.Stream.Position = $Offset
    $read = 0
    while ($read -lt $Length) {
        $count = $State.Stream.Read($buffer, $read, $Length - $read)
        if ($count -le 0) { break }
        $read += $count
    }
    if ($read -lt $Length) { throw (New-MapFault $MapCut (Get-ShortText $State $What ($Offset + $Length))) }
    return , $buffer
}

function Read-TagBytes($State, [long]$Address, [long]$Length, [string]$What) {
    $offset = $Address - $State.Base
    if ($offset -lt 0) {
        throw (New-MapFault $MapIndex ("{0} is at 0x{1:x}, before the map's tag data, which starts at 0x{2:x}" -f $What, $Address, $State.Base))
    }
    if ($offset + $Length -gt $State.TagsSize) {
        $end = $State.Base + $State.TagsSize
        if ($offset -ge $State.TagsSize) {
            throw (New-MapFault $MapIndex ("{0} starts at 0x{1:x}, past the end of the map's tag data at 0x{2:x}" -f $What, $Address, $end))
        }
        throw (New-MapFault $MapIndex ("{0} runs to 0x{1:x}, past the end of the map's tag data at 0x{2:x}" -f $What, ($Address + $Length), $end))
    }
    return , (Read-MapBytes $State ($State.TagsFile + $offset) $Length $What)
}

function Get-ShortText($State, [string]$What, [long]$End) {
    $text = "the file ends after {0:N0} bytes but {1} runs to byte {2:N0}" -f $State.Size, $What, $End
    if ($State.Declared -gt $State.Size) {
        $text += "; its header says it is {0:N0} bytes, so the file was cut short (a download, copy or upload that didn't finish)" -f $State.Declared
    }
    return $text
}

function Get-Ascii([byte[]]$Bytes, [int]$Offset, [int]$Length) {
    $text = [Text.Encoding]::ASCII.GetString($Bytes, $Offset, $Length)
    $nul = $text.IndexOf([char]0)
    if ($nul -ge 0) { $text = $text.Substring(0, $nul) }
    return $text.Trim()
}

function Test-MapFile([string]$File) {
    # @{ Reason (what the server would say; '' when it passes); Detail; Title; Scenario; MapType; MapId; Tags; Build }
    $result = @{ Reason = ''; Detail = ''; Title = ''; Scenario = ''; MapType = $null; MapId = $null; Tags = 0; Build = ''; Engine = '' }
    $stream = $null
    try {
        $stream = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $state = @{ Stream = $stream; Size = $stream.Length; Declared = 0L; Base = 0L; TagsSize = 0L; TagsFile = 0L }
        if ($state.Size -lt 0x4000) {
            throw (New-MapFault $MapCut ("the file is only {0:N0} bytes, less than a map's 16 KB header: it was cut short, or isn't a map" -f $state.Size))
        }
        $head = Read-MapBytes $state 0 0x4000 'its header'
        $magic = [Text.Encoding]::ASCII.GetString($head, 0, 4)
        $version = [BitConverter]::ToUInt32($head, 4)
        $state.Declared = [long][BitConverter]::ToUInt32($head, 8)
        $result.Build = Get-Ascii $head 0xA0 32
        $result.Title = Get-Ascii $head 0xC0 32
        $result.Scenario = Get-Ascii $head 0xE0 256
        if ($magic -ceq 'head') { throw (New-MapFault $MapNotHalo "it is an Xbox 360 map (its bytes run the other way): MCC and Project Reclaimer take the PC (MCC) build of a map") }
        if ($magic -cne 'daeh') {
            $shown = ($head[0..3] | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
            throw (New-MapFault $MapNotHalo "it doesn't start as a map does: its first four bytes are $shown, where a map has 'daeh' ('head' backwards)")
        }
        if ($version -ne 13) {
            throw (New-MapFault $MapNotHalo "it is a version $version map; MCC's Halo 3 maps are version 13 (this one was built by other tools, or for another game or an older MCC)")
        }
        if ([Text.Encoding]::ASCII.GetString($head, 0x3FFC, 4) -cne 'toof') {
            throw (New-MapFault $MapNotHalo "its 16 KB header doesn't end with 'foot' as a Halo 3 map's does: the header is damaged")
        }
        $state.Base = [BitConverter]::ToInt64($head, 0x2E0)
        $index = [BitConverter]::ToInt64($head, 0x2E8)
        $tagsAddress = [long][BitConverter]::ToUInt32($head, 0x4EC)
        $state.TagsSize = [long][BitConverter]::ToUInt32($head, 0x4F0)
        $state.TagsFile = ($tagsAddress + [long][BitConverter]::ToUInt32($head, 0x4D4)) % 4294967296
        if ($state.TagsSize -eq 0) {
            throw (New-MapFault $MapIndex "its tags section is empty, so it has no tag index: it isn't a playable map (Halo 3's shared.map is like this), or it wasn't built in full")
        }
        $header = Read-TagBytes $state $index 32 'its tag index header'
        $groups = [long][BitConverter]::ToUInt32($header, 0)
        $groupsAt = [BitConverter]::ToInt64($header, 8)
        $count = [long][BitConverter]::ToUInt32($header, 0x10)
        $tagsAt = [BitConverter]::ToInt64($header, 0x18)
        $result.Tags = $count
        if ($groups -gt 1024 -or $count -gt 32768) {
            $listed = @()
            if ($count -gt 32768) { $listed += ('{0:N0} tags (at most 32,768 can be read)' -f $count) }
            if ($groups -gt 1024) { $listed += ('{0:N0} tag groups (at most 1,024)' -f $groups) }
            throw (New-MapFault $MapIndex ("its tag index lists " + ($listed -join ' and ')))
        }
        $what = "its tag group table ($groups groups)"
        if (-not ($header | Where-Object { $_ -ne 0 })) { $what = 'its tag index header is all zeros (the tag data is missing), so its tag group table' }
        $table = Read-TagBytes $state $groupsAt ($groups * 16) $what
        $scenarioGroup = -1
        for ($n = 0; $n -lt $groups; $n++) {
            if ([Text.Encoding]::ASCII.GetString($table, 16 * $n, 4) -ceq 'rncs') { $scenarioGroup = $n; break }
        }
        if ($scenarioGroup -lt 0) { throw (New-MapFault $MapNoScenario "none of its $groups tag groups is a scenario ('scnr'): there's no level in it") }
        $entries = Read-TagBytes $state $tagsAt ($count * 8) ('its tag table ({0:N0} tags)' -f $count)
        $number = -1
        for ($n = 0; $n -lt $count; $n++) {
            if ([BitConverter]::ToInt16($entries, 8 * $n) -eq $scenarioGroup) { $number = $n; break }
        }
        if ($number -lt 0) { throw (New-MapFault $MapNoScenario ("none of its {0:N0} tags is a scenario ('scnr'): there's no level in it" -f $count)) }
        $pointer = [long][BitConverter]::ToUInt32($entries, 8 * $number + 4) * 4
        $start = Read-TagBytes $state $pointer 16 "its scenario tag (tag $number)"
        $result.MapType = [BitConverter]::ToInt16($start, 0)
        $result.MapId = [BitConverter]::ToInt32($start, 0xC)
    } catch [System.IO.InvalidDataException] {
        $parts = $_.Exception.Message -split "`n", 2
        $result.Reason = $parts[0]
        $result.Detail = $parts[1]
    } catch {
        $result.Reason = 'unreadable'
        $result.Detail = "it can't be opened or read: $($_.Exception.Message)"
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    return $result
}

# ------------------------------------------------------------------------------------------------
# Findings
# ------------------------------------------------------------------------------------------------

function New-Report([string]$Folder) {
    return [pscustomobject]@{
        Folder = $Folder; Name = (Split-Path $Folder -Leaf); Kind = 'mod'; Engine = ''; ModVersion = ''
        WorkshopId = ''; ModGuid = ''; Facts = (New-Object 'System.Collections.Generic.List[string]')
        Findings = (New-Object 'System.Collections.Generic.List[object]')
        Maps = (New-Object 'System.Collections.Generic.List[object]')  # @{ Stem; File; MapId; Guid; Described }
        MapGuids = (New-Object 'System.Collections.Generic.List[object]')  # @{ Guid; Description }
        Layouts = (New-Object 'System.Collections.Generic.List[object]')
    }
}

function Add-Finding($Report, [string]$Level, [string]$Code, [string]$Title, [string]$Why, [string]$Fix, [string]$Affects) {
    $Report.Findings.Add([pscustomobject]@{ Level = $Level; Code = $Code; Title = $Title; Why = $Why; Fix = $Fix; Affects = $Affects; Order = $Report.Findings.Count })
}

function Get-RelativePath([string]$Root, [string]$File) {
    if ($File.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { return $File.Substring($Root.Length).TrimStart('\', '/') }
    return $File
}

# ------------------------------------------------------------------------------------------------
# Finding the mods
# ------------------------------------------------------------------------------------------------

function Get-MapFiles([string]$Folder) {
    $found = @()
    foreach ($place in @($Folder, (Join-Path $Folder 'maps'))) {
        if (Test-Path -LiteralPath $place -PathType Container) {
            $found += @(Get-ChildItem -LiteralPath $place -Filter '*.map' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.map' -and $NotMaps -notcontains $_.BaseName.ToLowerInvariant() })
        }
    }
    return , @($found | Sort-Object FullName)
}

function Find-Mods([string]$Root) {
    # Each folder with a ModInfo.json (as MCC finds them), and each folder of loose .map files without one
    if (Test-Path -LiteralPath (Join-Path $Root 'ModInfo.json')) { return , @($Root) }
    $found = New-Object 'System.Collections.Generic.List[string]'
    Get-ChildItem -LiteralPath $Root -Recurse -Depth 5 -Filter 'ModInfo.json' -File -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Name -ceq 'ModInfo.json' -or $_.Name -ieq 'ModInfo.json') { $found.Add($_.DirectoryName) } }
    $candidates = @($Root)
    foreach ($top in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if ($top.Name -ieq 'Workshop') { $candidates += @(Get-ChildItem -LiteralPath $top.FullName -Directory | ForEach-Object FullName) }
        else { $candidates += $top.FullName }
    }
    foreach ($folder in $candidates) {
        $inside = $found | Where-Object { $_ -eq $folder -or $_.StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase) -or $folder.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) }
        if ($inside) { continue }
        if ((Get-MapFiles $folder).Count -gt 0) { $found.Add($folder) }
    }
    return , @($found | Sort-Object -Unique)
}

# ------------------------------------------------------------------------------------------------
# The game versions a mod can say it works with
# ------------------------------------------------------------------------------------------------

function Get-SteamApp([string]$AppId) {
    # An installed Steam app's folder, from Steam's own records (registry, libraryfolders.vdf, appmanifest); $null if not there
    $steam = $null
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $item = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) { if ($item.$name -and (Test-Path -LiteralPath $item.$name)) { $steam = $item.$name; break } }
        } catch { }
        if ($steam) { break }
    }
    if (-not $steam) { return $null }
    $libraries = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($match in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $libraries += $match.Groups[1].Value -replace '\\\\', '\'
        }
    }
    foreach ($library in ($libraries | Select-Object -Unique)) {
        $manifest = Join-Path $library "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        $dir = [regex]::Match((Get-Content -LiteralPath $manifest -Raw), '"installdir"\s+"([^"]+)"').Groups[1].Value
        $folder = Join-Path $library "steamapps\common\$dir"
        if ($dir -and (Test-Path -LiteralPath $folder)) { return $folder }
    }
    return $null
}

function Get-GameVersions {
    # @{ Mcc = [version] or $null; ExcessionMin; ExcessionMax }: MCC's own version, and the range Excession offers as "latest"
    $versions = @{ Mcc = $null; ExcessionMin = $null; ExcessionMax = $null }
    try {
        $mcc = Get-SteamApp '976730'
        if ($mcc) {
            $exe = Join-Path $mcc 'MCC\Binaries\Win64\MCC-Win64-Shipping.exe'
            if (Test-Path -LiteralPath $exe) { $versions.Mcc = [version]((Get-Item -LiteralPath $exe).VersionInfo.FileVersion -replace '[^\d.]', '') }
        }
    } catch { }
    try {
        $excession = Get-SteamApp '1695795'
        if ($excession) {
            $lines = @(Get-Content -LiteralPath (Join-Path $excession 'bin\game_client.txt') | Where-Object { $_.Trim() })
            if ($lines.Count -ge 2) { $versions.ExcessionMin = [version]$lines[0].Trim(); $versions.ExcessionMax = [version]$lines[1].Trim() }
        }
    } catch { }
    return $versions
}

function Read-AppVersion($Value) {
    # A ModInfo {Major, Minor, Patch} as a [version], or the problem as text
    if ($null -eq $Value -or $Value -isnot [psobject] -or $Value -is [string]) { return 'it is not written as {"Major": 1, "Minor": 3528, "Patch": 0}' }
    $parts = @()
    foreach ($name in @('Major', 'Minor', 'Patch')) {
        $field = Get-Prop $Value $name
        if (-not $field) { return "it has no $name" }
        if ($field.Value -isnot [int] -and $field.Value -isnot [long]) { return "its $name is not a whole number" }
        if ($field.Value -lt 0) { return "its $name is below 0" }
        $parts += $field.Value
    }
    return [version]("{0}.{1}.{2}" -f $parts[0], $parts[1], $parts[2])
}

# ------------------------------------------------------------------------------------------------
# One mod
# ------------------------------------------------------------------------------------------------

function Test-Mod([string]$Folder, $Versions) {
    $report = New-Report $Folder
    $infoPath = Join-Path $Folder 'ModInfo.json'
    $maps = Get-MapFiles $Folder
    $campaign = Test-Path -LiteralPath (Join-Path $Folder 'CampaignInfo.json')
    $workshopFolder = (Split-Path $Folder -Leaf) -match '^\d+$' -and (Split-Path (Split-Path $Folder -Parent) -Leaf) -ieq 'Workshop'
    if ($workshopFolder) { $report.WorkshopId = Split-Path $Folder -Leaf }

    if (-not (Test-Path -LiteralPath $infoPath)) {
        $report.Kind = 'loose map'
        Add-Finding $report 'WARNING' 'no-modinfo' 'No ModInfo.json: this is a loose map, not a mod package' `
            ("MCC and the Steam Workshop only know a mod by its ModInfo.json, which Excession writes when you make the mod. " +
             "Without it, MCC won't see these maps at all and Excession can't upload them. Project Reclaimer can still play a " +
             "loose .map put in its content\Mods folder (with its .mapinfo, or without one), so this is fine only for a " +
             "server's own copy.") `
            'To share it: open Excession, create a new local mod in this folder, add each map under Multiplayer Maps (it writes ModInfo.json and the map descriptions), then save.' `
            $BOTH
        foreach ($map in $maps) { Test-ModMap $report $map.FullName 'loose' }
        Test-FolderHygiene $report $Folder
        return $report
    }

    $info = Read-Json $infoPath
    if (-not $info.Ok) {
        Add-Finding $report 'PROBLEM' 'modinfo-unreadable' "ModInfo.json can't be read: $($info.Problem)" `
            ("ModInfo.json is how MCC, Excession and Project Reclaimer know the mod: what it is, which game it's for and which " +
             "maps it has. A file they can't read means the whole mod is skipped: MCC lists none of it, and Project " +
             "Reclaimer ignores it.") `
            'Fix the JSON where the message points (a missing comma or quote, a stray character), or open the mod in Excession and save it again so it writes the file afresh.' `
            $BOTH
        Test-FolderHygiene $report $Folder
        return $report
    }
    $data = $info.Value

    # Field names: MCC reads them exactly as written
    foreach ($name in @('ModIdentifier', 'ModVersion', 'MinAppVersion', 'MaxAppVersion', 'Engine', 'Title', 'Description',
                        'InheritSharedFiles', 'ModContents', 'GameModContents')) {
        $other = Get-PropOtherCase $data $name
        if ($other -and -not (Get-Prop $data $name)) {
            Add-Finding $report 'PROBLEM' 'modinfo-field-case' "ModInfo.json writes `"$other`" where MCC reads `"$name`"" `
                "MCC reads ModInfo.json's field names exactly as Excession writes them, capitals included. `"$other`" isn't the same name to it, so the setting is missing as far as the game is concerned." `
                "Rename it to `"$name`" (or re-save the mod in Excession)." $MCC
        }
    }

    # Title, GUID, version
    $title = Get-Text (Get-Prop $data 'Title').Value
    if ($title) { $report.Name = $title } else {
        Add-Finding $report 'WARNING' 'no-title' 'The mod has no title (Title.Neutral)' `
            "MCC's mod list, the Workshop page and Project Reclaimer's mod lists all show a mod by its title. Without one it shows as a blank or as its folder's name, and players can't tell what it is." `
            'Set the title in Excession (or in ModInfo.json: "Title": { "Neutral": "Your Mod" }).' $BOTH
    }
    if (-not (Get-Text (Get-Prop $data 'Description').Value)) {
        Add-Finding $report 'NOTE' 'no-description' 'The mod has no description' `
            'The description is what players read about the mod in MCC and on the Workshop. It works without one.' `
            'Add one in Excession.' $MCC
    }
    $identifier = (Get-Prop $data 'ModIdentifier').Value
    $guid = Get-Prop $identifier 'ModGuid'
    if (-not $guid) {
        Add-Finding $report 'PROBLEM' 'no-modguid' 'ModInfo.json has no ModGuid' `
            "MCC tells mods apart by ModIdentifier.ModGuid: a mod without one is ignored. Excession makes it when it creates the mod." `
            'Re-create the mod in Excession, or add "ModIdentifier": { "ModGuid": "<a new GUID>" } (PowerShell makes one with [guid]::NewGuid()).' $MCC
    } elseif (-not (Test-Guid ([string]$guid.Value))) {
        Add-Finding $report 'PROBLEM' 'bad-modguid' "ModGuid `"$($guid.Value)`" isn't a valid GUID" `
            "MCC tells mods apart by their ModGuid, written like 6bd5cdf7-e40d-41d4-a464-57a1c1b3a256 (and never all zeros). One it can't read, or the all-zero placeholder, makes MCC ignore the mod or mix it up with another." `
            'Give the mod a new GUID in Excession, or write a fresh one in ModInfo.json.' $MCC
    } else { $report.ModGuid = ([string]$guid.Value).ToLowerInvariant() }
    $hosted = (Get-Prop $identifier 'HostedModIds').Value
    $steamId = (Get-Prop $hosted 'SteamWorkshopId').Value
    if ($steamId) {
        if ($workshopFolder -and [string]$steamId -ne $report.WorkshopId) {
            Add-Finding $report 'PROBLEM' 'workshop-id-mismatch' "ModInfo.json says Workshop item $steamId, but this folder is item $($report.WorkshopId)" `
                ("This copy sits in a Workshop\$($report.WorkshopId) folder, so it was downloaded as that item, yet its ModInfo.json names another. Project Reclaimer refuses to install or update it (`"ModInfo.json names a different Workshop item`"), and players' games can't match it to the item they download.") `
                'The uploader: upload this mod to the item its ModInfo.json names, or correct SteamWorkshopId to the item it really is.' $BOTH
        }
        $report.WorkshopId = [string]$steamId
    } elseif (-not $workshopFolder) {
        Add-Finding $report 'NOTE' 'not-uploaded' 'Not uploaded yet (no SteamWorkshopId)' `
            'Excession writes HostedModIds.SteamWorkshopId on the first upload; later uploads update that same item. Nothing to fix.' `
            '' $UPLOAD
    }
    $modVersion = Read-AppVersion (Get-Prop $data 'ModVersion').Value
    if ($modVersion -is [version]) { $report.ModVersion = $modVersion.ToString() }
    elseif (Get-Prop $data 'ModVersion') {
        Add-Finding $report 'WARNING' 'bad-mod-version' "ModVersion can't be read: $modVersion" `
            "ModVersion (Major, Minor, Patch) is how players and other mods that depend on this one tell its versions apart; MCC expects three whole numbers." `
            'Set it in Excession (Mod Version, e.g. 1.2.0).' $MCC
    } else {
        Add-Finding $report 'WARNING' 'no-mod-version' 'ModInfo.json has no ModVersion' `
            "Without a version, players can't tell an update from the copy they have, and mods that depend on this one can't name the version they need." `
            'Set Mod Version in Excession (e.g. 1.0.0) and raise it with each upload.' $MCC
    }

    # The game versions it says it works with
    Test-AppVersions $report $data $Versions

    # The Workshop page Excession makes from the title and description
    if ($title -and [Text.Encoding]::UTF8.GetByteCount($title) -gt 128) {
        Add-Finding $report 'WARNING' 'title-too-long' ("The mod's title is {0} bytes; a Workshop title holds 128" -f [Text.Encoding]::UTF8.GetByteCount($title)) `
            'Excession uses the mod''s title for the Workshop item, and Steam takes at most 128 bytes (fewer characters if they''re accented or not Latin). A longer one fails the upload or is cut.' `
            'Shorten the title.' $UPLOAD
    }
    $about = Get-Text (Get-Prop $data 'Description').Value
    if ($about -and [Text.Encoding]::UTF8.GetByteCount($about) -gt 8000) {
        Add-Finding $report 'WARNING' 'description-too-long' ("The mod's description is {0:N0} bytes; a Workshop description holds 8,000" -f [Text.Encoding]::UTF8.GetByteCount($about)) `
            'Excession uses the mod''s description for the Workshop item, and Steam takes at most 8,000 bytes.' `
            'Shorten it (put the long version on the Workshop page itself).' $UPLOAD
    }

    # Engine
    $engineField = Get-Prop $data 'Engine'
    $engine = if ($engineField) { [string]$engineField.Value } else { '' }
    $report.Engine = $engine
    $contents = (Get-Prop $data 'GameModContents').Value
    $modContents = (Get-Prop $data 'ModContents').Value
    $mpList = @(if ((Get-Count (Get-Prop $contents 'MultiplayerMaps').Value) -gt 0) { (Get-Prop $contents 'MultiplayerMaps').Value })
    $ffList = @(if ((Get-Count (Get-Prop $contents 'FirefightMaps').Value) -gt 0) { (Get-Prop $contents 'FirefightMaps').Value })
    $flag = @{}
    foreach ($name in @('HasSharedFiles', 'HasCampaign', 'HasSpartanOps', 'HasController')) { $flag[$name] = (Get-Prop $contents $name).Value -eq $true }
    foreach ($name in @('HasBackgroundVideos', 'HasNameplates')) { $flag[$name] = (Get-Prop $modContents $name).Value -eq $true }
    $gameStuff = $mpList.Count -or $ffList.Count -or $flag.HasCampaign -or $flag.HasSpartanOps -or $flag.HasController
    if ($engineField -and $engine -and $Engines -notcontains $engine) {
        Add-Finding $report 'PROBLEM' 'bad-engine' "Engine `"$engine`" isn't one MCC knows" `
            ("MCC loads a mod's game contents into the game its Engine names: one of $($Engines -join ', '). Any other value (a typo, wrong capitals) means they're never loaded.") `
            'Pick the game in Excession (Game Engine), or write one of the names above exactly.' $MCC
    } elseif (-not $engine -and $gameStuff) {
        Add-Finding $report 'PROBLEM' 'no-engine' 'The mod has maps or a campaign, but no Engine' `
            "A mod with no Engine isn't for any one game (Excession's docs: it `"will not be targeted at the particular Halo title`"), which suits menu videos and nameplates only. Maps and campaigns are loaded into the game Engine names, so these are skipped." `
            'Pick the Game Engine in Excession.' $MCC
    }
    if ($engine -and $engine -ne 'Halo3') {
        Add-Finding $report 'NOTE' 'not-halo3' "Made for $engine, not Halo 3" `
            ("Project Reclaimer plays Halo 3 mods only: it skips this one without a word. " +
             $(if ($DeepMapEngines -notcontains $engine) { "The deep map checks here read MCC's Halo 3 and ODST maps, so this mod's maps are checked for being there and described, not opened." } else { '' })) `
            '' $PR
    }

    # Where its shared files come from
    $inherit = Get-Prop $data 'InheritSharedFiles'
    if ($inherit -and $InheritValues -notcontains [string]$inherit.Value) {
        Add-Finding $report 'WARNING' 'bad-inherit' "InheritSharedFiles is `"$($inherit.Value)`"" `
            ("InheritSharedFiles says where the mod's maps get the files they share (shared.map and the like): `"FromMCC`" (the game's own; every published mod checked uses it), `"FromExternalMod`" (another mod's) or `"Disabled`" (all in the mod itself). MCC doesn't know another value.") `
            'Set it to "FromMCC" unless the mod is built on another mod.' $MCC
    }
    if ($inherit -and [string]$inherit.Value -eq 'FromExternalMod') {
        $external = (Get-Prop $data 'InheritSharedFilesFromExternalMod').Value
        $externalGuid = (Get-Prop $external 'ModGuid').Value
        if (-not $externalGuid -or -not (Test-Guid ([string]$externalGuid))) {
            Add-Finding $report 'PROBLEM' 'external-mod-missing' 'InheritSharedFiles is "FromExternalMod" but no valid mod is named' `
                "The maps take their shared files from another mod, named by InheritSharedFilesFromExternalMod.ModGuid. Without a valid GUID there MCC can't find it (`"mod says it inherits shared files from an external mod but does not specify which one`") and the maps can't load." `
                'Name the mod it builds on, or set InheritSharedFiles to "FromMCC".' $MCC
        } else {
            $report.Facts.Add("Takes its shared files from the mod $externalGuid, which players need too")
            $script:Dependencies += , @($report, [string]$externalGuid)
        }
    }
    $sharedMaps = @(@('maps\shared.map', 'shared.map') | ForEach-Object { Join-Path $Folder $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if ($flag.HasSharedFiles -and -not $sharedMaps -and -not (Test-Path -LiteralPath (Join-Path $Folder "$($engine.ToLowerInvariant())\maps\shared.map"))) {
        Add-Finding $report 'NOTE' 'shared-flag-on' 'HasSharedFiles is true, but the mod has no shared.map' `
            "Every published mod checked has HasSharedFiles false, even those that ship their own shared.map (in $($engine.ToLowerInvariant())\maps\, where the game's own would be); what MCC does with it set isn't documented. If the maps don't use a shared.map of their own, false is the safe value." `
            'Set HasSharedFiles to false in Excession unless you know the mod needs it.' $MCC
    }

    # What it says it has, against what's there
    $pairs = @(
        @('HasCampaign', 'CampaignInfo.json', 'a campaign', 'Campaign info is being ignored'),
        @('HasSpartanOps', 'SpartanOpsInfo.json', 'Spartan Ops missions', 'SpartanOps info is being ignored'),
        @('HasController', 'ControllerInfo.json', 'controller settings', ''),
        @('HasBackgroundVideos', 'BackgroundVideosInfo.json', 'menu background videos', 'Could not resolve Background video'),
        @('HasNameplates', 'NameplatesInfo.json', 'nameplates', 'Could not resolve Nameplate image'))
    foreach ($pair in $pairs) {
        $there = Test-Path -LiteralPath (Join-Path $Folder $pair[1])
        if ($flag[$pair[0]] -and -not $there) {
            Add-Finding $report 'PROBLEM' 'contents-file-missing' "$($pair[0]) is true but there is no $($pair[1])" `
                ("The mod says it has $($pair[2]), so MCC reads $($pair[1]) to find them. It isn't there, so they aren't loaded" + $(if ($pair[3]) { " (`"$($pair[3])`")." } else { '.' })) `
                "Make them in Excession (it writes $($pair[1])), or set $($pair[0]) to false." $MCC
        } elseif ($there -and -not $flag[$pair[0]]) {
            Add-Finding $report 'WARNING' 'contents-flag-off' "The mod has $($pair[1]), but $($pair[0]) is false" `
                "MCC reads $($pair[1]) only when ModInfo.json's $($pair[0]) is true, so the mod's $($pair[2]) aren't loaded. If they're all the mod has, MCC loads it as empty (`"Mod has no actionable contents`")." `
                "Set $($pair[0]) to true in Excession, or delete $($pair[1]) if the mod doesn't have $($pair[2])." $MCC
        }
    }

    # The maps' descriptions: multiplayer, Firefight and campaign missions
    $referenced = @{}  # map file name (lower case) -> @{ Description; Kind }
    foreach ($relative in $mpList) { Test-Description $report $Folder ([string]$relative) 'multiplayer' $referenced $maps }
    foreach ($relative in $ffList) { Test-Description $report $Folder ([string]$relative) 'firefight' $referenced $maps }
    $campaignInfo = Join-Path $Folder 'CampaignInfo.json'
    if ($flag.HasCampaign -and (Test-Path -LiteralPath $campaignInfo)) { Test-Campaign $report $Folder $campaignInfo $referenced $maps }
    $listedFiles = @($mpList + $ffList | ForEach-Object { ([string]$_ -replace '/', '\').ToLowerInvariant() })
    foreach ($place in @('multiplayer', 'firefight')) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Folder $place) -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $relative = (Get-RelativePath $Folder $file.FullName)
            if ($listedFiles -notcontains $relative.ToLowerInvariant()) {
                Add-Finding $report 'WARNING' 'description-unlisted' "$relative isn't listed in ModInfo.json" `
                    ("MCC reads only the descriptions ModInfo.json lists (GameModContents.$(if ($place -eq 'multiplayer') { 'MultiplayerMaps' } else { 'FirefightMaps' })), so this one is ignored and its map isn't listed. " +
                     $(if ($file.BaseName -ne $file.BaseName.Trim()) { 'Its name also has a space before .json, which is easy to miss when listing it. ' } else { '' }) +
                     'If it is an old description, it is uploaded for nothing.') `
                    'Add the map in Excession (it lists the description), or delete the file.' $MCC
            }
        }
    }

    # The maps in the folder
    foreach ($map in $maps) {
        $stem = $map.BaseName
        $entry = $referenced[$stem.ToLowerInvariant()]
        if ($entry) {
            if ((Split-Path $map.FullName -Parent).TrimEnd('\') -ieq $Folder.TrimEnd('\')) {
                Add-Finding $report 'WARNING' 'map-not-in-maps' "$($map.Name) is in the mod's own folder, not in maps\" `
                    "MCC's mod docs: `"All .map files of the mod package need to be manually placed to the maps subfolder`". Project Reclaimer finds it either way, but MCC looks in maps\." `
                    'Move it into the maps folder.' $MCC
            }
            Test-ModMap $report $map.FullName $entry.Kind
            continue
        }
        $older = $maps | Where-Object { $referenced.ContainsKey($_.BaseName.ToLowerInvariant()) -and $stem.ToLowerInvariant().StartsWith($_.BaseName.ToLowerInvariant()) } | Select-Object -First 1
        if ($older) {
            Add-Finding $report 'WARNING' 'map-old-copy' "$($map.Name) looks like an old copy of $($older.Name) ($(Format-Size $map.Length))" `
                ("No description names it, so MCC never loads it and Project Reclaimer skips it at every start (`"Map needs matching .mapinfo metadata`"). " +
                 "But Excession uploads every file in the mod folder, so every player still downloads it: $(Format-Size $map.Length) for nothing, and it counts against your Steam Cloud quota. " +
                 "A live server ended up with fixedHugeGrassTrapasRemix-old.map this way.") `
                "Delete $($map.Name) (keep backups outside the mod folder)." $UPLOAD
        } else {
            Add-Finding $report 'PROBLEM' 'map-not-described' "$($map.Name) has no description naming it, so it isn't played" `
                ("A mod's map is used only when a description ModInfo.json lists (multiplayer, Firefight or a campaign mission) names it: the last part of its ScenarioFile has to be the map's file name, `"$stem`". " +
                 "None does, so MCC never lists the map and Project Reclaimer skips it (`"Map needs matching .mapinfo metadata`"). Usually the map file was renamed after its description was written, or the description was never added.") `
                ("Add the map in Excession, or set its description's ScenarioFile so it ends in `"$stem`" (Excession writes the scenario's tag path, e.g. levels/multi/$stem/$stem). " +
                 'If the map isn''t meant to be in the mod, delete it.') `
                $BOTH
            Test-ModMap $report $map.FullName ''
        }
    }

    # Videos and nameplates
    $videos = @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter '*.bk2' -File -ErrorAction SilentlyContinue)
    $videoInfo = Join-Path $Folder 'BackgroundVideosInfo.json'
    if (Test-Path -LiteralPath $videoInfo) {
        $read = Read-Json $videoInfo
        if (-not $read.Ok) {
            Add-Finding $report 'PROBLEM' 'videos-unreadable' "BackgroundVideosInfo.json can't be read: $($read.Problem)" `
                'It lists the menu videos the mod adds; MCC can''t read it, so none are loaded.' 'Fix the JSON, or make the videos again in Excession.' $MCC
        } elseif ($read.Value -is [psobject]) {
            foreach ($property in $read.Value.PSObject.Properties) {
                $file = Join-Path $Folder ($property.Name -replace '/', '\')
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                    Add-Finding $report 'PROBLEM' 'video-missing' "BackgroundVideosInfo.json lists $($property.Name), which isn't in the mod" `
                        "MCC drops a video it can't find (`"Could not resolve Background video`")." 'Add the video, or remove it in Excession.' $MCC
                }
                $videoGuid = [string](Get-Prop $property.Value 'VideoGuid').Value
                if (-not (Test-Guid $videoGuid)) {
                    Add-Finding $report 'WARNING' 'video-bad-guid' "$($property.Name) has no valid VideoGuid" `
                        'MCC tells videos apart by their VideoGuid; Excession makes one for each.' 'Add the video again in Excession.' $MCC
                }
            }
        }
    }

    $actionable = $mpList.Count -or $ffList.Count -or $flag.HasCampaign -or $flag.HasSpartanOps -or $flag.HasController -or
        $flag.HasBackgroundVideos -or $flag.HasNameplates -or (Test-Path -LiteralPath (Join-Path $Folder 'customization.json'))
    if (-not $actionable) {
        Add-Finding $report 'PROBLEM' 'no-contents' 'The mod has nothing in it MCC loads' `
            "ModInfo.json lists no multiplayer or Firefight maps and says the mod has no campaign, Spartan Ops, controller settings, videos or nameplates. MCC loads a mod like this as empty (`"Mod has no actionable contents`") and players get nothing from it." `
            'Add the contents in Excession; a file in the folder does nothing until ModInfo.json lists it (or its flag is true).' $MCC
    }

    # Files Project Reclaimer and MCC read beside the maps
    Test-SoundBanks $report $Folder
    Test-BlfFiles $report $Folder
    Test-Layouts $report $Folder
    $customization = Join-Path $Folder 'customization.json'
    if (Test-Path -LiteralPath $customization) {
        $read = Read-Json $customization
        if (-not $read.Ok) {
            Add-Finding $report 'PROBLEM' 'customization-unreadable' "customization.json can't be read: $($read.Problem)" `
                "customization.json is what makes this a character mod for Project Reclaimer: its characters' bodies, armor and colors. One it can't read leaves the characters out (`"Customization mod ... left out`"), and players see Halo 3's own characters instead." `
                'Fix the JSON, or open the mod in the customization editor that comes with Project Reclaimer and save it again.' $PR
        } else { $report.Facts.Add('Character mod (customization.json)') }
    }
    Test-WorkshopReceipt $report $Folder
    Test-FolderHygiene $report $Folder
    return $report
}

function Test-AppVersions($Report, $Data, $Versions) {
    $min = Get-Prop $Data 'MinAppVersion'
    $max = Get-Prop $Data 'MaxAppVersion'
    if (-not $min -or -not $max) {
        $missing = @(@('MinAppVersion', 'MaxAppVersion') | Where-Object { -not (Get-Prop $Data $_) }) -join ' and '
        Add-Finding $Report 'WARNING' 'no-app-version' "ModInfo.json has no $missing" `
            "MinAppVersion and MaxAppVersion are the MCC versions the mod says it works with; MCC checks its own version against them before it loads the mod (`"Mod does not support this version of the game`"). Excession writes both." `
            'Set Min. and Max. Game Version in Excession ("SET TO LATEST" fills in the current ones).' $MCC
        return
    }
    $minVersion = Read-AppVersion $min.Value
    $maxVersion = Read-AppVersion $max.Value
    foreach ($pair in @(@('MinAppVersion', $minVersion), @('MaxAppVersion', $maxVersion))) {
        if ($pair[1] -isnot [version]) {
            Add-Finding $Report 'PROBLEM' 'bad-app-version' "$($pair[0]) can't be read: $($pair[1])" `
                "MCC compares its own version with MinAppVersion and MaxAppVersion before loading the mod. One it can't read means it can't tell the mod works with it." `
                'Set the game versions in Excession.' $MCC
        }
    }
    if ($minVersion -isnot [version] -or $maxVersion -isnot [version]) { return }
    $zero = [version]'0.0.0'
    if ($maxVersion -eq $zero) {
        # 0.0.0 sets no bound: many published mods that load on today's MCC have 0.0.0 for both
        $Report.Facts.Add($(if ($minVersion -eq $zero) { 'Works with any MCC version (0.0.0: no limit set)' } else { "Works with MCC $minVersion and later (no maximum set)" }))
        Add-Finding $Report 'NOTE' 'app-version-unset' 'MaxAppVersion is 0.0.0 (no limit)' `
            'With 0.0.0 the mod doesn''t say which MCC versions it was made for; published mods that do this load on any version. Setting real ones lets MCC tell players when an MCC update breaks the mod, instead of loading it anyway.' `
            'Optional: in Excession, "SET TO LATEST" for Min. and Max. Game Version.' $MCC
        return
    }
    $Report.Facts.Add("Works with MCC $minVersion to $maxVersion")
    if ($minVersion -gt $maxVersion) {
        Add-Finding $Report 'PROBLEM' 'app-version-backwards' "MinAppVersion ($minVersion) is after MaxAppVersion ($maxVersion)" `
            "No MCC version is both at least $minVersion and at most $maxVersion, so MCC never loads the mod." `
            'Swap them, or set both in Excession ("SET TO LATEST").' $MCC
        return
    }
    $mcc = $Versions.Mcc
    if ($mcc) {
        $mcc3 = [version]("{0}.{1}.{2}" -f $mcc.Major, $mcc.Minor, [Math]::Max(0, $mcc.Build))
        if ($mcc3 -gt $maxVersion) {
            Add-Finding $Report 'PROBLEM' 'app-version-old' "MCC on this PC is $mcc3, past the MaxAppVersion $maxVersion the mod allows" `
                "MCC won't load a mod whose MaxAppVersion is older than the game (`"Mod does not support this version of the game`"). Everyone on the current MCC gets nothing from it." `
                'Raise Max. Game Version in Excession ("SET TO LATEST MAXIMUM GAME VERSION"), check the mod still works, and upload it again.' $MCC
        } elseif ($mcc3 -lt $minVersion) {
            Add-Finding $Report 'WARNING' 'app-version-new' "The mod needs MCC $minVersion or later; this PC has $mcc3" `
                "MCC skips a mod made for a newer version of the game than it is. Players who haven't updated MCC (or a server on an older copy of its files) get nothing from it." `
                'Update MCC; or lower Min. Game Version in Excession if the mod works on older versions.' $MCC
        }
    }
    if ($Versions.ExcessionMax -and $Versions.ExcessionMax -gt [version]("{0}.{1}.{2}.0" -f $maxVersion.Major, $maxVersion.Minor, $maxVersion.Build) -and -not ($mcc -and [version]("{0}.{1}.{2}" -f $mcc.Major, $mcc.Minor, [Math]::Max(0, $mcc.Build)) -gt $maxVersion)) {
        Add-Finding $Report 'WARNING' 'app-version-behind' "MaxAppVersion is $maxVersion; Excession now offers $($Versions.ExcessionMax)" `
            "Excession's newest maximum game version is past the mod's: when MCC updates to it, the mod stops loading until it is uploaded again." `
            'Set Max. Game Version to the latest in Excession before uploading.' $MCC
    }
}

function Test-Description($Report, [string]$Folder, [string]$Relative, [string]$Kind, $Referenced, $Maps) {
    # One map description (multiplayer\, firefight\ or a campaign mission): readable, named, matched to its .map
    $file = Join-Path $Folder ($Relative -replace '/', '\')
    $listName = @{ multiplayer = 'MultiplayerMaps'; firefight = 'FirefightMaps'; campaign = 'CampaignInfo.json''s CampaignMaps' }[$Kind]
    if (-not (Test-Path -LiteralPath $file)) {
        Add-Finding $Report 'PROBLEM' 'description-missing' "$listName lists $Relative, which isn't in the mod" `
            "Each entry is a map description MCC reads to list the map; a missing one means that map is never listed (MCC: `"Could not resolve`"; Project Reclaimer skips it without a word, so it's easy to miss)." `
            "Add the file, or remove the entry (Excession: remove the map and save)." $BOTH
        return
    }
    $read = Read-Json $file
    if (-not $read.Ok) {
        Add-Finding $Report 'PROBLEM' 'description-unreadable' "The map description $Relative can't be read: $($read.Problem)" `
            "MCC and Project Reclaimer read this file to list the map and find its .map (MCC: `"Failed to parse JSON file`"). One they can't read means the map isn't there." `
            'Fix the JSON where the message points, or edit the map in Excession and save it again.' $BOTH
        return
    }
    $map = $read.Value
    foreach ($name in @('MapGuid', 'ScenarioFile', 'Title', 'Description', 'Images', 'Flags', 'InsertionPoints', 'MaximumTeamsByGameCategory',
                        'MapDefaultPrimaryWeapon', 'MapDefaultPrimaryWeaponForge', 'CampaignMapKind', 'CampaignMetagame')) {
        $other = Get-PropOtherCase $map $name
        if ($other -and -not (Get-Prop $map $name)) {
            Add-Finding $Report 'PROBLEM' 'description-field-case' "$Relative writes `"$other`" where MCC reads `"$name`"" `
                "MCC reads a map description's field names exactly, capitals included; `"$other`" is a different name to it, so the setting is missing." `
                "Rename it to `"$name`" (or edit the map in Excession and save)." $MCC
        }
    }
    $mapGuid = [string](Get-Prop $map 'MapGuid').Value
    if (-not $mapGuid) {
        Add-Finding $Report 'PROBLEM' 'no-mapguid' "$Relative has no MapGuid" `
            "MCC and Project Reclaimer tell maps apart by their MapGuid (a mod's maps have no other ID): map variants, saved films and Forge layouts made on the map name it. Without one the map can't be told apart from others." `
            'Excession writes one when you add the map; or write a fresh GUID.' $BOTH
    } elseif (-not (Test-Guid $mapGuid)) {
        Add-Finding $Report 'PROBLEM' 'bad-mapguid' "$Relative's MapGuid `"$mapGuid`" isn't a valid GUID" `
            'A MapGuid is written like 6bd5cdf7-e40d-41d4-a464-57a1c1b3a256, never all zeros. One that can''t be read is as good as none: the map can''t be told apart from others.' `
            'Give the map a fresh GUID (Excession does when you add it again).' $BOTH
    } else { $Report.MapGuids.Add(@{ Guid = $mapGuid.ToLowerInvariant(); Description = $Relative }) }
    $title = Get-Text (Get-Prop $map 'Title').Value
    if (-not $title) {
        Add-Finding $Report 'WARNING' 'map-no-title' "$Relative has no title" `
            'The title is the map''s name in MCC''s lists, in game lobbies and in Project Reclaimer''s lists. Without one it shows blank (or as its file name).' `
            'Set the map name in Excession.' $BOTH
    } elseif ($title.Length -ge 32) {
        Add-Finding $Report 'NOTE' 'map-title-long' "$Relative's title is $($title.Length) characters" `
            'Excession has crashed exporting the map info of a map whose title is 32 characters or more (its changelog). Long titles are also cut short in game lobbies.' `
            'Keep map titles to 31 characters or fewer.' $MCC
    }

    # The .map it describes: the last part of ScenarioFile, as maps\<that>.map
    $scenarioField = Get-Prop $map 'ScenarioFile'
    $scenario = if ($scenarioField) { ([string]$scenarioField.Value).Trim() } else { '' }
    if (-not $scenario) {
        Add-Finding $Report 'PROBLEM' 'no-scenariofile' "$Relative has no ScenarioFile" `
            "ScenarioFile is how a description finds its .map: the tag path of the scenario it was built from (levels/multi/<name>/<name>), whose last part is the map's file name. Without it no map is found, so this one isn't played." `
            'Set the Scenario File in Excession (e.g. levels/multi/guardian/guardian for maps\guardian.map).' $BOTH
        return
    }
    $stem = ($scenario -split '[\\/]')[-1]
    $Referenced[$stem.ToLowerInvariant()] = @{ Description = $Relative; Kind = $Kind }
    $match = $Maps | Where-Object { $_.BaseName -ieq $stem } | Select-Object -First 1
    if (-not $match) {
        $hint = ''
        $loose = @($Maps | Where-Object { -not $Referenced.ContainsKey($_.BaseName.ToLowerInvariant()) })
        if ($loose.Count -eq 1) { $hint = " The mod has $($loose[0].Name), which no description names: if that's this map, the file was renamed after the description was written." }
        Add-Finding $Report 'PROBLEM' 'description-no-map' "$Relative describes $stem.map, which isn't in the mod" `
            ("Its ScenarioFile, `"$scenario`", ends in `"$stem`", so the map file it needs is maps\$stem.map. It isn't there, so MCC drops the map (`"Could not resolve Multiplayer Cache File`"; Excession doesn't check this) and Project Reclaimer never lists it." + $hint) `
            "Put $stem.map in maps\, or set ScenarioFile so its last part is the map file's real name. Renaming a built map isn't supported by the tools: build it under the name you want." `
            $BOTH
    }

    # Images
    $images = (Get-Prop $map 'Images').Value
    if ($images) {
        foreach ($imageKind in @('Thumbnail', 'Large', 'LoadingScreen', 'TopDown')) {
            $value = [string](Get-Prop $images $imageKind).Value
            if (-not $value) {
                if ($imageKind -in @('Thumbnail', 'Large', 'LoadingScreen')) {
                    Add-Finding $Report 'NOTE' 'image-none' "$Relative has no $imageKind image" `
                        "MCC shows a blank where the map's $imageKind image goes. It works without one." `
                        "Add one in Excession (a PNG; Excession's templates: thumbnail 316 x 160, large 668 x 292, loading screen 1920 x 1080)." $MCC
                }
                continue
            }
            Test-MapImage $Report $Folder $Relative $imageKind $value
        }
    }

    # Settings MCC reads (Halo 3 and ODST values; other games have their own lists)
    foreach ($flagValue in @((Get-Prop $map 'Flags').Value)) {
        if ($null -ne $flagValue -and $MapFlags -notcontains [string]$flagValue) {
            Add-Finding $Report 'PROBLEM' 'bad-map-flag' "$Relative has the flag `"$flagValue`", which MCC doesn't know" `
                ("A map's Flags can only be $($MapFlags -join ', ') (MCC reads each into a fixed list). A description with another value in it can't be read as written, so the map may be dropped.") `
                'Remove it, or set the flags in Excession.' $MCC
        }
    }
    $teams = (Get-Prop $map 'MaximumTeamsByGameCategory').Value
    if ($Kind -eq 'multiplayer' -and $teams -and $teams -is [psobject] -and $Report.Engine -in @('', 'Halo3', 'Halo3ODST')) {
        foreach ($property in $teams.PSObject.Properties) {
            if ($property.Value -is [int] -and $property.Value -eq 0) {
                Add-Finding $Report 'PROBLEM' 'team-count-zero' "$Relative allows 0 teams in $($property.Name)" `
                    "A known MCC issue: a game whose Max Team Category is 0 `"can load into a black screen and immediately announce game over`"." `
                    'Set it to the number of teams the map supports (1 or more), or remove it.' $MCC
            } elseif ($property.Name -eq 'All') {
                Add-Finding $Report 'NOTE' 'team-category-all' "$Relative sets teams for `"All`"" `
                    ("`"All`" isn't one of Halo 3's game categories ($(@($MaxTeams.Keys) -join ', ')); it looks like Excession's Max Teams All Up field, and published maps use it, but how MCC reads it isn't documented (and per MCC's known issues, team counts aren't always respected in game).") `
                    'If teams matter, set them per category in Excession.' $MCC
            } elseif (-not $MaxTeams.Contains($property.Name)) {
                Add-Finding $Report 'WARNING' 'bad-team-category' "$Relative sets teams for `"$($property.Name)`", which isn't a Halo 3 game category" `
                    ("Halo 3's categories are $(@($MaxTeams.Keys) -join ', '). MCC doesn't know this one, so that count does nothing.") `
                    'Remove it, or set the team counts in Excession.' $MCC
            } elseif ($property.Value -isnot [int] -or $property.Value -lt 1 -or $property.Value -gt $MaxTeams[$property.Name]) {
                Add-Finding $Report 'WARNING' 'bad-team-count' "$Relative allows $($property.Value) teams in $($property.Name); Halo 3 allows 1 to $($MaxTeams[$property.Name])" `
                    "Halo 3 can't run more teams than that in this kind of game, so lobbies won't offer the teams you meant." `
                    'Set it in Excession (Max teams by game category).' $MCC
            }
        }
    }
    foreach ($name in @('MapDefaultPrimaryWeapon', 'MapDefaultPrimaryWeaponForge')) {
        $weapon = [string](Get-Prop $map $name).Value
        if ($weapon -and $Report.Engine -in @('', 'Halo3', 'Halo3ODST') -and $Halo3Weapons -notcontains $weapon) {
            Add-Finding $Report 'WARNING' 'bad-weapon' "$Relative's $name is `"$weapon`", not a Halo 3 weapon" `
                "Players start with this weapon in games that use the map's default. A name that isn't one of Halo 3's weapons gives them the game's default instead (or nothing)." `
                'Use one of Halo 3''s (e.g. _damage_reporting_type_assault_rifle), or _damage_reporting_type_invalid for none; Excession lists them.' $MCC
        }
    }
    if ($Kind -eq 'campaign') {
        $missionKind = [string](Get-Prop $map 'CampaignMapKind').Value
        if ($missionKind -and $missionKind -notin @('Default', 'Tutorial', 'Prologue', 'Epilogue', 'SupportsFirefight')) {
            Add-Finding $Report 'WARNING' 'bad-mission-kind' "$Relative's CampaignMapKind is `"$missionKind`"" `
                'A mission is Default, Tutorial, Prologue, Epilogue or SupportsFirefight; MCC doesn''t know another kind.' 'Set it in Excession.' $MCC
        }
        $metagame = (Get-Prop $map 'CampaignMetagame').Value
        if ($metagame) {
            $par = [double](Get-Prop $metagame 'ParTimeInSeconds').Value
            $average = [double](Get-Prop $metagame 'AverageTimeInSeconds').Value
            $max = [double](Get-Prop $metagame 'MaxTimeInSeconds').Value
            if (($par -or $average -or $max) -and -not ($par -le $average -and $average -le $max)) {
                Add-Finding $Report 'PROBLEM' 'mission-times' "$Relative's scoring times are out of order (par $par s, average $average s, max $max s)" `
                    "Campaign scoring needs par time <= average time <= max time; Excession refuses others (`"MaxTimeInSeconds must be greater than or equal to AverageTimeInSeconds!`")." `
                    'Set them in order in Excession (or all to 0 for no scoring times).' $MCC
            }
        }
    }
}

function Test-Campaign($Report, [string]$Folder, [string]$File, $Referenced, $Maps) {
    $read = Read-Json $File
    if (-not $read.Ok) {
        Add-Finding $Report 'PROBLEM' 'campaign-unreadable' "CampaignInfo.json can't be read: $($read.Problem)" `
            'It lists the campaign''s missions; MCC can''t read it, so the campaign isn''t there.' 'Fix the JSON, or save the campaign again in Excession.' $MCC
        return
    }
    $campaign = $read.Value
    $guid = [string](Get-Prop $campaign 'CampaignGuid').Value
    if (-not (Test-Guid $guid)) {
        Add-Finding $Report 'PROBLEM' 'campaign-bad-guid' 'CampaignInfo.json has no valid CampaignGuid' `
            'MCC tells campaigns apart by their CampaignGuid; Excession makes one when you create the campaign.' 'Create the campaign again in Excession, or write a fresh GUID.' $MCC
    }
    if (-not (Get-Text (Get-Prop $campaign 'Title').Value)) {
        Add-Finding $Report 'WARNING' 'campaign-no-title' 'The campaign has no title' `
            'MCC''s campaign list shows a campaign by its title; without one it shows blank.' 'Set it in Excession.' $MCC
    }
    $players = (Get-Prop $campaign 'MaxCampaignPlayersOverride').Value
    if ($null -ne $players -and ($players -isnot [int] -or $players -lt 0 -or $players -gt 4)) {
        Add-Finding $Report 'WARNING' 'campaign-players' "MaxCampaignPlayersOverride is $players" `
            'It is 0 (no override) or 1 to 4 players (Excession: "Set to zero to not override. Otherwise ... between 1 and 4").' 'Set it in Excession.' $MCC
    }
    $missions = @(if ((Get-Count (Get-Prop $campaign 'CampaignMaps').Value) -gt 0) { (Get-Prop $campaign 'CampaignMaps').Value })
    if (-not $missions) {
        Add-Finding $Report 'PROBLEM' 'campaign-no-missions' 'CampaignInfo.json lists no missions' `
            'MCC ignores a campaign with no missions ("Campaign info is being ignored, no maps are defined").' 'Add the missions in Excession.' $MCC
    }
    foreach ($mission in $missions) { Test-Description $Report $Folder ([string]$mission) 'campaign' $Referenced $Maps }
}

function Test-MapImage($Report, [string]$Folder, [string]$Relative, [string]$Kind, [string]$Value) {
    $file = Join-Path $Folder ($Value -replace '/', '\')
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $elsewhere = Get-ChildItem -LiteralPath $Folder -Recurse -File -Filter (Split-Path $file -Leaf) -ErrorAction SilentlyContinue | Select-Object -First 1
        $hint = if ($elsewhere) { " There is a file of that name at $(Get-RelativePath $Folder $elsewhere.FullName): the description still points at its old place." } else { '' }
        Add-Finding $Report 'WARNING' 'image-missing' "$Relative's $Kind image `"$Value`" isn't in the mod" `
            ("MCC shows the map's $Kind image from this file. It isn't there (moved, renamed, or never added), so players see a blank where it goes." + $hint) `
            'Put the image where the description says, or choose it again in Excession.' $MCC
        return
    }
    if ((Split-Path $file -Parent).TrimEnd('\') -ieq $Folder.TrimEnd('\')) {
        Add-Finding $Report 'NOTE' 'image-in-root' "$Relative's $Kind image is in the mod's own folder" `
            "Excession wants a map's images in a subfolder of the mod (`"Image should be placed in subfolder of mod root folder`"), usually images\, and won't take this one if you choose it there again." `
            'Move it to images\ and choose it again in Excession.' $MCC
    }
    $image = Get-ImageInfo $file
    $size = (Get-Item -LiteralPath $file).Length
    if ($image.Format -ne 'png') {
        $what = if ($image.Format -eq 'jpg') { 'a JPEG' } else { 'not an image MCC reads' }
        Add-Finding $Report 'WARNING' 'image-not-png' "$Relative's $Kind image $Value is $what, not a PNG" `
            "MCC's mod docs: map images `"must be stored in the PNG (.png) format`" (the file's contents count, not its name). Another format can show blank in MCC's menus." `
            'Save it as a real PNG (not just renamed) and choose it again.' $MCC
    }
    $limit = if ($Kind -eq 'LoadingScreen') { $LoadingImageLimitKiB } else { $ImageLimitKiB }
    if ($size -gt $limit * 1KB) {
        Add-Finding $Report 'NOTE' 'image-too-big' ("$Relative's $Kind image is {0:N0} KB; Excession recommends at most {1:N0} KB" -f ($size / 1KB), $limit) `
            "It works, but big images are slower to load in MCC's menus and add to every player's download; Excession recommends at most $limit KB for this kind." `
            'Shrink it (a smaller size, or a better-compressed PNG).' $MCC
    }
    if ($size -gt $PrImageLimit) {
        Add-Finding $Report 'WARNING' 'image-pr-limit' "$Relative's $Kind image is $(Format-Size $size), over the 8 MB Project Reclaimer shares" `
            'Project Reclaimer leaves out of a mod what players can''t download from the server: a file over its limit means the whole mod can''t be shared from the server.' `
            'Shrink the image.' $PR
    }
    $template = @{ Thumbnail = @(316, 160); Large = @(668, 292) }[$Kind]
    if ($template -and $image.Width -gt 0 -and ($image.Width -ne $template[0] -or $image.Height -ne $template[1])) {
        Add-Finding $Report 'NOTE' 'image-size' "$Relative's $Kind image is $($image.Width) x $($image.Height); Excession's template is $($template[0]) x $($template[1])" `
            "MCC's menus show the $Kind image at the template's size; another size is scaled to fit, so it may look stretched or blurry." `
            "Make it $($template[0]) x $($template[1]) (the templates are in Excession's documentation)." $MCC
    }
}

function Test-ModMap($Report, [string]$File, [string]$Kind) {
    # A .map file: the checks MCC's Halo 3 and Project Reclaimer make before using it. $Kind: what describes it
    # (multiplayer, firefight, campaign; '' for none)
    $item = Get-Item -LiteralPath $File
    $entry = @{ Stem = $item.BaseName; File = $File; MapId = $null; Described = [bool]$Kind; Kind = $Kind; Size = $item.Length }
    $Report.Maps.Add($entry)
    if ($Report.Engine -and $DeepMapEngines -notcontains $Report.Engine) { return }
    $map = Test-MapFile $File
    if ($map.Reason) {
        $why = switch ($map.Reason) {
            $MapCut { "The file ends before all of it is there. MCC can't load it, and Project Reclaimer skips it (`"$MapCut`")." }
            $MapIndex { "The map's tag index (the table of everything in the map) points outside the map's data. MCC can't load it, and Project Reclaimer skips it (`"$MapIndex`"). This happened to a real Workshop upload; the author's next upload fixed it." }
            $MapNotHalo { "It isn't a map MCC's Halo 3 reads (MCC checks a map's header: `"is an old version`", `"is not built for this specific halo engine`"). Project Reclaimer skips it (`"$MapNotHalo`")." }
            $MapNoScenario { "The map has no scenario, the tag that is the level itself. There's nothing to play, and Project Reclaimer skips it (`"$MapNoScenario`")." }
            default { 'The file can''t be read.' }
        }
        $fix = if ($map.Reason -eq $MapCut) { 'Build or copy the map again and check the copy finishes (compare its size with the one the tools made).' } else { 'Rebuild the map with the current mod tools (MCC needs Halo 3 maps rebuilt after some MCC updates), then check it again. If another tool edited the map after the build, that edit is the likely cause.' }
        Add-Finding $Report 'PROBLEM' 'map-damaged' "$($item.Name) is damaged: $($map.Detail)" $why $fix $BOTH
        return
    }
    $entry.MapId = $map.MapId
    $Report.Facts.Add(("{0}: {1}, {2:N0} tags, map ID {3}, built {4}" -f $item.Name, (Format-Size $item.Length), $map.Tags, $map.MapId, $map.Build))
    $scenarioStem = ($map.Scenario -split '[\\/]')[-1]
    if (($scenarioStem -and $scenarioStem -ine $item.BaseName) -or ($map.Title -and $map.Title -ine $item.BaseName)) {
        Add-Finding $Report 'WARNING' 'map-renamed' "$($item.Name) has other names inside it" `
            ("The mod tools give a map one name in three places: its file name, the name in its header and its scenario's name (guardian.map holds `"guardian`" and levels\multi\guardian\guardian). " +
             "This one is file `"$($item.BaseName)`", header `"$($map.Title)`", scenario `"$($map.Scenario)`": it was renamed, or its header edited, after the build. " +
             "Renaming a built map isn't supported by the tools, and Halo 3 checks a map's header when it loads it (`"had a corrupt name`"), so a renamed map may be refused or misbehave. It plays on Project Reclaimer as long as its description names the file.") `
            'Build the map under the name you want (name the scenario that), and leave the built file as it is.' $MCC
    }
    if ($Kind -in @('multiplayer', 'firefight') -and $null -ne $map.MapType -and $map.MapType -ne 1 -and $Report.Engine -in @('', 'Halo3')) {
        $type = switch ($map.MapType) { 0 { 'a campaign' } 2 { 'a main menu' } default { "a type $($map.MapType)" } }
        Add-Finding $Report 'PROBLEM' 'map-not-multiplayer' "$($item.Name) holds $type scenario, but is listed as a $Kind map" `
            "Multiplayer maps must be built from a multiplayer scenario; this one can't be played in multiplayer games." `
            'Set the scenario''s type to multiplayer in the mod tools and rebuild, or list it as a campaign mission instead.' $BOTH
    }
    if ($map.MapId -eq 0 -and $Kind -eq 'multiplayer') {
        Add-Finding $Report 'NOTE' 'map-no-id' "$($item.Name) declares no map ID" `
            'MCC knows a mod''s map by its MapGuid, so this is fine there. Project Reclaimer makes an ID from the file name (the same on every PC; players need Project Reclaimer 0.8.12 or later).' `
            '' $PR
    }
    $stockName = $StockMapIds.Keys | Where-Object { $StockMapIds[$_] -eq $map.MapId } | Select-Object -First 1
    if ($Kind -eq 'multiplayer' -and $map.MapId -and $stockName -and $stockName -ine $item.BaseName) {
        Add-Finding $Report 'WARNING' 'map-id-stock' "$($item.Name) uses map ID $($map.MapId), which is Halo 3's $stockName" `
            "Map variants, saved films and game types made on a map name its map ID. Sharing a Halo 3 map's ID means things made on one can be taken as made on the other (Project Reclaimer plays such maps, but variants can open on the wrong one). That's only right for a mod that means to replace that Halo 3 map." `
            'Give the scenario its own map ID in the mod tools (one no Halo 3 map uses).' $BOTH
    }
    if ($item.Length -gt $PrMapLimit) {
        Add-Finding $Report 'WARNING' 'map-too-big' "$($item.Name) is $(Format-Size $item.Length), over the 4 GB Project Reclaimer shares" `
            'Project Reclaimer servers can''t send a map over 4 GB to players, so players without the mod can''t join games on it.' `
            'Make the map smaller (smaller bitmaps and sounds).' $PR
    }
}

function Test-SoundBanks($Report, [string]$Folder) {
    $banks = @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter '*.fsb' -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.fsb')
    foreach ($bank in $banks) {
        $head = Get-Head $bank.FullName 4
        if ($null -eq $head -or [Text.Encoding]::ASCII.GetString($head) -notmatch '^FSB[45]') {
            Add-Finding $Report 'PROBLEM' 'soundbank-damaged' "$(Get-RelativePath $Folder $bank.FullName) isn't an FMOD sound bank" `
                "Halo 3 plays a mod's sounds from FMOD banks (they start with FSB5). This file doesn't, so its sounds are silent or the game errors on them." `
                'Export the bank again from FMOD (or the mod tools) and replace it.' $BOTH
        }
        if (-not (Test-Path -LiteralPath "$($bank.FullName).info")) {
            Add-Finding $Report 'WARNING' 'soundbank-no-info' "$(Get-RelativePath $Folder $bank.FullName) has no .fsb.info beside it" `
                "Halo 3's banks come in pairs: the .fsb with its sounds and an .fsb.info that indexes them. Without the .info, the game can't find the sounds in the bank." `
                "Add $($bank.Name).info from the same export." $MCC
        }
        if ($bank.Length -gt $PrMediaLimit) {
            Add-Finding $Report 'WARNING' 'soundbank-too-big' "$(Get-RelativePath $Folder $bank.FullName) is $(Format-Size $bank.Length), over the 2 GB Project Reclaimer shares" `
                'Project Reclaimer servers can''t send it to players, so the whole mod can''t be downloaded from the server.' 'Split or shrink the bank.' $PR
        }
    }
    foreach ($info in @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter '*.fsb.info' -File -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path -LiteralPath ($info.FullName -replace '\.info$', ''))) {
            Add-Finding $Report 'WARNING' 'soundbank-info-alone' "$(Get-RelativePath $Folder $info.FullName) has no .fsb beside it" `
                'An .fsb.info indexes the sounds of the .fsb of the same name. On its own it does nothing (or points the game at sounds that aren''t there).' `
                'Add its .fsb, or delete it.' $MCC
        }
    }
    foreach ($video in @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter '*.bk2' -File -ErrorAction SilentlyContinue)) {
        $head = Get-Head $video.FullName 3
        $magic = if ($null -eq $head) { '' } else { [Text.Encoding]::ASCII.GetString($head) }
        if ($magic -eq 'BIK') {
            Add-Finding $Report 'WARNING' 'video-bink1' "$(Get-RelativePath $Folder $video.FullName) is a Bink 1 video named .bk2" `
                'A .bk2 file is expected to be Bink 2 (starting with KB2); this one is Bink 1 (BIK). Where the game plays it with Bink 2, as MCC''s menu videos are, it won''t play.' `
                'Export it as Bink 2, or name it .bik if it''s meant to be a Bink 1 video.' $MCC
        } elseif ($magic -ne 'KB2') {
            Add-Finding $Report 'PROBLEM' 'video-damaged' "$(Get-RelativePath $Folder $video.FullName) isn't a Bink video" `
                'MCC plays .bk2 files with Bink 2 (they start with KB2). This one is neither Bink 2 nor Bink 1, so it can''t be played.' `
                'Export it again as Bink 2 (.bk2).' $MCC
        }
        if ($video.Length -gt $PrMediaLimit) {
            Add-Finding $Report 'WARNING' 'video-too-big' "$(Get-RelativePath $Folder $video.FullName) is $(Format-Size $video.Length), over the 2 GB Project Reclaimer shares" `
                'Project Reclaimer servers can''t send it to players.' 'Shrink it.' $PR
        }
    }
}

function Test-BlfFiles($Report, [string]$Folder) {
    # .mapinfo files, and map and game variants: Halo's BLF files, which start with "_blf"
    $files = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in @('.mapinfo', '.mvar', '.campaign') -or ($_.Extension -eq '.bin' -and $_.DirectoryName -match 'variant')
    })
    foreach ($file in $files) {
        $head = Get-Head $file.FullName 4
        if ($null -eq $head -or [Text.Encoding]::ASCII.GetString($head) -cne '_blf') {
            $what = if ($file.Extension -eq '.mapinfo') { 'map info' } elseif ($file.Extension -eq '.campaign') { 'campaign info' } else { 'variant' }
            Add-Finding $Report 'PROBLEM' 'blf-damaged' "$(Get-RelativePath $Folder $file.FullName) isn't a Halo $what file" `
                ("Halo's $what files are BLF files, starting with `"_blf`". This one doesn't, so the game skips it (Project Reclaimer: `"Expected an MCC BLF variant file`").") `
                ('Export it again from the game or the tools.' + $(if ($file.Extension -eq '.mapinfo') { ' Excession: Convert Existing .mapinfo, or Export Map Info BLF.' } else { '' })) `
                $BOTH
        }
    }
}

function Test-Layouts($Report, [string]$Folder) {
    $layouts = Join-Path $Folder 'Project Reclaimer Layouts'
    if (-not (Test-Path -LiteralPath $layouts)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $layouts -Filter '*.json' -File)) {
        $read = Read-Json $file.FullName
        if (-not $read.Ok) {
            Add-Finding $Report 'WARNING' 'layout-unreadable' "The Forge layout $($file.Name) can't be read: $($read.Problem)" `
                'Project Reclaimer hosts install a mod''s Forge layouts from this folder into their Maps; one it can''t read isn''t installed.' `
                'Save the layout again from Project Reclaimer''s Forge.' $PR
            continue
        }
        $name = [string](Get-Prop $read.Value 'name').Value
        if (-not $name) { $name = $file.BaseName }
        $base = (Get-Prop $read.Value 'base_map').Value
        $Report.Layouts.Add(@{ Name = $name; Stem = [string](Get-Prop $base 'stem').Value; MapId = (Get-Prop $base 'id').Value; Guid = [string](Get-Prop $base 'guid').Value; File = $file.Name })
    }
}

function Test-WorkshopReceipt($Report, [string]$Folder) {
    # A copy installed by a Project Reclaimer server: its list of the item's files, with their sizes
    $receipt = Join-Path $Folder 'reclaimer-installed.json'
    if (-not (Test-Path -LiteralPath $receipt)) { return }
    $read = Read-Json $receipt
    $files = (Get-Prop $read.Value 'files').Value
    if (-not $read.Ok -or $null -eq $files) { return }
    $gone = @()
    foreach ($entry in @($files)) {
        if (@($entry).Count -ne 2) { continue }
        $file = Join-Path $Folder (([string]$entry[0]) -replace '/', '\')
        if (-not (Test-Path -LiteralPath $file)) { $gone += "$($entry[0]) (missing)" }
        elseif ((Get-Item -LiteralPath $file).Length -ne [long]$entry[1]) { $gone += "$($entry[0]) (another size)" }
    }
    if ($gone) {
        Add-Finding $Report 'PROBLEM' 'workshop-incomplete' "This installed copy is incomplete: $($gone.Count) of $(@($files).Count) files are missing or changed" `
            ("A Project Reclaimer server installed this Workshop item and wrote down every file and its size. These differ now: " + (($gone | Select-Object -First 5) -join ', ') + $(if ($gone.Count -gt 5) { ', ...' } else { '' }) + ". The server won't use the item like this (`"Workshop installation ... is incomplete`").") `
            'On the server: remove the item''s folder and fetch it again (Huragok: G, the server, 3, then I).' $PR
    }
}

function Test-FolderHygiene($Report, [string]$Folder) {
    # Excession uploads every file in the mod folder, so anything that isn't the mod goes to every player
    $all = @(Get-ChildItem -LiteralPath $Folder -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        Add-Member -InputObject $_ -NotePropertyName Inside -NotePropertyValue ('\' + (Get-RelativePath $Folder $_.FullName)) -PassThru })
    $total = ($all | Measure-Object -Property Length -Sum).Sum
    $Report.Facts.Add(("{0:N0} files, {1}" -f $all.Count, (Format-Size ([double]$total))))
    $kinds = [ordered]@{
        'system files (Thumbs.db, desktop.ini, .DS_Store)' = { $_.Name -in @('Thumbs.db', 'desktop.ini', '.DS_Store') -or $_.Inside -match '\\__MACOSX\\' }
        'backups and temporary files (.bak, .old, .tmp, ~)' = { $_.Extension -in @('.bak', '.old', '.tmp', '.temp', '.orig') -or $_.Name.EndsWith('~') }
        'copies and backup folders (" - Copy", "(1)", "backup")' = { $_.Name -match ' - Copy( \(\d+\))?(\.|$)' -or $_.Name -match ' \(\d+\)\.[^.]+$' -or $_.Inside -match '(?i)\\[^\\]*backup[^\\]*\\' -or $_.BaseName -match '(?i)backup' }
        'archives (.zip, .rar, .7z)' = { $_.Extension -in @('.zip', '.rar', '.7z', '.tar', '.gz') }
        'programs and scripts (.exe, .dll, .bat, .cmd, .ps1, .py, .vbs, .js)' = { $_.Extension -in @('.exe', '.dll', '.bat', '.cmd', '.ps1', '.py', '.vbs', '.js', '.msi', '.com', '.scr') }
        'source art and models (.psd, .xcf, .tif, .blend, .max, .fbx, .obj, .jms, .ass)' = { $_.Extension -in @('.psd', '.xcf', '.tif', '.tiff', '.kra', '.blend', '.max', '.ma', '.mb', '.fbx', '.obj', '.jms', '.ass', '.jma', '.jmm', '.jmo', '.jmt', '.jmw', '.jmz', '.gr2') }
        'mod tools data (tags\, data\, .scenario and other tag files)' = { $_.Inside -match '\\(tags|data)\\' -or $_.Extension -in @('.scenario', '.scenario_structure_bsp', '.bitmap', '.shader', '.model', '.render_model', '.collision_model', '.physics_model', '.sound') }
        'logs (.log)' = { $_.Extension -eq '.log' }
        "Project Reclaimer's install receipts (reclaimer-*.json)" = { $_.Name -like 'reclaimer-*.json' }
    }
    foreach ($kind in $kinds.Keys) {
        $hits = @($all | Where-Object $kinds[$kind])
        if (-not $hits) { continue }
        $size = ($hits | Measure-Object -Property Length -Sum).Sum
        $examples = (($hits | Select-Object -First 4 | ForEach-Object { Get-RelativePath $Folder $_.FullName }) -join ', ') + $(if ($hits.Count -gt 4) { ', ...' } else { '' })
        $level = 'WARNING'
        $why = "Excession uploads everything in the mod's folder (`"*All* files in the above folder will be included on upload`"), so these go to every player who downloads the mod: $(Format-Size ([double]$size)) they don't need."
        if ($kind -like 'programs*') { $why += ' Programs and scripts in a mod also look suspicious to players and antivirus programs, and Project Reclaimer never shares them with players.' }
        if ($kind -like "Project Reclaimer's*") { $why = "These are written by a Project Reclaimer server when it installs a Workshop item: they describe that server's copy, not the mod. This folder was copied from a server; uploading it would ship the server's notes to everyone."; $level = 'WARNING' }
        Add-Finding $Report $level 'unneeded-files' ("{0} {1}: {2}" -f $hits.Count, $kind, $examples) $why `
            'Move them out of the mod folder before uploading (keep them somewhere else).' $UPLOAD
    }
    $spaced = @($all | Where-Object { $_.BaseName -ne $_.BaseName.TrimEnd() -or $_.Name -ne $_.Name.Trim() })
    if ($spaced) {
        Add-Finding $Report 'WARNING' 'name-spaces' "$($spaced.Count) file name(s) with a space before the extension or at an end: $((($spaced | Select-Object -First 3) | ForEach-Object { '"' + (Get-RelativePath $Folder $_.FullName) + '"' }) -join ', ')" `
            'A space at the end of a name, or before its extension ("utapau .json"), is easy to miss when the file is named elsewhere (in ModInfo.json, a description, a list), and Windows tools trim it in some places and not others, so the file isn''t found.' `
            'Rename it without the space (and fix whatever names it).' $BOTH
    }
    if ($Report.Kind -eq 'mod') {
        $mapinfos = @($all | Where-Object { $_.Extension -eq '.mapinfo' -or $_.Extension -match '^\.\w+_mapinfo$' })
        if ($mapinfos) {
            Add-Finding $Report 'NOTE' 'mapinfo-leftover' "$($mapinfos.Count) .mapinfo file(s): $((($mapinfos | Select-Object -First 3) | ForEach-Object { Get-RelativePath $Folder $_.FullName }) -join ', ')" `
                'A mod package doesn''t need .mapinfo files: MCC and Project Reclaimer read the map descriptions ModInfo.json lists. Excession exports them for the editing kit''s own main menu (maps\info), so ones elsewhere are usually leftovers that every player downloads.' `
                'Leave them out of the mod folder unless you know a tool needs them there.' $UPLOAD
        }
    }
    $cloud = @($all | Where-Object { $_.Inside.Length - 1 -gt $PathLimit })
    if ($cloud) {
        Add-Finding $Report 'WARNING' 'upload-path-too-long' "$($cloud.Count) file path(s) inside the mod are longer than $PathLimit characters" `
            ("Steam Cloud, where Workshop uploads go, takes paths of up to 260 characters; a longer one fails the upload. First: " + $cloud[0].Inside.TrimStart('\')) `
            'Use shorter folder and file names inside the mod.' $UPLOAD
    }
    $long = @($all | Where-Object { $_.FullName.Length -gt $PathLimit })
    if ($long) {
        Add-Finding $Report 'WARNING' 'path-too-long' "$($long.Count) file path(s) are longer than Windows' $PathLimit characters" `
            ("Many programs, MCC's file loading among them, can't open a path that long, so those files may be skipped on PCs where the mod is installed deeper. First: " + $long[0].FullName) `
            'Use shorter folder and file names inside the mod.' $BOTH
    }
    $empty = @(Get-ChildItem -LiteralPath $Folder -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) })
    if ($empty) {
        Add-Finding $Report 'NOTE' 'empty-folders' "$($empty.Count) empty folder(s): $((($empty | Select-Object -First 3) | ForEach-Object { Get-RelativePath $Folder $_.FullName }) -join ', ')" `
            'Empty folders do nothing in the mod.' 'Delete them.' $UPLOAD
    }
    if ($Report.Kind -eq 'mod') {
        $described = @($Report.Maps | Where-Object { $_.Kind -in @('multiplayer', 'loose') })
        if ($described.Count -gt $PrPerMod.Maps) {
            Add-Finding $Report 'WARNING' 'pr-too-many-maps' "The mod has $($described.Count) maps; Project Reclaimer shares mods of up to $($PrPerMod.Maps)" `
                'A Project Reclaimer server can only send players a mod of up to 8 maps and 512 files; players without this mod can''t download it from the server (they need it from the Workshop).' `
                'Split it into smaller mods if it''s meant for Project Reclaimer servers.' $PR
        }
        if ($all.Count -gt $PrPerMod.Files) {
            Add-Finding $Report 'WARNING' 'pr-too-many-files' "The mod has $($all.Count) files; Project Reclaimer shares mods of up to $($PrPerMod.Files)" `
                'A Project Reclaimer server can only send players a mod of up to 512 files.' 'Remove what the mod doesn''t need, or split it.' $PR
        }
    }
}

# ------------------------------------------------------------------------------------------------
# Across mods
# ------------------------------------------------------------------------------------------------

function Test-AcrossMods($Reports) {
    $byGuid = @{}
    foreach ($report in $Reports) { if ($report.ModGuid) { $byGuid[$report.ModGuid] = @($byGuid[$report.ModGuid]) + $report } }
    foreach ($guid in $byGuid.Keys) {
        $owners = @($byGuid[$guid] | Where-Object { $_ })
        if ($owners.Count -lt 2) { continue }
        foreach ($report in $owners) {
            $others = ($owners | Where-Object { $_ -ne $report } | ForEach-Object { "$($_.Name) ($($_.Folder))" }) -join '; '
            Add-Finding $report 'PROBLEM' 'duplicate-modguid' "Another mod here has the same ModGuid: $others" `
                "MCC tells mods apart by their ModGuid, and loads only one of two that share it (`"ModGuid is already claimed by an installed mod, ignoring ...`"). This happens when a mod folder is copied to start a new mod: the copy keeps the old GUID." `
                'Give the newer mod a fresh GUID (Excession: create the mod anew, or write a new ModGuid).' $MCC
        }
    }
    $maps = @()
    foreach ($report in $Reports) { foreach ($entry in $report.MapGuids) { $maps += @{ Report = $report; Guid = $entry.Guid; Description = $entry.Description } } }
    foreach ($group in ($maps | Group-Object { $_.Guid } | Where-Object Count -gt 1)) {
        foreach ($entry in $group.Group) {
            $others = ($group.Group | Where-Object { $_ -ne $entry } | ForEach-Object { "$($_.Description) in $($_.Report.Name)" }) -join '; '
            Add-Finding $entry.Report 'PROBLEM' 'duplicate-mapguid' "$($entry.Description) has the same MapGuid as $others" `
                'MCC and Project Reclaimer tell maps apart by their MapGuid. Two maps with one GUID get mixed up: variants and films made on one open on the other, or one map hides the other.' `
                'Give one of them a fresh MapGuid (copying a map description is the usual cause).' $BOTH
        }
    }
    $ids = @()
    foreach ($report in $Reports) { foreach ($map in $report.Maps) { if ($map.MapId -and $map.Kind -in @('multiplayer', 'loose')) { $ids += @{ Report = $report; Map = $map } } } }
    foreach ($group in ($ids | Group-Object { "$($_.Report.Engine)|$($_.Map.MapId)" } | Where-Object Count -gt 1)) {
        foreach ($entry in $group.Group) {
            $others = ($group.Group | Where-Object { $_ -ne $entry } | ForEach-Object { "$($_.Map.Stem).map ($($_.Report.Name))" }) -join ', '
            Add-Finding $entry.Report 'WARNING' 'duplicate-map-id' "$($entry.Map.Stem).map has map ID $($entry.Map.MapId), as does $others" `
                "A game session can't hold two maps with one map ID: Project Reclaimer leaves one out (`"shares its engine index with another custom map`") and they can't be in one playlist; variants made on one can be taken as the other's." `
                'Give each scenario its own map ID in the mod tools.' $BOTH
        }
    }
    $stems = @()
    foreach ($report in $Reports) { foreach ($map in $report.Maps) { if ($map.Kind -in @('multiplayer', 'loose')) { $stems += @{ Report = $report; Stem = $map.Stem.ToLowerInvariant(); Key = "$($report.Engine)|$($map.Stem.ToLowerInvariant())" } } } }
    foreach ($group in ($stems | Group-Object { $_.Key } | Where-Object Count -gt 1)) {
        $owners = @()
        foreach ($entry in $group.Group) { if ($owners -notcontains $entry.Report) { $owners += $entry.Report } }
        if ($owners.Count -lt 2) { continue }
        foreach ($report in $owners) {
            $others = ($owners | Where-Object { $_ -ne $report } | ForEach-Object Name) -join ', '
            Add-Finding $report 'NOTE' 'same-map-name' "$($group.Group[0].Stem).map is also in $others" `
                ("Two mods' maps with one file name can't be in one Project Reclaimer playlist, and players who have one see `"Map name clashes with mod on this PC`" when joining a game on the other. If it's the same map in two versions, that's expected.") `
                'Give the map a distinct file name if they are different maps.' $PR
        }
    }
    # Forge layouts: their base map installed here, at the map ID they were made on
    $installed = @{}
    foreach ($report in $Reports) { foreach ($map in $report.Maps) { if ($map.Described -or $report.Kind -ne 'mod') { $installed[$map.Stem.ToLowerInvariant()] = $map } } }
    foreach ($report in $Reports) {
        foreach ($layout in $report.Layouts) {
            if (-not $layout.Stem -or $StockMapIds.ContainsKey($layout.Stem.ToLowerInvariant())) { continue }
            $map = $installed[$layout.Stem.ToLowerInvariant()]
            if (-not $map) {
                Add-Finding $report 'WARNING' 'layout-no-map' "The Forge layout `"$($layout.Name)`" is made on $($layout.Stem).map, which isn't here" `
                    'A Forge layout plays on the map it was made on. Neither this mod nor the others checked has that map (or its description), so the layout can''t be played.' `
                    'Ship the layout with the mod that has its map, or save it again on this mod''s map.' $PR
            } elseif ($layout.MapId -and $map.MapId -and [int]$layout.MapId -ne [int]$map.MapId) {
                Add-Finding $report 'WARNING' 'layout-other-version' "The Forge layout `"$($layout.Name)`" was made on another version of $($layout.Stem).map (map ID $($layout.MapId); this one is $($map.MapId))" `
                    'The map was rebuilt with a different map ID since the layout was saved, so the layout may not load on it, or its objects may sit in the wrong places.' `
                    'Load the layout on the current map in Forge and save it again.' $PR
            }
        }
    }
    foreach ($pair in $script:Dependencies) {
        $report, $needed = $pair
        if (-not ($Reports | Where-Object { $_.ModGuid -eq $needed.ToLowerInvariant() })) {
            Add-Finding $report 'NOTE' 'dependency-not-here' "The mod it builds on ($needed) isn't among the mods checked" `
                'Players need that mod installed too, or MCC ignores this one ("requires missing ModGuid"). It may simply be elsewhere; make sure the Workshop page says so.' `
                'Mention the required mod on the Workshop page (and add it as a required item there).' $MCC
        }
    }
}

# ------------------------------------------------------------------------------------------------
# The report
# ------------------------------------------------------------------------------------------------

function Show-Report($Report) {
    $problems = @($Report.Findings | Where-Object Level -eq 'PROBLEM').Count
    $warnings = @($Report.Findings | Where-Object Level -eq 'WARNING').Count
    $notes = @($Report.Findings | Where-Object Level -eq 'NOTE').Count
    Say ('=' * [Math]::Min(100, $script:Width)) DarkCyan
    $label = $Report.Name
    $about = @()
    if ($Report.Kind -ne 'mod') { $about += $Report.Kind }
    if ($Report.Engine) { $about += $Report.Engine }
    if ($Report.ModVersion) { $about += "version $($Report.ModVersion)" }
    if ($Report.WorkshopId) { $about += "Workshop $($Report.WorkshopId)" }
    Say ("$label" + $(if ($about) { "  ($($about -join ', '))" } else { '' })) White
    Say $Report.Folder DarkGray
    foreach ($fact in $Report.Facts) { Say "- $fact" DarkGray 2 4 }
    Say
    $order = @{ PROBLEM = 0; WARNING = 1; NOTE = 2 }
    # Findings of one kind are told once in full; the rest of that kind are listed under it
    $sorted = @($Report.Findings | Sort-Object { $order[$_.Level] }, Order)
    $told = @{}
    foreach ($finding in $sorted) {
        $key = "$($finding.Level)|$($finding.Code)"
        if ($told.ContainsKey($key)) { continue }
        $told[$key] = $true
        $same = @($sorted | Where-Object { $_.Level -eq $finding.Level -and $_.Code -eq $finding.Code })
        $color = switch ($finding.Level) { 'PROBLEM' { 'Red' } 'WARNING' { 'Yellow' } default { 'Cyan' } }
        Say ("[{0}] {1}" -f $finding.Level, $finding.Title) $color 2 4
        foreach ($other in ($same | Select-Object -Skip 1 -First 12)) { Say ("and: " + $other.Title) $color 6 11 }
        if ($same.Count -gt 13) { Say ("and {0} more like these" -f ($same.Count - 13)) $color 6 }
        Say ("Why: " + $finding.Why) Gray 6 11
        if ($finding.Fix) { Say ("Fix: " + $finding.Fix) Gray 6 11 }
        Say ("Affects: {0}  ({1})" -f $finding.Affects, $finding.Code) DarkGray 6
        Say
    }
    if ($problems) { Say ("NOT READY: {0} problem(s), {1} warning(s), {2} note(s)" -f $problems, $warnings, $notes) Red 2 }
    elseif ($warnings) { Say ("READY, BUT READ THE WARNINGS: {0} warning(s), {1} note(s)" -f $warnings, $notes) Yellow 2 }
    else { Say ("READY: nothing wrong found" + $(if ($notes) { " ({0} note(s))" -f $notes } else { '' })) Green 2 }
    Say
}

function Test-Folder([string]$Candidate) {
    # A folder that's there (an address with characters a path can't have is simply not one)
    try { return [bool](Test-Path -LiteralPath $Candidate -PathType Container) } catch { return $false }
}

function Get-ModsFolder {
    while ($true) {
        Say 'Which folder? Drag it into this window (or paste its address), then press Enter. Enter on its own quits.' White
        $answer = Read-Host 'Mods folder'
        $script:Log.Add("Mods folder: $answer")
        $answer = $answer.Trim().Trim('"', "'").Trim()
        if (-not $answer) { return $null }
        if (Test-Folder $answer) { return (Resolve-Path -LiteralPath $answer).ProviderPath.TrimEnd('\') }
        Say "That isn't a folder: $answer" Red
        Say
    }
}

function Save-Log([string]$Checked) {
    try {
        $logs = Join-Path $ToolFolder 'logs'
        if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs | Out-Null }
        $name = (Split-Path $Checked -Leaf) -replace '[^\w\-. ]', '_'
        $file = Join-Path $logs ("{0} {1}.txt" -f (Get-Date -Format 'yyyy-MM-dd HH-mm-ss'), $name)
        [IO.File]::WriteAllLines($file, $script:Log, (New-Object Text.UTF8Encoding $true))
        return $file
    } catch {
        Say "The log couldn't be saved: $($_.Exception.Message)" Red
        return $null
    }
}

function Wait-Close {
    if (-not $NoPause) { Write-Host; [void](Read-Host 'Press Enter to close') }
}

# ------------------------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------------------------

$script:Dependencies = @()
try { $Host.UI.RawUI.WindowTitle = "Halo Mod Health Checker $Version" } catch { }
Say "Halo Mod Health Checker $Version" Cyan
Say 'Checks a mods folder for what will stop a mod working in MCC or on a Project Reclaimer server, and what just isn''t right. It only reads: nothing is changed.' DarkGray
Say
if (-not $NoUpdateCheck) { Invoke-UpdateCheck }

if ($Path) {
    $Path = $Path.Trim().Trim('"').Trim()
    if (-not (Test-Folder $Path)) { Say "That isn't a folder: $Path" Red; Wait-Close; exit 2 }
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
} else {
    $Path = Get-ModsFolder
    if (-not $Path) { exit 0 }
}

Say
Say "Checking $Path" White
Say ("on {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) DarkGray
$versions = Get-GameVersions
if ($versions.Mcc) { Say "MCC on this PC: $($versions.Mcc)" DarkGray }
if ($versions.ExcessionMax) { Say "Excession's latest game version: $($versions.ExcessionMax)" DarkGray }
Say

$folders = Find-Mods $Path
if ($folders.Count -eq 0) {
    Say 'No mods found there: no ModInfo.json and no .map files in it or its folders.' Yellow
    Say 'Point it at a mod''s own folder (the one with ModInfo.json), or at a folder holding mod folders.' DarkGray
    $saved = Save-Log $Path
    if ($saved) { Say "Report saved: $saved" DarkGray }
    Wait-Close
    exit 1
}
Say ("{0} mod(s) found." -f $folders.Count) White
$reports = @()
foreach ($folder in $folders) {
    Write-Host ("  reading {0}..." -f (Get-RelativePath $Path $folder)) -ForegroundColor DarkGray
    $reports += Test-Mod $folder $versions
}
Test-AcrossMods $reports
Say
foreach ($report in $reports) { Show-Report $report }

$notReady = @($reports | Where-Object { $_.Findings | Where-Object Level -eq 'PROBLEM' })
$warned = @($reports | Where-Object { -not ($_.Findings | Where-Object Level -eq 'PROBLEM') -and ($_.Findings | Where-Object Level -eq 'WARNING') })
Say ('=' * [Math]::Min(100, $script:Width)) DarkCyan
Say ("{0} mod(s) checked: {1} not ready, {2} ready with warnings, {3} ready." -f $reports.Count, $notReady.Count, $warned.Count, ($reports.Count - $notReady.Count - $warned.Count)) White
$saved = Save-Log $Path
if ($saved) { Say "Report saved: $saved" DarkGray }
Wait-Close
exit $(if ($notReady.Count) { 3 } else { 0 })

<#
Tests for checkmodhealth.ps1: builds small mods with one fault each (and a sound one), runs the checker on
them the way a modder does, and checks the report names each fault with its code.

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1

The maps are tiny Halo 3 maps built here byte by byte (the layout checkmodhealth.ps1's header describes).
Runs in a temporary folder; nothing in the repository is changed.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ("modhealth-tests-" + [Guid]::NewGuid().ToString('N'))
$tool = Join-Path $work 'tool'
$mods = Join-Path $work 'Mods'
New-Item -ItemType Directory -Path $tool, $mods | Out-Null
Copy-Item (Join-Path $repo 'checkmodhealth.ps1') $tool

# ---------------------------------------------------------------- a tiny Halo 3 map
$Base = 0x1CA1A0000L
$TagsFile = 0x4000; $TagsAddress = 0x77027000L; $TagsSize = 0x1000
$DebugFile = 0x5000; $DebugAddress = 0x7CE47000L

function Put([byte[]]$Data, [int]$Offset, [byte[]]$Bytes) { [Array]::Copy($Bytes, 0, $Data, $Offset, $Bytes.Length) }
function U32([long]$Value) { return [BitConverter]::GetBytes([uint32]($Value % 4294967296)) }
function U64([long]$Value) { return [BitConverter]::GetBytes([int64]$Value) }
function I16([int]$Value) { return [BitConverter]::GetBytes([int16]$Value) }
function Ascii([string]$Text) { return [Text.Encoding]::ASCII.GetBytes($Text) }

function New-TestMap([int]$MapId = 9001, [int]$Kind = 1, [string]$Scenario = 'levels\multi\test\test', [int]$TagCount = 3, [string]$Name = '') {
    # As the tools build it: its header name is its scenario's name (and the file gets the same name)
    if (-not $Name) { $Name = ($Scenario -split '\\')[-1] }
    $data = New-Object byte[] ($DebugFile + 0x100)
    Put $data 0 (Ascii 'daeh'); Put $data 4 (U32 13); Put $data 8 (U32 $data.Length)
    Put $data 0x20 (U32 3); Put $data 0x24 (U32 ($DebugAddress + 0x10)); Put $data 0x28 (U32 0x80); Put $data 0x2C (U32 $DebugAddress)
    Put $data 0xA0 (Ascii 'Jan  3 2024 10:08:58'); Put $data 0xC0 (Ascii $Name); Put $data 0xE0 (Ascii $Scenario)
    Put $data 0x2E0 (U64 $Base); Put $data 0x2E8 (U64 ($Base + 0x200))
    Put $data 0x4CC (U32 ($DebugFile - $DebugAddress + 4294967296)); Put $data 0x4D4 (U32 ($TagsFile - $TagsAddress + 4294967296))
    Put $data 0x4DC (U32 $DebugAddress); Put $data 0x4E0 (U32 0x100)
    Put $data 0x4EC (U32 $TagsAddress); Put $data 0x4F0 (U32 $TagsSize)
    Put $data 0x3FFC (Ascii 'toof')
    $groups = @(0, 2, 1)
    for ($n = 0; $n -lt 3; $n++) {
        Put $data ($TagsFile + 8 * $n) (I16 $groups[$n]); Put $data ($TagsFile + 8 * $n + 2) (I16 0x2175)
        $pointer = if ($groups[$n] -eq 2) { ($Base + 0x300) / 4 } else { ($Base + 0x400) / 4 }
        Put $data ($TagsFile + 8 * $n + 4) (U32 $pointer)
    }
    $letters = @('gtam', 'mtib', 'rncs')
    for ($n = 0; $n -lt 3; $n++) { Put $data ($TagsFile + 0x100 + 16 * $n) (Ascii $letters[$n]) }
    Put $data ($TagsFile + 0x200) (U32 3); Put $data ($TagsFile + 0x208) (U64 ($Base + 0x100))
    Put $data ($TagsFile + 0x210) (U32 $TagCount); Put $data ($TagsFile + 0x218) (U64 $Base)
    Put $data ($TagsFile + 0x300) (I16 $Kind); Put $data ($TagsFile + 0x30C) (U32 $MapId)
    return , $data
}

$Png = [byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0,0,0,0x0D,0x49,0x48,0x44,0x52,0,0,1,0x3C,0,0,0,0xA0,8,6,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
$Jpg = [byte[]](0xFF,0xD8,0xFF,0xE0,0,0x10,0x4A,0x46,0x49,0x46,0,1,1,0,0,1,0,1,0,0,0xFF,0xC0,0,0x11,8,0,0xA0,1,0x3C,3,1,0x22,0)

function Write-Json([string]$File, $Value) {
    New-Item -ItemType Directory -Force -Path (Split-Path $File) | Out-Null
    [IO.File]::WriteAllText($File, ($Value | ConvertTo-Json -Depth 8))
}

function New-Mod([string]$Name, [hashtable]$Maps, [hashtable]$Options = @{}) {
    # A mod as Excession makes it: ModInfo.json, a description per map (ScenarioFile = the map's name), the maps,
    # a thumbnail. $Options change it: Guid, MapGuid, Scenario (per map), Listed, Info (a scriptblock editing ModInfo)
    $folder = Join-Path $mods $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $folder 'maps'), (Join-Path $folder 'images') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $folder 'images\thumb.png'), $Png)
    $listed = @()
    foreach ($stem in $Maps.Keys) {
        [IO.File]::WriteAllBytes((Join-Path $folder "maps\$stem.map"), $Maps[$stem])
        $scenario = if ($Options.Scenario -and $Options.Scenario[$stem]) { $Options.Scenario[$stem] } else { $stem }
        $mapGuid = if ($Options.MapGuid) { $Options.MapGuid } else { [Guid]::NewGuid().ToString() }
        $description = [ordered]@{
            MapGuid = $mapGuid; ScenarioFile = $scenario; Title = @{ Neutral = "$Name $stem" }; Description = @{ Neutral = 'A test map.' }
            Images = [ordered]@{ Large = 'images\thumb.png'; Thumbnail = 'images\thumb.png'; LoadingScreen = 'images\thumb.png'; TopDown = '' }
            Flags = @('DisableSavedFilms'); InsertionPoints = @()
            MaximumTeamsByGameCategory = [ordered]@{ GameCategory_CTF = 2; GameCategory_Slayer = 8 }
            MapDefaultPrimaryWeapon = '_damage_reporting_type_assault_rifle'
        }
        if ($Options.Description) { & $Options.Description $description }
        Write-Json (Join-Path $folder "multiplayer\$stem.json") $description
        $listed += "multiplayer/$stem.json"
    }
    if ($Options.ContainsKey('Listed')) { $listed = $Options.Listed }
    $info = [ordered]@{
        ModIdentifier = [ordered]@{ ModGuid = $(if ($Options.Guid) { $Options.Guid } else { [Guid]::NewGuid().ToString() }) }
        ModVersion = [ordered]@{ Major = 1; Minor = 0; Patch = 0 }
        MinAppVersion = [ordered]@{ Major = 1; Minor = 3385; Patch = 0 }
        MaxAppVersion = [ordered]@{ Major = 1; Minor = 3528; Patch = 0 }
        Engine = 'Halo3'; Title = @{ Neutral = $Name }; Description = @{ Neutral = 'A test mod.' }
        InheritSharedFiles = 'FromMCC'
        GameModContents = [ordered]@{ HasSharedFiles = $false; HasCampaign = $false; MultiplayerMaps = $listed }
    }
    if ($Options.Info) { & $Options.Info $info }
    Write-Json (Join-Path $folder 'ModInfo.json') $info
    return $folder
}

# ---------------------------------------------------------------- the mods
$guid = [Guid]::NewGuid().ToString()
$mapGuid = [Guid]::NewGuid().ToString()
New-Mod 'Sound' @{ sound = (New-TestMap 9101 -Scenario 'levels\multi\sound\sound') } | Out-Null
New-Mod 'OldCopy' @{ arena = (New-TestMap 9102 -Scenario 'levels\multi\arena\arena') } | Out-Null
[IO.File]::WriteAllBytes((Join-Path $mods 'OldCopy\maps\arena-old.map'), (New-TestMap 9102 -Scenario 'levels\multi\arena\arena'))
New-Mod 'WrongName' @{ real = (New-TestMap 9103 -Scenario 'levels\multi\real\real') } @{ Scenario = @{ real = 'levels/multi/other/other' } } | Out-Null
$bad = New-Mod 'BadJson' @{ x = (New-TestMap 9104) }
[IO.File]::WriteAllText((Join-Path $bad 'ModInfo.json'), '{ "Title": ')
New-Mod 'BadFields' @{ fields = (New-TestMap 9105 -Scenario 'levels\multi\fields\fields') } @{ Info = {
    param($i)
    $i.Remove('Engine'); $i['engine'] = 'Halo3'; $i.ModIdentifier.ModGuid = 'not-a-guid'
    $i.Remove('MinAppVersion'); $i.Remove('MaxAppVersion') } } | Out-Null
New-Mod 'WrongEngine' @{ we = (New-TestMap 9106 -Scenario 'levels\multi\we\we') } @{ Info = { param($i) $i.Engine = 'Halo5' } } | Out-Null
New-Mod 'Damaged' @{ damaged = (New-TestMap 9107 -TagCount 600) } | Out-Null
New-Mod 'Campaign' @{ echo = (New-TestMap 9108 -Kind 0 -Scenario 'levels\multi\echo\echo') } | Out-Null
New-Mod 'First' @{ twin = (New-TestMap 9200 -Scenario 'levels\multi\twin\twin') } @{ Guid = $guid; MapGuid = $mapGuid } | Out-Null
New-Mod 'Second' @{ twin = (New-TestMap 9200 -Scenario 'levels\multi\twin\twin') } @{ Guid = $guid; MapGuid = $mapGuid } | Out-Null
$junk = New-Mod 'Junk' @{ junk = (New-TestMap 9110 -Scenario 'levels\multi\junk\junk') }
foreach ($name in @('Thumbs.db', 'backup.zip', 'tool.exe', 'reclaimer-installed.json')) { [IO.File]::WriteAllText((Join-Path $junk $name), 'x') }
New-Item -ItemType Directory -Path (Join-Path $junk 'tags\levels') | Out-Null
[IO.File]::WriteAllText((Join-Path $junk 'tags\levels\junk.scenario'), 'x')
$images = New-Mod 'Images' @{ pics = (New-TestMap 9111 -Scenario 'levels\multi\pics\pics') } @{ Description = {
    param($d) $d.Images.Large = 'images\large.png'; $d.Images.LoadingScreen = 'images\photo.png'; $d.Images.TopDown = 'top.png'; $d.Images.Thumbnail = 'images\huge.png' } }
[IO.File]::WriteAllBytes((Join-Path $images 'images\photo.png'), $Jpg)
[IO.File]::WriteAllBytes((Join-Path $images 'top.png'), $Png)
$huge = New-Object byte[] (950KB); Put $huge 0 $Png
[IO.File]::WriteAllBytes((Join-Path $images 'images\huge.png'), $huge)
New-Mod 'Settings' @{ settings = (New-TestMap 9112 -Scenario 'levels\multi\settings\settings') } @{ Description = {
    param($d) $d.Flags = @('Bogus'); $d.MaximumTeamsByGameCategory.GameCategory_CTF = 4; $d.MapDefaultPrimaryWeapon = '_damage_reporting_type_bogus' } } | Out-Null
New-Mod 'Shared' @{ shared1 = (New-TestMap 9113 -Scenario 'levels\multi\shared1\shared1') } @{ Info = { param($i) $i.GameModContents.HasSharedFiles = $true } } | Out-Null
New-Mod 'Empty' @{} | Out-Null
New-Mod 'Renamed' @{ renamed = (New-TestMap 9120 -Scenario 'levels\multi\orig\orig') } | Out-Null
$unlisted = New-Mod 'Unlisted' @{ listed = (New-TestMap 9121 -Scenario 'levels\multi\listed\listed') }
Write-Json (Join-Path $unlisted 'multiplayer\utapau .json') @{ MapGuid = [Guid]::NewGuid().ToString(); ScenarioFile = 'utapau' }
New-Mod 'Teams' @{ teams = (New-TestMap 9122 -Scenario 'levels\multi\teams\teams') } @{ Description = {
    param($d) $d.MaximumTeamsByGameCategory.GameCategory_CTF = 0; $d.MaximumTeamsByGameCategory['All'] = 2 } } | Out-Null
$videos = New-Mod 'VideosOff' @{ vids = (New-TestMap 9123 -Scenario 'levels\multi\vids\vids') }
Write-Json (Join-Path $videos 'BackgroundVideosInfo.json') @{ 'intro.bk2' = @{ VideoGuid = [Guid]::NewGuid().ToString(); Title = @{ Neutral = 'x' } } }
$campaign = New-Mod 'CampaignMod' @{} @{ Info = { param($i) $i.GameModContents.HasCampaign = $true } }
[IO.File]::WriteAllBytes((Join-Path $campaign 'maps\m10.map'), (New-TestMap 9124 -Kind 0 -Scenario 'levels\solo\m10\m10'))
Write-Json (Join-Path $campaign 'CampaignInfo.json') @{ CampaignGuid = [Guid]::NewGuid().ToString(); Title = @{ Neutral = 'A Campaign' }; MaxCampaignPlayersOverride = 6; CampaignMaps = @('campaign/m10.json', 'campaign/m20.json') }
Write-Json (Join-Path $campaign 'campaign\m10.json') @{ MapGuid = [Guid]::NewGuid().ToString(); ScenarioFile = 'levels/solo/m10/m10'; Title = @{ Neutral = 'Mission 10' }; CampaignMapKind = 'Default'; CampaignMetagame = @{ ParTimeInSeconds = 600.0; AverageTimeInSeconds = 300.0; MaxTimeInSeconds = 900.0 } }
New-Mod 'LongTitle' @{ lt = (New-TestMap 9125 -Scenario 'levels\multi\lt\lt') } @{ Info = { param($i) $i.Title = @{ Neutral = ('x' * 140) } } } | Out-Null
$copies = New-Mod 'Copies' @{ cp = (New-TestMap 9126 -Scenario 'levels\multi\cp\cp') }
[IO.File]::WriteAllBytes((Join-Path $copies 'images\thumb - Copy.png'), $Png)
$rootMap = New-Mod 'RootMap' @{ rootmap = (New-TestMap 9127 -Scenario 'levels\multi\rootmap\rootmap') }
Move-Item (Join-Path $rootMap 'maps\rootmap.map') (Join-Path $rootMap 'rootmap.map')
New-Item -ItemType Directory -Path (Join-Path $mods 'Loose') | Out-Null
[IO.File]::WriteAllBytes((Join-Path $mods 'Loose\loose.map'), (New-TestMap 9114 -Scenario 'levels\multi\loose\loose'))
$sounds = New-Mod 'Sounds' @{ banks = (New-TestMap 9115 -Scenario 'levels\multi\banks\banks') }
New-Item -ItemType Directory -Path (Join-Path $sounds 'halo3\fmod\pc') | Out-Null
[IO.File]::WriteAllText((Join-Path $sounds 'halo3\fmod\pc\sfx.broken.fsb'), 'not a bank')
[IO.File]::WriteAllText((Join-Path $sounds 'halo3\fmod\pc\sfx.alone.fsb.info'), 'x')
[IO.File]::WriteAllText((Join-Path $sounds 'maps\banks.mapinfo'), 'not blf')
$layouts = New-Mod 'Layouts' @{ base = (New-TestMap 9116 -Scenario 'levels\multi\base\base') }
Write-Json (Join-Path $layouts 'Project Reclaimer Layouts\elsewhere.json') @{ version = 1; name = 'Elsewhere'; base_map = @{ id = 1; stem = 'nowhere' } }
Write-Json (Join-Path $layouts 'Project Reclaimer Layouts\old.json') @{ version = 1; name = 'Old Mix'; base_map = @{ id = 7521; stem = 'base' } }
New-Mod 'OldVersion' @{ old = (New-TestMap 9117 -Scenario 'levels\multi\old\old') } @{ Info = { param($i) $i.MaxAppVersion.Minor = 3000; $i.MinAppVersion.Minor = 2000 } } | Out-Null
$item = Join-Path $mods 'Workshop\123456'
New-Item -ItemType Directory -Path $item | Out-Null
$moved = New-Mod 'Item' @{ item = (New-TestMap 9118 -Scenario 'levels\multi\item\item') } @{ Info = { param($i) $i.ModIdentifier.HostedModIds = @{ SteamWorkshopId = 999 } } }
Get-ChildItem $moved | Move-Item -Destination $item
Remove-Item $moved
Write-Json (Join-Path $item 'reclaimer-installed.json') @{ item = 123456; files = @(, @('maps/gone.map', 10)) }

# ---------------------------------------------------------------- run it, as a modder does
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tool 'checkmodhealth.ps1') -Path $mods -NoUpdateCheck -NoPause | Out-Null
$exit = $LASTEXITCODE
$log = Get-ChildItem (Join-Path $tool 'logs') -Filter '*.txt' | Select-Object -First 1
$text = Get-Content -LiteralPath $log.FullName -Raw
$sections = @{}
foreach ($section in ($text -split '={60,}')) {
    $match = [regex]::Match($section, [regex]::Escape($mods) + '\\([^\r\n]+)')
    if ($match.Success) { $sections[$match.Groups[1].Value.Trim()] = $section }
}

$failed = 0
function Expect([string]$Mod, [string[]]$Codes, [string]$Verdict = $null, [string[]]$Absent = @()) {
    $section = $script:sections[$Mod]
    if (-not $section) { Write-Host "FAIL  $Mod`: not in the report" -ForegroundColor Red; $script:failed++; return }
    foreach ($code in $Codes) {
        if ($section -match "\($([regex]::Escape($code))\)") { Write-Host "ok    $Mod`: $code" -ForegroundColor Green }
        else { Write-Host "FAIL  $Mod`: $code missing" -ForegroundColor Red; $script:failed++ }
    }
    foreach ($code in $Absent) {
        if ($section -match "\($([regex]::Escape($code))\)") { Write-Host "FAIL  $Mod`: $code shouldn't be there" -ForegroundColor Red; $script:failed++ }
        else { Write-Host "ok    $Mod`: no $code" -ForegroundColor Green }
    }
    if ($Verdict) {
        if ($section -match [regex]::Escape($Verdict)) { Write-Host "ok    $Mod`: $Verdict" -ForegroundColor Green }
        else { Write-Host "FAIL  $Mod`: not '$Verdict'" -ForegroundColor Red; $script:failed++ }
    }
}

Expect 'Sound' @() 'READY: nothing wrong found' @('map-renamed', 'map-not-described')
Expect 'OldCopy' @('map-old-copy') 'READY, BUT READ THE WARNINGS'
Expect 'WrongName' @('description-no-map', 'map-not-described')
Expect 'BadJson' @('modinfo-unreadable')
Expect 'BadFields' @('modinfo-field-case', 'bad-modguid', 'no-app-version')
Expect 'WrongEngine' @('bad-engine', 'not-halo3')
Expect 'Damaged' @('map-damaged')
Expect 'Campaign' @('map-not-multiplayer')
Expect 'First' @('duplicate-modguid', 'duplicate-mapguid', 'duplicate-map-id', 'same-map-name')
Expect 'Second' @('duplicate-modguid', 'duplicate-mapguid', 'duplicate-map-id')
Expect 'Junk' @('unneeded-files')
Expect 'Images' @('image-missing', 'image-not-png', 'image-in-root', 'image-too-big')
Expect 'Settings' @('bad-map-flag', 'bad-team-count', 'bad-weapon')
Expect 'Shared' @('shared-flag-on')
Expect 'Empty' @('no-contents')
Expect 'Loose' @('no-modinfo')
Expect 'Sounds' @('soundbank-damaged', 'soundbank-info-alone', 'blf-damaged')
Expect 'Layouts' @('layout-no-map', 'layout-other-version')
Expect 'Workshop\123456' @('workshop-id-mismatch', 'workshop-incomplete')
Expect 'Renamed' @('map-renamed')
Expect 'Unlisted' @('description-unlisted', 'name-spaces')
Expect 'Teams' @('team-count-zero', 'team-category-all')
Expect 'VideosOff' @('contents-flag-off')
Expect 'CampaignMod' @('description-missing', 'mission-times', 'campaign-players') $null @('map-not-described', 'map-not-multiplayer')
Expect 'LongTitle' @('title-too-long')
Expect 'Copies' @('unneeded-files')
Expect 'RootMap' @('map-not-in-maps')
Expect 'Sounds' @('mapinfo-leftover')
if ($text -match 'MCC on this PC: (\d+)\.(\d+)') { Expect 'OldVersion' @('app-version-old') }
else { Write-Host 'skip  OldVersion: MCC isn''t installed here' -ForegroundColor DarkGray }
if ($exit -ne 3) { Write-Host "FAIL  exit code $exit, not 3 (mods not ready)" -ForegroundColor Red; $failed++ } else { Write-Host 'ok    exit code 3' -ForegroundColor Green }

Remove-Item -LiteralPath $work -Recurse -Force
if ($failed) { Write-Host "$failed check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green

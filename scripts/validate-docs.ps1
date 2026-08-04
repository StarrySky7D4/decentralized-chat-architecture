[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$rootPrefix = $rootPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$gitPath = (Join-Path $rootPath '.git').TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$errors = New-Object 'System.Collections.Generic.List[string]'

function Get-DisplayPath {
    param([string]$Path)

    $rootUri = New-Object System.Uri(($rootPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar))
    $pathUri = New-Object System.Uri($Path)
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('/', [IO.Path]::DirectorySeparatorChar)
}

function Add-ValidationError {
    param(
        [string]$File,
        [int]$Line,
        [string]$Message
    )

    $display = Get-DisplayPath -Path $File
    if ($Line -gt 0) {
        $errors.Add("${display}:${Line}: $Message")
    } else {
        $errors.Add("${display}: $Message")
    }
}

function Test-LocalLink {
    param(
        [string]$File,
        [int]$Line,
        [string]$RawTarget
    )

    $target = $RawTarget.Trim()
    if ($target.StartsWith('<')) {
        $closing = $target.IndexOf('>')
        if ($closing -lt 1) {
            Add-ValidationError -File $File -Line $Line -Message "malformed angle-bracket link: $RawTarget"
            return
        }
        $target = $target.Substring(1, $closing - 1)
    } else {
        $target = ($target -split '\s+', 2)[0]
    }

    if ([string]::IsNullOrWhiteSpace($target) -or $target.StartsWith('#') -or $target.StartsWith('//')) {
        return
    }
    if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:') {
        return
    }

    $pathPart = ($target -split '[#?]', 2)[0]
    if ([string]::IsNullOrWhiteSpace($pathPart)) {
        return
    }

    try {
        $decoded = [Uri]::UnescapeDataString($pathPart).Replace('/', [IO.Path]::DirectorySeparatorChar)
    } catch {
        Add-ValidationError -File $File -Line $Line -Message "invalid percent-encoding in link: $target"
        return
    }

    if ([IO.Path]::IsPathRooted($decoded)) {
        Add-ValidationError -File $File -Line $Line -Message "repository link must be relative: $target"
        return
    }

    $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $File) $decoded))
    if ($resolved -ne $rootPath -and -not $resolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Add-ValidationError -File $File -Line $Line -Message "relative link escapes repository: $target"
        return
    }
    if (-not (Test-Path -LiteralPath $resolved)) {
        Add-ValidationError -File $File -Line $Line -Message "broken relative link: $target"
    }
}

$markdownFiles = Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force -Filter '*.md' |
    Where-Object { -not $_.FullName.StartsWith($gitPath, [StringComparison]::OrdinalIgnoreCase) } |
    Sort-Object FullName

foreach ($item in $markdownFiles) {
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Add-ValidationError -File $item.FullName -Line 0 -Message 'UTF-8 BOM is not allowed'
    }

    try {
        $text = $utf8.GetString($bytes)
    } catch {
        Add-ValidationError -File $item.FullName -Line 0 -Message 'file is not strict UTF-8'
        continue
    }

    if (-not $text.EndsWith("`n")) {
        Add-ValidationError -File $item.FullName -Line 0 -Message 'file must end with a newline'
    }
    if ($text -match '(\r\n|\n|\r){2,}$') {
        Add-ValidationError -File $item.FullName -Line 0 -Message 'file must end with exactly one newline'
    }

    $lines = [regex]::Split($text, "\r\n|\n|\r")
    $openFence = $null
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $line = $lines[$index]
        $lineNumber = $index + 1

        if ($line -match '[ \t]+$') {
            Add-ValidationError -File $item.FullName -Line $lineNumber -Message 'trailing whitespace'
        }

        $fenceMatch = [regex]::Match($line, '^[ ]{0,3}(?<fence>`{3,}|~{3,})(?<rest>.*)$')
        if ($fenceMatch.Success) {
            $fence = $fenceMatch.Groups['fence'].Value
            if ($null -eq $openFence) {
                $openFence = $fence
            } elseif ($fence[0] -eq $openFence[0] -and $fence.Length -ge $openFence.Length -and [string]::IsNullOrWhiteSpace($fenceMatch.Groups['rest'].Value)) {
                $openFence = $null
            }
        }

        foreach ($match in [regex]::Matches($line, '!?(?<!\\)\[[^\]]*\]\((?<target>[^)]+)\)')) {
            Test-LocalLink -File $item.FullName -Line $lineNumber -RawTarget $match.Groups['target'].Value
        }
        $reference = [regex]::Match($line, '^[ ]{0,3}\[[^\]]+\]:[ \t]*(?<target>\S+)')
        if ($reference.Success) {
            Test-LocalLink -File $item.FullName -Line $lineNumber -RawTarget $reference.Groups['target'].Value
        }
    }

    if ($null -ne $openFence) {
        Add-ValidationError -File $item.FullName -Line 0 -Message "unclosed fenced code block ($openFence)"
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error -Message $_ -ErrorAction Continue }
    Write-Host "Documentation validation failed with $($errors.Count) error(s)."
    exit 1
}

Write-Host "Validated $($markdownFiles.Count) Markdown file(s): strict UTF-8, relative links, fences, whitespace, and EOF."

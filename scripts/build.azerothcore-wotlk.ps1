#https://www.azerothcore.org/wiki/installation
#https://github.com/liyunfan1223/azerothcore-wotlk
#git config --global pager.diff false && git config --global pager.log false && git config --global pager.show false
$debug = $false
$locationsJsonPath = Join-Path $PSScriptRoot "build.azerothcore-wotlk.locations.json"
$prsJsonPath = Join-Path $PSScriptRoot "build.azerothcore-wotlk.prs.json"
$locationsConfig = $null
$prsConfig = $null
$prsConfigChanged = $false
$all_prs = @()
$all_prsByPath = @{}
$repositoryConfigByPath = @{}
$release = "RelWithDebInfo"
# Debug, Release, MinSizeRel (minimized size), or RelWithDebInfo.
# RelWithDebInfo is the release build with debug symbols recommended by TrinityCore and AzerothCore.
$clean = $false
$partialclean = $false
$build = $true
$compile = $true
$extractdata = $false
$checkdistfiles = $true
$runsql = $false
$run = $true
$createusers = $false
$startclient = $false
$basepath = 'J:\Code\ac'
$wowclientdir = 'C:\ProgramData\WOW\Wowclient'
$wowexe = 'nicks_launcher.exe'
$mysqlexe = "C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe"
Set-Location "${basepath}"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath | Select-Object -First 1
if (-not $vs) {
    Write-Host "❌ Error: Visual Studio installation with C++ tools not found." -ForegroundColor Red
    exit 1
}
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64'

####
# Requirements
# https://dev.mysql.com/downloads/mysql/8.4.html
# Add to PATH: "C:\Program Files\MySQL\MySQL Server 8.0\bin\"
# MYSQL_ROOT_DIR set to "C:\Program Files\MySQL\MySQL Server 8.4"
# BOOST Binaries "C:\ProgramData\boost" from https://sourceforge.net/projects/boost/files/boost-binaries/
# BOOST_ROOT set to "C:\ProgramData\boost"
# https://cmake.org/download/ x64 installed from msi. ver with vs studio is too old
# http://www.slproweb.com/products/Win32OpenSSL.html
#

# Define a reusable function to merge a single PR
function Merge-PR {
    param (
        [int]$pr_num,
        [string]$remote,
        [string]$branch,
        [string]$location
    )

    Process {
        Write-Host "------------------------------------------------"
        Write-Host "Processing PR #$pr_num..." -ForegroundColor Cyan

        # --- 1. Check PR Status via GitHub API ---

        $remoteUrlOutput = @(git remote get-url $remote 2>$null)
        if ($LASTEXITCODE -ne 0 -or $remoteUrlOutput.Count -eq 0) {
            throw "Could not get the URL for remote '$remote'."
        }
        $remoteUrl = $remoteUrlOutput | Select-Object -First 1
        $urlMatch = [regex]::Match(
            $remoteUrl,
            '(?i)github\.com[:/](?<owner>[^/]+)/(?<repository>[^/]+?)(?:\.git)?/?$'
        )
        if (-not $urlMatch.Success) {
            throw "Remote '$remote' is not a supported GitHub URL: $remoteUrl"
        }
        $repoPath = "$($urlMatch.Groups['owner'].Value)/$($urlMatch.Groups['repository'].Value)"

        $apiUrl = "https://api.github.com/repos/$repoPath/pulls/$pr_num"
        $pr_status = ""

        try {
            Write-Host "Checking status of PR #$pr_num from $apiUrl..." -ForegroundColor Gray
            # Call the GitHub API
            $pr_data = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop

            if ($null -ne $pr_data.merged_at) {
                # PR is merged
                $pr_status = "MERGED"
            } elseif ($pr_data.state -eq "closed") {
                # PR is closed but not merged
                $pr_status = "CLOSED"
            } elseif ($pr_data.state -eq "open") {
                # PR is still open
                $pr_status = "OPEN"
            }
        } catch {
            # This can fail if the PR doesn't exist (typo?), API is down, or rate limit
            Write-Host "⚠️ Could not fetch PR status from GitHub API for PR #$pr_num." -ForegroundColor Yellow
            Write-Host ($_.Exception.Message | Out-String) -ForegroundColor Gray
            Write-Host "This could be a typo in the PR number or an API rate limit."
            $choice = Read-Host "Do you want to try merging it anyway? (y/n)"
            if ($choice -ne 'y') {
                Write-Host "Skipping PR #$pr_num."
                Write-Host "------------------------------------------------`n"
                return # Skip to the next PR
            }
            Write-Host "Assuming PR is 'OPEN' and proceeding..." -ForegroundColor Yellow
            $pr_status = "OPEN" # Default to old behavior on user confirm
        }

        # --- 2. Handle based on Status ---

        if ($pr_status -eq "MERGED") {
            Write-Host "✅ PR #$pr_num is already MERGED into remote." -ForegroundColor DarkYellow
            $removeChoice = Read-Host "Remove PR #$pr_num from JSON list? (y/n)"
            if ($removeChoice -eq 'y') {
                Remove-PrFromJson -pr_num $pr_num -remote $remote -branch $branch -location $location
            }
            Write-Host "------------------------------------------------`n"
            return # Skip to the next PR
        }

        if ($pr_status -eq "CLOSED") {
            Write-Host "❓ PR #$pr_num is CLOSED." -ForegroundColor Yellow
            $choice = Read-Host "Do you want to merge it (y) or unmerge (and del from json) it (n)?"
            if ($choice -eq 'n') {
                Write-Host "Looking for previous merge commit for PR #$pr_num..." -ForegroundColor Cyan
                $commit_hash = git log --grep="PR #$pr_num" --merges --format="%H" -n 1
                if ($commit_hash) {
                    Write-Host "Found merge commit: $commit_hash" -ForegroundColor Gray
                    Write-Host "Reverting merge commit..." -ForegroundColor Yellow
                    git revert -m 1 $commit_hash --no-edit
                    if ($LASTEXITCODE -ne 0) {
                        $conflictFiles = @(git diff --name-only --diff-filter=U)
                        if ($conflictFiles.Count -eq 0) {
                            throw "Failed to revert PR #$pr_num without resolvable file conflicts."
                        }
                        Resolve-GitConflicts -Context "reverting PR #$pr_num"
                        git add -A
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to stage the resolved revert for PR #$pr_num."
                        }
                        git revert --continue
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to continue the resolved revert for PR #$pr_num."
                        }
                    }
                    Write-Host "✅ Successfully reverted PR #$pr_num." -ForegroundColor Green
                    Remove-PrFromJson -pr_num $pr_num -remote $remote -branch $branch -location $location
                } else {
                    Write-Host "⚠️ No merge commit found for PR #$pr_num." -ForegroundColor Yellow
                }
                Write-Host "------------------------------------------------`n"
                return # Skip to the next PR
            }
            Write-Host "Proceeding with merge for CLOSED PR #$pr_num..."
        }

        # --- 3. Proceed with Merge (if OPEN or user-confirmed CLOSED) ---

        Write-Host "Merging PR #$pr_num for testing..." -ForegroundColor Green

        # Pull latest changes from the current branch first
        #git pull

        #Write-Host "Using remote '$upstreamRemote' in folder $((Get-Location).Path | Split-Path -Leaf)"

        # Fetch the latest PR head
        Write-Host "Fetching $remote pull/$pr_num/head..." -ForegroundColor Gray
        git fetch $remote pull/$pr_num/head

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch PR #$pr_num from '$remote'."
        }

        # Merge directly from FETCH_HEAD (no local pr-* branch)
        $mergeOutput = @(git merge FETCH_HEAD --no-ff --no-commit 2>&1)
        $mergeExitCode = $LASTEXITCODE

        # Check if already up to date
        if ($mergeOutput -match "Already up to date" -or $mergeOutput -match "Already up-to-date") {
            Write-Host "✅ PR #$pr_num is already fully merged (already up to date)." -ForegroundColor Green
            Write-Host "Skipping commit and push."
            Write-Host "------------------------------------------------`n"
            return
        }

        # Check if there are actual conflicts (files with conflict markers)
        $conflictFiles = git diff --name-only --diff-filter=U

        if ($mergeExitCode -ne 0 -and -not $conflictFiles) {
            Write-Host ($mergeOutput -join [Environment]::NewLine) -ForegroundColor Gray
            throw "Merge failed for PR #$pr_num without resolvable file conflicts."
        }

        if ($conflictFiles) {
            # CONFLICT PATH - there are unresolved conflicts
            Write-Host "🧩 Conflicts detected while merging PR #$pr_num. Please resolve." -ForegroundColor Yellow
            Write-Host "Opening mergetool..."
            git mergetool

            if ($LASTEXITCODE -ne 0) {
                throw "Mergetool failed or was aborted for PR #$pr_num."
            }

            # Check again if there are still unresolved conflicts after mergetool
            $conflictFiles = git diff --name-only --diff-filter=U
            if ($conflictFiles) {
                Write-Host "❌ Unresolved conflicts remain in the following files:" -ForegroundColor Red
                $conflictFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
                throw "Unresolved conflicts remain for PR #$pr_num."
            }

            Write-Host "✅ Conflicts resolved successfully." -ForegroundColor Green
        } else {
            # CLEAN MERGE PATH - merge succeeded without conflicts
            Write-Host "✅ Clean merge of PR #$pr_num." -ForegroundColor Green
        }

        # Verify there are actually changes to commit
        $statusOutput = git status --porcelain
        if (-not $statusOutput) {
            Write-Host "✅ PR #$pr_num merged but nothing to commit (working tree clean)." -ForegroundColor Green
            Write-Host "Aborting merge state..."
            if (Test-GitRef -Ref "MERGE_HEAD") {
                git merge --abort
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to abort the empty merge for PR #$pr_num."
                }
            }
            Write-Host "Skipping commit and push."
            Write-Host "------------------------------------------------`n"
            return
        }

        # After merge is clean (either no conflicts or conflicts resolved), commit and push
        Write-Host "Staging all changes..."
        git add -A
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to stage PR #$pr_num."
        }

        Write-Host "Committing the merge..."
        git commit -m "Merge PR #$pr_num for testing"

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to commit PR #$pr_num."
        }

        Write-Host "✅ Committed PR #$pr_num successfully." -ForegroundColor Green

        Write-Host "Successfully merged PR #$pr_num."
        Write-Host "------------------------------------------------`n"
    }
}
function Import-PrsJson {
    if (-not (Test-Path -LiteralPath $prsJsonPath -PathType Leaf)) {
        throw "PR JSON file not found at $prsJsonPath."
    }

    try {
        $script:prsConfig = Get-Content -LiteralPath $prsJsonPath -Raw | ConvertFrom-Json
    } catch {
        throw "Failed to parse PR JSON file at $prsJsonPath. $($_.Exception.Message)"
    }

    if ($script:prsConfig.SchemaVersion -ne 2) {
        throw "Unsupported PR JSON schema version '$($script:prsConfig.SchemaVersion)'. Expected version 2."
    }

    $script:all_prs = @()
    $script:all_prsByPath = @{}
    $script:repositoryConfigByPath = @{}

    foreach ($repository in @($script:prsConfig.Repositories)) {
        $locationName = [string]$repository.Location
        $repositoryPath = [string]$repository.Path
        if ([string]::IsNullOrWhiteSpace($locationName) -or [string]::IsNullOrWhiteSpace($repositoryPath)) {
            throw "Every repository entry must have non-empty Location and Path values."
        }

        $repositoryKey = "$locationName`n$repositoryPath"
        if ($script:repositoryConfigByPath.ContainsKey($repositoryKey)) {
            throw "Duplicate repository configuration for $locationName/$repositoryPath."
        }

        $sourceIndexes = @{}
        $sourceKeys = @{}
        $sources = @($repository.Sources)
        if ($sources.Count -eq 0) {
            throw "Repository $locationName/$repositoryPath must have at least one source."
        }
        foreach ($source in $sources) {
            $sourceIndex = 0
            if (-not [int]::TryParse([string]$source.Index, [ref]$sourceIndex) -or $sourceIndex -lt 1) {
                throw "Invalid source Index '$($source.Index)' for $locationName/$repositoryPath."
            }
            if ($sourceIndexes.ContainsKey($sourceIndex)) {
                throw "Duplicate source Index '$sourceIndex' for $locationName/$repositoryPath."
            }
            $sourceIndexes[$sourceIndex] = $true

            $remote = [string]$source.Remote
            $branch = [string]$source.Branch
            $strategy = [string]$source.Strategy
            if ([string]::IsNullOrWhiteSpace($remote) -or [string]::IsNullOrWhiteSpace($branch)) {
                throw "Every source for $locationName/$repositoryPath must have Remote and Branch values."
            }
            git check-ref-format "refs/heads/$branch" *> $null
            if ($LASTEXITCODE -ne 0) {
                throw "Invalid branch name '$branch' for $locationName/$repositoryPath $remote."
            }
            if ($strategy -notin @("ff-only", "merge", "fetch-only")) {
                throw "Invalid strategy '$strategy' for $locationName/$repositoryPath $remote/$branch."
            }

            $sourceKey = "$remote`n$branch"
            if ($sourceKeys.ContainsKey($sourceKey)) {
                throw "Duplicate source $remote/$branch for $locationName/$repositoryPath."
            }
            $sourceKeys[$sourceKey] = $true

            $seenPrs = @{}
            foreach ($pr in @($source.PRs)) {
                $prNumber = 0
                if (-not [int]::TryParse([string]$pr, [ref]$prNumber) -or $prNumber -lt 1) {
                    throw "Invalid PR '$pr' for $locationName/$repositoryPath $remote/$branch."
                }
                if ($seenPrs.ContainsKey($prNumber)) {
                    throw "Duplicate PR #$prNumber for $locationName/$repositoryPath $remote/$branch."
                }
                $seenPrs[$prNumber] = $true
            }

            $group = [pscustomobject]@{
                Location = $locationName
                Path = $repositoryPath
                Index = $sourceIndex
                Remote = $remote
                Branch = $branch
                Strategy = $strategy
                PRs = @($source.PRs)
                SourceConfig = $source
            }
            $script:all_prs += $group
        }

        $expectedIndex = 1
        foreach ($sourceIndex in @($sourceIndexes.Keys | Sort-Object)) {
            if ($sourceIndex -ne $expectedIndex) {
                throw "Source indexes for $locationName/$repositoryPath must be contiguous starting at 1."
            }
            $expectedIndex++
        }

        $script:repositoryConfigByPath[$repositoryKey] = $repository
        $script:all_prsByPath[$repositoryKey] = @{}
        foreach ($group in @($script:all_prs | Where-Object {
            $_.Location -eq $locationName -and $_.Path -eq $repositoryPath
        })) {
            $script:all_prsByPath[$repositoryKey]["$($group.Remote)`n$($group.Branch)"] = $group
        }
    }

    Write-Host "✅ PR and remote configuration loaded from $prsJsonPath." -ForegroundColor Green
}

function Save-PrsJson {
    try {
        $json = $script:prsConfig | ConvertTo-Json -Depth 10
        $json = $json -replace "`r`n?", "`n"
        [System.IO.File]::WriteAllText(
            $prsJsonPath,
            $json + "`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        $script:prsConfigChanged = $true
    } catch {
        throw "Failed to write PR JSON file at $prsJsonPath. $($_.Exception.Message)"
    }
}

function Remove-PrFromJson {
    param (
        [int]$pr_num,
        [string]$remote,
        [string]$branch,
        [string]$location
    )

    if ($all_prsByPath.Count -eq 0) {
        Import-PrsJson
    }

    $currentDirName = Split-Path -Leaf (Get-Location).Path
    $repositoryKey = "$location`n$currentDirName"
    $sourceKey = "$remote`n$branch"
    if (-not $all_prsByPath.ContainsKey($repositoryKey) -or
        -not $all_prsByPath[$repositoryKey].ContainsKey($sourceKey)) {
        Write-Host "⚠️ No PR group found for $location/$currentDirName $remote/$branch." -ForegroundColor Yellow
        return
    }

    $group = $all_prsByPath[$repositoryKey][$sourceKey]
    $remainingPrs = @($group.SourceConfig.PRs | Where-Object { $_ -ne $pr_num })
    if ($remainingPrs.Count -eq @($group.SourceConfig.PRs).Count) {
        Write-Host "ℹ️ PR #$pr_num not found for $location/$currentDirName $remote/$branch." -ForegroundColor Gray
        return
    }

    $group.SourceConfig.PRs = $remainingPrs
    $group.PRs = $remainingPrs
    Save-PrsJson
    Write-Host "✅ Removed PR #$pr_num from $location/$currentDirName $remote/$branch." -ForegroundColor Green
}

function Import-UpdateLocations {
    if (-not (Test-Path -LiteralPath $locationsJsonPath -PathType Leaf)) {
        throw "Update locations JSON file not found at $locationsJsonPath."
    }

    try {
        $script:locationsConfig = Get-Content -LiteralPath $locationsJsonPath -Raw | ConvertFrom-Json
    } catch {
        throw "Failed to parse update locations JSON at $locationsJsonPath. $($_.Exception.Message)"
    }

    if ($script:locationsConfig.SchemaVersion -ne 1) {
        throw "Unsupported locations schema version '$($script:locationsConfig.SchemaVersion)'. Expected version 1."
    }

    $locationNames = @{}
    $locationsByName = @{}
    foreach ($location in @($script:locationsConfig.Locations)) {
        $name = [string]$location.Name
        $path = [string]$location.Path
        $scan = [string]$location.Scan
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($path)) {
            throw "Every update location must have non-empty Name and Path values."
        }
        if ($locationNames.ContainsKey($name)) {
            throw "Duplicate update location '$name'."
        }
        $locationNames[$name] = $true
        $locationsByName[$name] = $location

        if (-not [System.IO.Path]::IsPathRooted($path)) {
            throw "Update location '$name' must use an absolute path: $path"
        }
        if ($scan -notin @("self", "children")) {
            throw "Invalid Scan value '$scan' for update location '$name'."
        }
        foreach ($property in @("Fetch", "Merge", "MergePRs")) {
            if ($location.PSObject.Properties.Name -notcontains $property -or
                $location.$property -isnot [bool]) {
                throw "Update location '$name' must have a Boolean $property value."
            }
        }
    }

    foreach ($repository in @($script:prsConfig.Repositories)) {
        $locationName = [string]$repository.Location
        if (-not $locationNames.ContainsKey($locationName)) {
            throw "Repository '$($repository.Path)' references unknown location '$($repository.Location)'."
        }

        $location = $locationsByName[$locationName]
        $repositoryName = [string]$repository.Path
        if ([System.IO.Path]::GetFileName($repositoryName) -ne $repositoryName) {
            throw "Repository Path must be one directory name, not a nested path: $locationName/$repositoryName"
        }
        $configuredPath = if ($location.Scan -eq "self") {
            if ((Split-Path -Leaf $location.Path) -ne $repositoryName) {
                $expectedRepository = Split-Path -Leaf $location.Path
                throw "Self-scanned location '$locationName' must configure repository '$expectedRepository'."
            }
            $location.Path
        } else {
            Join-Path $location.Path $repositoryName
        }

        $locationEnabled = $location.Fetch -or $location.Merge -or $location.MergePRs
        if ($locationEnabled -and -not (Test-Path -LiteralPath $configuredPath -PathType Container)) {
            throw "Configured repository does not exist: $configuredPath"
        }
    }

    Write-Host "✅ Update locations loaded from $locationsJsonPath." -ForegroundColor Green
}

function Test-GitRef {
    param ([string]$Ref)

    git rev-parse --verify --quiet $Ref *> $null
    return $LASTEXITCODE -eq 0
}

function Get-GitOperationState {
    if (Test-GitRef -Ref "MERGE_HEAD") {
        return "merge"
    }
    if (Test-GitRef -Ref "CHERRY_PICK_HEAD") {
        return "cherry-pick"
    }
    if (Test-GitRef -Ref "REVERT_HEAD") {
        return "revert"
    }

    $gitDirectoryOutput = @(git rev-parse --git-dir 2>$null)
    $gitExitCode = $LASTEXITCODE
    $gitDirectory = $gitDirectoryOutput | Select-Object -First 1
    if ($gitExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($gitDirectory)) {
        throw "Unable to resolve the Git directory for $((Get-Location).Path)."
    }
    if (-not [System.IO.Path]::IsPathRooted($gitDirectory)) {
        $gitDirectory = Join-Path (Get-Location).Path $gitDirectory
    }

    if (Test-Path -LiteralPath (Join-Path $gitDirectory "rebase-merge") -PathType Container) {
        return "rebase"
    }
    if (Test-Path -LiteralPath (Join-Path $gitDirectory "rebase-apply") -PathType Container) {
        return "rebase-or-am"
    }
    if (Test-Path -LiteralPath (Join-Path $gitDirectory "BISECT_START") -PathType Leaf) {
        return "bisect"
    }
    if (Test-Path -LiteralPath (Join-Path $gitDirectory "sequencer") -PathType Container) {
        return "sequencer"
    }

    return "none"
}

function Resolve-GitConflicts {
    param ([string]$Context)

    $conflictFiles = @(git diff --name-only --diff-filter=U)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect conflicts while $Context."
    }
    if ($conflictFiles.Count -eq 0) {
        return
    }

    Write-Host "🧩 Conflicts detected while $Context." -ForegroundColor Yellow
    $conflictFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    git mergetool
    if ($LASTEXITCODE -ne 0) {
        throw "Mergetool failed or was aborted while $Context."
    }

    $conflictFiles = @(git diff --name-only --diff-filter=U)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to recheck conflicts while $Context."
    }
    if ($conflictFiles.Count -gt 0) {
        throw "Unresolved conflicts remain while ${Context}: $($conflictFiles -join ', ')"
    }
}

function Complete-PendingGitMerge {
    $operation = Get-GitOperationState
    if ($operation -eq "none") {
        $conflictFiles = @(git diff --name-only --diff-filter=U)
        if ($conflictFiles.Count -gt 0) {
            throw "Unmerged files exist without an active merge: $($conflictFiles -join ', ')"
        }
        return
    }
    if ($operation -ne "merge") {
        throw "Repository has an unfinished $operation operation. Complete or abort it before updating."
    }

    Write-Host "⚠️ Completing an unfinished merge before fetching updates." -ForegroundColor Yellow
    Resolve-GitConflicts -Context "completing the existing merge"
    git add -A
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to stage the completed merge."
    }
    git commit --no-edit
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to commit the completed merge."
    }
}

function Save-LocalChanges {
    $status = @(git status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect repository status."
    }
    if ($status.Count -eq 0) {
        Write-Host "✅ Working directory is clean." -ForegroundColor Green
        return
    }

    Write-Host "⚠️ Committing local changes before upstream merges:" -ForegroundColor Yellow
    $status | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    git add -A
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to stage local changes."
    }

    git diff --cached --quiet
    $diffExitCode = $LASTEXITCODE
    if ($diffExitCode -eq 0) {
        Write-Host "No stageable local changes were found." -ForegroundColor Gray
        return
    }
    if ($diffExitCode -ne 1) {
        throw "Failed to inspect staged local changes."
    }

    git commit -m "Local changes before upstream merge."
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to commit local changes before upstream merges."
    }

    $remainingStatus = @(git status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to verify local changes after committing."
    }
    if ($remainingStatus.Count -gt 0) {
        throw "Repository still has uncommitted changes after the safety commit."
    }
}

function Get-RepositoryDirectories {
    param ([pscustomobject]$Location)

    if (-not $Location.Fetch -and -not $Location.Merge -and -not $Location.MergePRs) {
        Write-Host "⏭️ Update location '$($Location.Name)' is disabled." -ForegroundColor DarkGray
        return
    }
    if (-not (Test-Path -LiteralPath $Location.Path -PathType Container)) {
        throw "Enabled update location '$($Location.Name)' does not exist: $($Location.Path)"
    }

    $candidates = if ($Location.Scan -eq "self") {
        @(Get-Item -LiteralPath $Location.Path)
    } else {
        @(Get-ChildItem -LiteralPath $Location.Path -Directory | Sort-Object Name)
    }

    foreach ($candidate in $candidates) {
        $topLevelOutput = @(git -C $candidate.FullName rev-parse --show-toplevel 2>$null)
        $gitExitCode = $LASTEXITCODE
        $topLevel = $topLevelOutput | Select-Object -First 1
        if ($gitExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($topLevel)) {
            if (Test-Path -LiteralPath (Join-Path $candidate.FullName ".git")) {
                throw "Unable to inspect Git repository $($candidate.FullName)."
            }
            continue
        }

        $candidatePath = [System.IO.Path]::GetFullPath($candidate.FullName).TrimEnd("\", "/")
        $topLevelPath = [System.IO.Path]::GetFullPath($topLevel).TrimEnd("\", "/")
        if ($candidatePath -ieq $topLevelPath) {
            $candidate
        }
    }
}

function Get-RepositorySources {
    param (
        [string]$LocationName,
        [string]$RepositoryName,
        [string[]]$Remotes
    )

    $repositoryKey = "$LocationName`n$RepositoryName"
    if ($repositoryConfigByPath.ContainsKey($repositoryKey)) {
        $configuredSources = @($all_prs | Where-Object {
            $_.Location -eq $LocationName -and $_.Path -eq $RepositoryName
        } | Sort-Object Index)

        $configuredRemotes = @($configuredSources.Remote | Sort-Object -Unique)
        foreach ($remote in $configuredRemotes) {
            if ($remote -notin $Remotes) {
                throw "Configured remote '$remote' does not exist in $LocationName/$RepositoryName."
            }
        }
        if ($Remotes.Count -gt 1) {
            foreach ($remote in $Remotes) {
                if ($remote -notin $configuredRemotes) {
                    $message = "Multi-remote repository $LocationName/$RepositoryName is missing remote " +
                        "'$remote' in the JSON."
                    throw $message
                }
            }
        }
        return $configuredSources
    }

    if ($Remotes.Count -gt 1) {
        throw "Multi-remote repository $LocationName/$RepositoryName requires an ordered JSON entry."
    }
    if ($Remotes.Count -eq 0) {
        Write-Host "⏭️ Repository has no remotes; branch merging is skipped." -ForegroundColor Yellow
        return @()
    }

    $currentBranchOutput = @(git branch --show-current 2>$null)
    $gitExitCode = $LASTEXITCODE
    $currentBranch = $currentBranchOutput | Select-Object -First 1
    if ($gitExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($currentBranch)) {
        throw "Repository is in detached HEAD state."
    }

    $upstreamOutput = @(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null)
    $gitExitCode = $LASTEXITCODE
    $upstream = $upstreamOutput | Select-Object -First 1
    if ($gitExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstream)) {
        $remote = @($Remotes | Where-Object { $upstream.StartsWith("$_/", [System.StringComparison]::Ordinal) } |
            Sort-Object Length -Descending | Select-Object -First 1)
        if ($remote.Count -ne 1) {
            throw "Unable to map configured upstream '$upstream' to a remote."
        }
        $branch = $upstream.Substring($remote[0].Length + 1)
    } else {
        $remote = @($Remotes[0])
        $branch = $currentBranch
    }

    return @([pscustomobject]@{
        Location = $LocationName
        Path = $RepositoryName
        Index = 1
        Remote = [string]$remote[0]
        Branch = [string]$branch
        Strategy = "merge"
        PRs = @()
        SourceConfig = $null
    })
}

function Merge-SourceBranch {
    param ([pscustomobject]$Source)

    $sourceName = "$($Source.Remote)/$($Source.Branch)"
    if ($Source.Strategy -eq "fetch-only") {
        Write-Host "⏭️ $sourceName is configured for fetch only." -ForegroundColor DarkGray
        return
    }

    $trackingRef = "refs/remotes/$($Source.Remote)/$($Source.Branch)"
    if (-not (Test-GitRef -Ref $trackingRef)) {
        throw "Remote-tracking branch '$sourceName' does not exist after fetching."
    }

    Write-Host "📊 Pre-merge analysis for $sourceName" -ForegroundColor Yellow
    $counts = git rev-list --left-right --count "HEAD...$trackingRef"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to compare HEAD with $sourceName. The histories may be unrelated."
    }
    Write-Host "Local-only / source-only commits: $counts" -ForegroundColor Gray
    git --no-pager diff --stat "HEAD...$trackingRef"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to produce the pre-merge diff for $sourceName."
    }

    Write-Host "🔄 Merging $sourceName with strategy '$($Source.Strategy)'..." -ForegroundColor Cyan
    if ($Source.Strategy -eq "ff-only") {
        git merge --ff-only --no-edit $trackingRef
        if ($LASTEXITCODE -ne 0) {
            throw "Fast-forward-only merge failed for $sourceName. No fallback merge was attempted."
        }
    } else {
        $mergeOutput = @(git merge --no-commit --no-edit $trackingRef 2>&1)
        $mergeExitCode = $LASTEXITCODE
        if ($mergeOutput.Count -gt 0) {
            Write-Host ($mergeOutput -join [Environment]::NewLine)
        }

        $conflictFiles = @(git diff --name-only --diff-filter=U)
        if ($mergeExitCode -ne 0 -and $conflictFiles.Count -eq 0) {
            throw "Merge failed for $sourceName without resolvable file conflicts."
        }
        if ($conflictFiles.Count -gt 0) {
            Resolve-GitConflicts -Context "merging $sourceName"
        }

        if (Test-GitRef -Ref "MERGE_HEAD") {
            git add -A
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to stage the merge from $sourceName."
            }
            git commit -m "Upstream merge."
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to commit the merge from $sourceName."
            }
        }
    }

    git merge-base --is-ancestor $trackingRef HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "Verification failed: $sourceName is not an ancestor of HEAD after merging."
    }
    Write-Host "✅ $sourceName is merged." -ForegroundColor Green
}

function Merge-SourcePrs {
    param ([pscustomobject]$Source)

    $prs = @($Source.PRs)
    if ($prs.Count -eq 0) {
        return
    }

    Write-Host "🔀 Processing PRs from $($Source.Remote)/$($Source.Branch)..." -ForegroundColor Cyan
    foreach ($pr in $prs) {
        Merge-PR -pr_num ([int]$pr) -remote $Source.Remote -branch $Source.Branch -location $Source.Location
    }
}

function Get-OwnedRemote {
    param (
        [string[]]$Remotes,
        [pscustomobject]$RepositoryConfig
    )

    if ($null -ne $RepositoryConfig -and
        $RepositoryConfig.PSObject.Properties.Name -contains "PushRemote" -and
        -not [string]::IsNullOrWhiteSpace([string]$RepositoryConfig.PushRemote)) {
        $pushRemote = [string]$RepositoryConfig.PushRemote
        if ($pushRemote -notin $Remotes) {
            throw "Configured PushRemote '$pushRemote' does not exist."
        }
        return $pushRemote
    }

    $ownedRemotes = @()
    foreach ($remote in $Remotes) {
        $pushUrlOutput = @(git remote get-url --push --all $remote 2>$null)
        $gitExitCode = $LASTEXITCODE
        if ($gitExitCode -ne 0) {
            throw "Unable to read the push URL for remote '$remote'."
        }
        if ($pushUrlOutput -match "(?i)biship") {
            $ownedRemotes += $remote
        }
    }

    if ($ownedRemotes.Count -gt 1) {
        throw "More than one remote has a biship URL: $($ownedRemotes -join ', '). Configure PushRemote explicitly."
    }
    if ($ownedRemotes.Count -eq 1) {
        return $ownedRemotes[0]
    }
    return $null
}

function Push-RepositoryBranch {
    param (
        [string[]]$Remotes,
        [pscustomobject]$RepositoryConfig
    )

    $pushRemote = Get-OwnedRemote -Remotes $Remotes -RepositoryConfig $RepositoryConfig
    if ([string]::IsNullOrWhiteSpace($pushRemote)) {
        Write-Host "⏭️ No biship remote found; local commits will not be pushed." -ForegroundColor Yellow
        return
    }

    $branchOutput = @(git branch --show-current 2>$null)
    $gitExitCode = $LASTEXITCODE
    $branch = $branchOutput | Select-Object -First 1
    if ($gitExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        throw "Cannot push from detached HEAD state."
    }
    $status = @(git status --porcelain=v1)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to verify repository status before pushing."
    }
    if ($status.Count -gt 0) {
        throw "Repository is not clean after merging; refusing to push."
    }

    Write-Host "⬆️ Pushing $branch to $pushRemote..." -ForegroundColor Cyan
    git push $pushRemote "HEAD:refs/heads/$branch"
    if ($LASTEXITCODE -ne 0) {
        throw "Push failed for $pushRemote/$branch."
    }
}

function Update-GitRepository {
    param (
        [System.IO.DirectoryInfo]$RepositoryDirectory,
        [pscustomobject]$Location
    )

    Write-Host "`n================================================" -ForegroundColor DarkCyan
    Write-Host "Updating $($RepositoryDirectory.FullName)" -ForegroundColor Green
    Write-Host "================================================" -ForegroundColor DarkCyan

    Push-Location $RepositoryDirectory.FullName
    try {
        $branchOutput = @(git branch --show-current 2>$null)
        $gitExitCode = $LASTEXITCODE
        $branch = $branchOutput | Select-Object -First 1
        if ($gitExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
            throw "Repository is in detached HEAD state."
        }
        Write-Host "On branch: $branch" -ForegroundColor Green

        $remotes = @(git remote)
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to list remotes."
        }
        $repositoryKey = "$($Location.Name)`n$($RepositoryDirectory.Name)"
        $repositoryConfig = if ($repositoryConfigByPath.ContainsKey($repositoryKey)) {
            $repositoryConfigByPath[$repositoryKey]
        } else {
            $null
        }
        $sources = @(Get-RepositorySources -LocationName $Location.Name `
            -RepositoryName $RepositoryDirectory.Name -Remotes $remotes)

        if ($Location.Merge -or $Location.MergePRs) {
            Complete-PendingGitMerge
            Save-LocalChanges
        }

        if ($Location.Fetch) {
            Write-Host "🌐 Fetching all remotes..." -ForegroundColor Cyan
            git fetch --all --prune
            if ($LASTEXITCODE -ne 0) {
                throw "Fetch failed. No configured source merges were attempted."
            }
        }

        foreach ($source in $sources) {
            if ($Location.Merge) {
                Merge-SourceBranch -Source $source
            }
            if ($Location.MergePRs) {
                Merge-SourcePrs -Source $source
            }
        }

        if ($Location.Merge) {
            git submodule update --init --recursive
            if ($LASTEXITCODE -ne 0) {
                throw "Submodule update failed."
            }
        }

        if ($Location.Merge -or $Location.MergePRs) {
            Push-RepositoryBranch -Remotes $remotes -RepositoryConfig $repositoryConfig
        }
        Write-Host "✅ Repository update completed." -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

function Complete-PrConfigurationUpdate {
    if (-not $script:prsConfigChanged) {
        return
    }

    $configurationDirectory = Split-Path -Parent $prsJsonPath
    $repositoryRootOutput = @(git -C $configurationDirectory rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $repositoryRootOutput.Count -eq 0) {
        throw "Unable to find the repository that owns $prsJsonPath."
    }
    $repositoryRoot = $repositoryRootOutput | Select-Object -First 1
    $relativeConfigPath = [System.IO.Path]::GetRelativePath($repositoryRoot, $prsJsonPath).Replace("\", "/")

    Push-Location $repositoryRoot
    try {
        $configStatus = @(git status --porcelain=v1 -- $relativeConfigPath)
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to inspect the saved PR configuration."
        }
        if ($configStatus.Count -eq 0) {
            $script:prsConfigChanged = $false
            return
        }

        $otherStatus = @(git status --porcelain=v1 -- . ":(exclude)$relativeConfigPath")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to inspect the configuration repository before committing."
        }
        if ($otherStatus.Count -gt 0) {
            throw "The configuration repository changed again during module processing; refusing to combine changes."
        }

        git add -A -- $relativeConfigPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to stage the updated PR configuration."
        }
        git commit -m "Update PR configuration."
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to commit the updated PR configuration."
        }

        $remotes = @(git remote)
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to list remotes for the configuration repository."
        }
        Push-RepositoryBranch -Remotes $remotes -RepositoryConfig $null
        $script:prsConfigChanged = $false
    } finally {
        Pop-Location
    }
}

function Invoke-RepositoryUpdates {
    foreach ($location in @($locationsConfig.Locations)) {
        $repositories = @(Get-RepositoryDirectories -Location $location)
        foreach ($repository in $repositories) {
            Update-GitRepository -RepositoryDirectory $repository -Location $location
        }
    }
    Complete-PrConfigurationUpdate
}

try {
    Import-PrsJson
    Import-UpdateLocations

    if ($debug) {
        Write-Host "`$all_prs contents:" -ForegroundColor Cyan
        if ($all_prs.Count -eq 0) {
            Write-Host "all_prs is empty" -ForegroundColor Red
        } else {
            $all_prs | ConvertTo-Json -Depth 5 | Write-Host
        }
    }

    Invoke-RepositoryUpdates
} catch {
    Write-Host "❌ Repository update failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if ($clean) {
	if (Test-Path "${basepath}\Build") {
		Set-Location "${basepath}\Build"
		Write-Host "Cleaning..." -ForegroundColor Yellow
		cmake --build "${basepath}\Build" --target clean --config Debug -v
		cmake --build "${basepath}\Build" --target clean --config Release -v
		cmake --build "${basepath}\Build" --target clean --config MinSizeRel -v
		cmake --build "${basepath}\Build" --target clean --config RelWithDebInfo -v
		#Remove-Item -Recurse -Force _deps -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\CMakeFiles" -ErrorAction SilentlyContinue
		#Remove-Item -Recurse -Force deps -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\Logs" -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\Modules" -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\src" -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\x64" -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\ALL_BUILD*.*" -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\AzerothCore.sln" -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\cmake*.*" -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\install*.*" -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\revision*.*" -ErrorAction SilentlyContinue
		Remove-Item -Recurse -Force "${basepath}\Build\zero*.*" -ErrorAction SilentlyContinue
		$partialclean = $true
	}
}
if ($partialclean) {
	if (Test-Path "${basepath}\Build") {
		Set-Location "${basepath}\Build"
		Write-Host "Partial Cleaning..." -ForegroundColor Yellow
		Get-ChildItem -Path "${basepath}\Build\" -Recurse -Include "*.idb","*.pdb","*.tlog","*.pch" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
	}
}
if ($build) {
	New-Item -Path "${basepath}\Build" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
	if (-not (Test-Path "${basepath}\Build\Directory.Build.props")) { Copy-Item "${basepath}\Directory.Build.props" "${basepath}\Build\" -Force }
	Write-Host "Building azerothcore..." -ForegroundColor Green
	#cmake --fresh -S .. -B . -G "Visual Studio 17 2022" -A x64 -DTOOLS_BUILD=all #default
	Set-Location "${basepath}\Build"
	if ($debug)
	{
		cmake --fresh -S .. -B . -G "Visual Studio 18 2026" -A x64 -DTOOLS_BUILD=all -DCMAKE_CXX_FLAGS="/D_WIN32_WINNT=0x0A00 /EHsc" -DLUA_VERSION=luajit --debug-output
	}
	else
	{
		cmake --fresh -S .. -B . -G "Visual Studio 18 2026" -A x64 -DTOOLS_BUILD=all -DCMAKE_CXX_FLAGS="/D_WIN32_WINNT=0x0A00 /EHsc" -DLUA_VERSION=luajit
	}
	#cmake --fresh -S .. -B . -G "Visual Studio 17 2022" -A x64 -DTOOLS_BUILD=all -DCMAKE_CXX_FLAGS="/D_WIN32_WINNT=0x0A00 /EHsc /O2 /Ob2 /Oi" -DLUA_VERSION=luajit
	#cmake --fresh -S .. -B . -G "Visual Studio 17 2022" -A x64 -DTOOLS_BUILD=all -DCMAKE_CXX_FLAGS="/D_WIN32_WINNT=0x0A00 /EHsc /Od" -DLUA_VERSION=luajit #disable optimizations
	#cmake --fresh -S .. -B . -G "Visual Studio 17 2022" -A x64 -DTOOLS_BUILD=all -DCMAKE_CXX_FLAGS="/D_WIN32_WINNT=0x0A00 /EHsc /MD /Gw /Gy /O2 /Ob2 /Oi /Ot /Zo /GL- /Zm200 /arch:AVX2 /favor:INTEL64 /fp:fast" -DCMAKE_SHARED_LINKER_FLAGS="/OPT:REF /OPT:ICF /OPT:LBR" -DLUA_VERSION=luajit #way too many optimizations
	if ($LASTEXITCODE -ne 0) { Write-Host "❌ Error. Halting."; exit 1 }
}
if ($compile) {
	#build luajit manually. had to do this before. no idea why
	#Set-Location ${basepath}\Build\_deps\luajit21-src\src
	#./msvcbuild.bat static
	Write-Host "Compiling ${release} azerothcore..." -ForegroundColor Green
	Set-Location "${basepath}\Build"
	if ($debug)
	{
		cmake --build . --target ALL_BUILD --config ${release} $--debug-output -- /m:20 /p:UseMultiToolTask=true
	}
	else
	{
		cmake --build . --target ALL_BUILD --config ${release} -- /m:20 /p:UseMultiToolTask=true
	}
	if ($LASTEXITCODE -ne 0) { Write-Host "❌ Error. Halting."; exit 1 }
	Copy-Item "C:\Program Files\MySQL\MySQL Server 8.4\lib\libmysql.dll" -Destination "${basepath}\Build\bin\${release}"
	Copy-Item "C:\Program Files\OpenSSL-Win64\bin\legacy.dll" -Destination "${basepath}\Build\bin\${release}"
	#Copy-Item "C:\Program Files\OpenSSL-Win64\bin\libcrypto-3-x64.dll" -Destination "${basepath}\Build\bin\${release}"
	#Copy-Item "C:\Program Files\OpenSSL-Win64\bin\libssl-3-x64.dll" -Destination "${basepath}\Build\bin\${release}"
	Copy-Item "C:\Program Files\OpenSSL-Win64\bin\libcrypto-4-x64.dll" -Destination "${basepath}\Build\bin\${release}"
	Copy-Item "C:\Program Files\OpenSSL-Win64\bin\libssl-4-x64.dll" -Destination "${basepath}\Build\bin\${release}"
	New-Item -Path "${basepath}\Build\bin\${release}\Logs" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
	New-Item -Path "${basepath}\Build\bin\${release}\Data" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
	New-Item -Path "${basepath}\Build\bin\${release}\Temp" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
	Write-Host "Built!" -ForegroundColor Green
}
if ($runsql) {
	Write-Host "Running SQL..." -ForegroundColor Green
	#"${basepath}\modules\mod-individual-progression\data\sql",
	#"${basepath}\modules\mod-ollama-chat\data\sql",
	#"${basepath}\modules\mod-playerbots\data\sql"
	$folders = @(
		#"${basepath}\modules\mod-ah-bot\data\sql", disabled...
		"${basepath}\modules\mod-challenge-modes\data\sql"
	)
	foreach ($folder in $folders) {
		Get-ChildItem -Path $folder -Filter *.sql -Recurse | Sort-Object FullName | ForEach-Object {
			$path = $_.DirectoryName.ToLower()
		    if ($path -match 'archive') {
				Write-Host "⏭️ Skipping (archive): $($_.FullName)"
				return
			}
			$db = if ($path -match 'world') { "acore_world" }
				  elseif ($path -match 'characters') { "acore_characters" }
				  elseif ($path -match 'auth') { "acore_auth" }
				  elseif ($path -match 'playerbots') { "acore_playerbots" }
				  else { "unknown_db" }  # fallback

			Write-Host "Running against $db : $($_.FullName)..."
			#Get-Content $_.FullName | &"C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe" --user root -pbmw320 --database $db
			Get-Content $_.FullName | &"${mysqlexe}" --user root -pbmw320 --database $db
			if ($LASTEXITCODE -ne 0) {
				Write-Host "❌ Failed on $($_.FullName)."
				#exit 1
			}
		}
	}
	Write-Host "✅ All SQL scripts applied successfully."
}
if ($extractdata) {
	Write-Host "Extracting data from wow client..." -ForegroundColor Green
	Set-Location "${basepath}\Build\bin\${release}"
	Copy-Item map_extractor.* "$wowclientdir"
	Copy-Item mmaps_generator.* "$wowclientdir"
	Copy-Item vmap4_extractor.* "$wowclientdir"
	Copy-Item vmap4_assembler.* "$wowclientdir"
	Copy-Item "${basepath}\src\tools\mmaps_generator\mmaps-config.yaml" "$wowclientdir"
	Set-Location "$wowclientdir"
	Remove-Item -Recurse -Force "$wowclientdir\Buildings" -ErrorAction SilentlyContinue
	Remove-Item -Recurse -Force "$wowclientdir\Cameras" -ErrorAction SilentlyContinue
	Remove-Item -Recurse -Force "$wowclientdir\dbc" -ErrorAction SilentlyContinue
	Remove-Item -Recurse -Force "$wowclientdir\maps" -ErrorAction SilentlyContinue
	Remove-Item -Recurse -Force "$wowclientdir\mmaps" -ErrorAction SilentlyContinue
	Remove-Item -Recurse -Force "$wowclientdir\vmaps" -ErrorAction SilentlyContinue
	New-Item -Path "$wowclientdir\Cameras" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
	New-Item -Path "$wowclientdir\dbc" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
	New-Item -Path "$wowclientdir\maps" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
	New-Item -Path "$wowclientdir\mmaps" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
	New-Item -Path "$wowclientdir\vmaps" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
	Write-Host "Extracting maps/dbc/cameras and vmap buildings in parallel."
	$map  = Start-Process ".\map_extractor.exe"   -ArgumentList "-f","0" -NoNewWindow -PassThru -RedirectStandardOutput "mapextractor.log"   -RedirectStandardError "mapextractor.err"
	$vmap = Start-Process ".\vmap4_extractor.exe" -ArgumentList "-l"     -NoNewWindow -PassThru -RedirectStandardOutput "vmap4extractor.log" -RedirectStandardError "vmap4extractor.err"
	$map, $vmap | Wait-Process
	if ($map.ExitCode -or $vmap.ExitCode) { throw "Extraction failed - check .err logs" }
	Write-Host "Assembling vmaps."
	$asm = Start-Process ".\vmap4_assembler.exe" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "vmap4assembler.log" -RedirectStandardError "vmap4assembler.err"
	if ($asm.ExitCode) { throw "vmap assembly failed" }
	Write-Host "Generating mmaps (longest step)."
	$mm = Start-Process ".\mmaps_generator.exe" -ArgumentList "--silent" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "mmaps_generator.log" -RedirectStandardError "mmaps_generator.err"
	if ($mm.ExitCode) { throw "mmaps generation failed" }
	Write-Host "Done. Mmaps generated."
	robocopy "$wowclientdir\Cameras" "${basepath}\Build\bin\${release}\Data\Cameras" /MIR /W:0 /R:0 /MT:50
	robocopy "$wowclientdir\dbc" "${basepath}\Build\bin\${release}\Data\dbc" /MIR /W:0 /R:0 /MT:50
	robocopy "$wowclientdir\maps" "${basepath}\Build\bin\${release}\Data\maps" /MIR /W:0 /R:0 /MT:50
	robocopy "$wowclientdir\mmaps" "${basepath}\Build\bin\${release}\Data\mmaps" /MIR /W:0 /R:0 /MT:50
	robocopy "$wowclientdir\vmaps" "${basepath}\Build\bin\${release}\Data\vmaps" /MIR /W:0 /R:0 /MT:50
	Remove-Item -Recurse -Force "$wowclientdir\Buildings" -ErrorAction SilentlyContinue
}
if ($checkdistfiles) {
	Write-Host "Checking dist & Conf files..." -ForegroundColor Green
	# Define the top-level directory to start the search
	$startPath = "${basepath}\Build\bin\${release}\configs"

	# Get all *.conf.dist files recursively from the start path
	$allDistFiles = Get-ChildItem -Path $startPath -Filter *.conf.dist -Recurse

	# Loop through every .dist file that was found
	foreach ($distFile in $allDistFiles) {
		Write-Host "Checking File: $($distFile.FullName) with dist file..." -ForegroundColor Magenta

		# Determine the corresponding .conf file path by removing the .dist extension
		$confFile = $distFile.FullName -replace '\.dist$', ''

		# Check if the .conf file already exists
		if (-not (Test-Path $confFile)) {
			# If it doesn't exist, create it by copying the .dist file
			Write-Host "⚠ No .conf file found for $($distFile.Name). Creating copy..." -ForegroundColor Yellow
			Copy-Item -Path $distFile.FullName -Destination $confFile
		} else {
			# If the .conf file exists, compare the line counts
			$distLineCount = (Get-Content -Path $distFile.FullName).Count
			$confLineCount = (Get-Content -Path $confFile).Count

			# If the line counts are not equal, launch KDiff3 for a comparison
			if ($distLineCount -ne $confLineCount) {
				Write-Host "Line count mismatch for $($distFile.Name) ($distLineCount vs $confLineCount). Launching diff tool..." -ForegroundColor Cyan
				
				# Define paths for the backup and the new output file
				$backupFile = $confFile -replace '\.conf$', '.conf.bak'
				$newOutputFile = "$confFile.new"

				# Back up the current .conf file (overwrites existing .bak)
				Write-Host "Backing up current config to $backupFile" -ForegroundColor Gray
				Copy-Item -Path $confFile -Destination $backupFile -Force
				
				# Define the arguments for kdiff3.exe
				#$kdiffArguments = @(
				#	$confFile,
				#	$distFile.FullName,
				#	"-m",                 # Argument to merge
				#	"-o", $newOutputFile  # Argument to specify the output file
				#)
				
				# Run kdiff3.exe and WAIT for the process to exit
				# Start-Process -FilePath "C:\Program Files\KDiff3\bin\kdiff3.exe" -ArgumentList $kdiffArguments -Wait
				Start-Process -FilePath "C:\Program Files\Notepad++\notepad++.exe" -ArgumentList "-nosession -multiInst -pluginMessage=compare", "`"$distFile`"", "`"$confFile`"" -Wait
			
				# After kdiff3 closes, check if an output file was saved
				if (Test-Path $newOutputFile) {
					# If it exists, overwrite the original .conf file with the new one
					Write-Host "Merge saved. Updating $confFile..." -ForegroundColor Green
					Move-Item -Path $newOutputFile -Destination $confFile -Force
				} else {
					# If no output file was saved (e.g., user cancelled), do nothing
					Write-Host "Merge cancelled. Original config file remains unchanged." -ForegroundColor Yellow
				}
			} else {
				 Write-Host "Line counts match. Skipping diff." -ForegroundColor Green
			}
		}
	}
}
if ($startclient) {
	Write-Host "Starting wow client..." -ForegroundColor Green
	Set-Location "$wowclientdir"
	Remove-Item -Recurse -Force cache
	& ".\${wowexe}"
	}
if ($run) {
	Write-Host "Backing up config files..." -ForegroundColor Green
	Set-Location "${basepath}\Build\bin\${release}"
	robocopy "${basepath}\Build\bin\${release}\configs" "J:\Code\Games\wow\servers\common\configs_backup_my" /MIR /W:0 /R:0 /MT:50 
	Write-Host "Running authserver..." -ForegroundColor Green
	Start-Process pwsh.exe -ArgumentList "-NoExit", "-Command", "Set-Location '${basepath}\Build\bin\${release}'; .\authserver.exe"
	#.\authserver.exe
	#sleep 2
	Write-Host "Running worldserver..." -ForegroundColor Green
	Start-Process pwsh.exe -ArgumentList "-NoExit", "-Command", "Set-Location '${basepath}\Build\bin\${release}'; .\worldserver.exe"
	if ($createusers) {
		Write-Host "Creating users..." -ForegroundColor Green
		https://www.azerothcore.org/wiki/gm-commands
		account create Sophee bmw320
		account set Sophee gmlevel 3 -1
		account create ahbot bmw320
	}
}

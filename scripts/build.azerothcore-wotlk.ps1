#https://www.azerothcore.org/wiki/installation
#https://github.com/liyunfan1223/azerothcore-wotlk
#git config --global pager.diff false && git config --global pager.log false && git config --global pager.show false
$debug = $false
$myrepo = $true
$mymodulerepo = $true
$updatecore = $true
$updatemodules = $true
$merge_prs = $true
$prsJsonPath = Join-Path $PSScriptRoot "build.azerothcore-wotlk.prs.json"
$all_prs = @()
$all_prsByPath = @{}
$updateeluna = $false
$updatetools = $false
$release = "RelWithDebInfo"
# Debug, Release, MinSizeRel (minimized size, less common), RelWithDebInfo (release build + debug symbols, what TrinityCore/AzerothCore recommend) 
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
$wowexe = 'WoW.overfear.exe'
$mysqlexe = "C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe"
Set-Location "${basepath}"
Push-Location
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) {
	Write-Host "❌ Error: Visual Studio installation not found. Halting." -ForegroundColor Red
	exit 1
}
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -DevCmdArguments '-arch=x64'
Pop-Location

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
        [string]$remote = "azerothcore"
    )

    Process {
        Write-Host "------------------------------------------------"
        Write-Host "Processing PR #$pr_num..." -ForegroundColor Cyan

        # --- 1. Check PR Status via GitHub API ---
        
        # Use the provided remote (azerothcore, bots, upstream, etc.)
        $repoPath = ""
        try {
            # Get the URL from the git remote (e.g., "https://github.com/azerothcore/azerothcore-wotlk.git")
            $remoteUrl = git remote get-url $remote
            # Extract "azerothcore/azerothcore-wotlk" from the URL
            $repoPath = $remoteUrl -replace ".*github.com[:/](.*?)(\.git)?$", '$1'
        } catch {
            Write-Host "❌ Could not get remote URL for '$remote'. Cannot check PR status." -ForegroundColor Red
            Write-Host "Please ensure the remote '$remote' is configured correctly." -ForegroundColor Gray
            exit 1
        }

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
            $removeChoice = Read-Host "Remove PR #$pr_num from JSON list? (Y/n)"
            if ([string]::IsNullOrWhiteSpace($removeChoice) -or $removeChoice -match '^[Yy]$') {
                Remove-PrFromJson -pr_num $pr_num -remote $remote
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
					if ($LASTEXITCODE -eq 0) {
						Write-Host "✅ Successfully reverted PR #$pr_num." -ForegroundColor Green
						Remove-PrFromJson -pr_num $pr_num -remote $remote
						git push
					} else {
						Write-Host "❌ Failed to revert PR #$pr_num." -ForegroundColor Red
					}
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
			Write-Host "❌ Failed to fetch PR #$pr_num. Skipping." -ForegroundColor Red
			return
		}

		# Merge directly from FETCH_HEAD (no local pr-* branch)
		$mergeOutput = git merge FETCH_HEAD --no-ff --no-commit 2>&1 | Out-String
		#$mergeOutput = git merge FETCH_HEAD --no-ff --no-commit 2>&1 | Tee-Object -Variable mergeOutput | Out-String

        # Check if already up to date
        if ($mergeOutput -match "Already up to date" -or $mergeOutput -match "Already up-to-date") {
            Write-Host "✅ PR #$pr_num is already fully merged (already up to date)." -ForegroundColor Green
            Write-Host "Skipping commit and push."
            Write-Host "------------------------------------------------`n"
            return
        }

        # Check if there are actual conflicts (files with conflict markers)
        $conflictFiles = git diff --name-only --diff-filter=U
        
        if ($conflictFiles) {
            # CONFLICT PATH - there are unresolved conflicts
            Write-Host "🧩 Conflicts detected while merging PR #$pr_num. Please resolve." -ForegroundColor Yellow
            Write-Host "Opening mergetool..."
            git mergetool

            if ($LASTEXITCODE -ne 0) {
                Write-Host "❌ Mergetool failed or was aborted. Halting." -ForegroundColor Red
                exit 1
            }

            # Check again if there are still unresolved conflicts after mergetool
            $conflictFiles = git diff --name-only --diff-filter=U
            if ($conflictFiles) {
                Write-Host "❌ Unresolved conflicts remain in the following files:" -ForegroundColor Red
                $conflictFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
                Write-Host "Please resolve all conflicts before continuing." -ForegroundColor Red
                exit 1
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
            git merge --abort 2>&1 | Out-Null
            Write-Host "Skipping commit and push."
            Write-Host "------------------------------------------------`n"
            return
        }

        # After merge is clean (either no conflicts or conflicts resolved), commit and push
        Write-Host "Staging all changes..."
        git add -A

        Write-Host "Committing the merge..."
        git commit -m "Merge PR #$pr_num for testing"

        if ($LASTEXITCODE -ne 0) {
            Write-Host "❌ Commit failed. Please check manually." -ForegroundColor Red
            exit 1
        }

        Write-Host "✅ Committed PR #$pr_num successfully." -ForegroundColor Green
        git push

        Write-Host "Successfully merged PR #$pr_num."
        Write-Host "------------------------------------------------`n"
    }
}
function Import-PrsJson {
	if (-not (Test-Path $prsJsonPath)) {
		Write-Host "❌ PR JSON file not found at $prsJsonPath" -ForegroundColor Red
		exit 1
	} else {
		Write-Host "✅ PR JSON file loaded from at $prsJsonPath." -ForegroundColor Green
	}
	try {
		$raw = Get-Content -Path $prsJsonPath -Raw
		$parsed = $raw | ConvertFrom-Json
	} catch {
		Write-Host "❌ Failed to parse PR JSON file at $prsJsonPath" -ForegroundColor Red
		Write-Host ($_.Exception.Message | Out-String) -ForegroundColor Gray
		exit 1
	}
	$script:all_prs = @()
	foreach ($entry in $parsed) {
		$prs = @()
		if ($null -ne $entry.PRs) { $prs = @($entry.PRs) }
		$script:all_prs += @{
			Path = [string]$entry.Path
			Remote = [string]$entry.Remote
			PRs = $prs
		}
	}
	$script:all_prsByPath = @{}
	foreach ($group in $script:all_prs) {
		if (-not $script:all_prsByPath.ContainsKey($group.Path)) {
			$script:all_prsByPath[$group.Path] = @{}
		}
		$script:all_prsByPath[$group.Path][$group.Remote] = $group
	}
}

function Save-PrsJson {
	try {
		$all_prs | ConvertTo-Json -Depth 5 | Set-Content -Path $prsJsonPath
	} catch {
		Write-Host "❌ Failed to write PR JSON file at $prsJsonPath" -ForegroundColor Red
		Write-Host ($_.Exception.Message | Out-String) -ForegroundColor Gray
	}
}

function Remove-PrFromJson {
	param (
		[int]$pr_num,
		[string]$remote
	)
	if ($all_prsByPath.Count -eq 0) {
		Import-PrsJson
	}
	$currentDirName = (Get-Location).Path | Split-Path -Leaf
	if (-not $all_prsByPath.ContainsKey($currentDirName)) {
		Write-Host "⚠️ No PR group found for folder $currentDirName in JSON." -ForegroundColor Yellow
		return
	}
	if (-not $all_prsByPath[$currentDirName].ContainsKey($remote)) {
		Write-Host "⚠️ No PR group found for remote $remote in folder $currentDirName." -ForegroundColor Yellow
		return
	}
	$group = $all_prsByPath[$currentDirName][$remote]
	$originalCount = @($group.PRs).Count
	$group.PRs = @($group.PRs | Where-Object { $_ -ne $pr_num })
	if (@($group.PRs).Count -eq $originalCount) {
		Write-Host "ℹ️ PR #$pr_num not found in JSON list for $currentDirName/$remote." -ForegroundColor Gray
		return
	}
	Save-PrsJson
	Write-Host "✅ Removed PR #$pr_num from JSON list for $currentDirName/$remote." -ForegroundColor Green
}

function check_dir_then_merge {
	$currentDirName = (Get-Location).Path | Split-Path -Leaf

	foreach ($prGroup in $all_prs) {
		if ($currentDirName -eq $prGroup.Path) {
			$remote = $prGroup.Remote
			$prs = $prGroup.PRs | Sort-Object
			Write-Host "--- Match found! Folder: $currentDirName (Remote: $remote) ---" -ForegroundColor Cyan
			foreach ($pr in $prs) {
				Merge-PR -pr_num $pr -remote $remote
			}
			Write-Host "✅ All matching PRs processed." -ForegroundColor Cyan
		} else {
			# Write-Host "⏭️ Skipping PR group for $($prGroup.Path) (Current: $currentDirName)" -ForegroundColor Yellow
		}
	}
}

Import-PrsJson

if ($debug) {
	# Write contents of $all_prs after populating it
	Write-Host "`$all_prs contents:" -ForegroundColor Cyan
	if ($all_prs.Count -eq 0) {
		Write-Host "all_prs is empty" -ForegroundColor Red
	} else {
		$all_prs | ConvertTo-Json -Depth 5 | Write-Host
	}
}

if ($updatecore) {
	if ($myrepo) {
		# ==============================
		# 0. Create a branch for testing
		# ==============================
		# make sure my origin/integrate is up to date:
		# git checkout integrate
		# git pull
		# or use update below
		#
		# git checkout -b pr-23233
		# git fetch azerothcore pull/23233/head:pr-23233-temp
		# git merge --no-ff pr-23233-temp -m "Merge azerothcore PR #23233 for testing"
		# git mergetool
		# git branch -d pr-23233-temp
		# git push --set-upstream origin pr-23233
		# git push
		# test and once done, delete:
		# git checkout integrate
		# git branch -D pr-23233

		# ==============================
		# Directly merge a PR
		# ==============================
		# $pr_num = 1813
		#
		## azerothcore:
		## git fetch azerothcore pull/$pr_num/head:pr-$pr_num
		#
		## mod-playerbots:
		## git fetch upstream pull/$pr_num/head:pr-$pr_num
		# 
		# git merge "pr-$pr_num" --no-ff -m "Merge PR #$pr_num from upstream"
		# git mergetool
		# git add -A && git commit --amend --no-edit && git push

		# ==============================
		# Unmerge it
		# ==============================
		# $pr_num = 1912
		# $commit_hash = git log --grep="PR #$pr_num" --merges --format="%H" -n 1
		# $commit_hash
		# git revert -m 1 $commit_hash --no-edit
		# git push

		# ==============================
		# 1. Pre-flight Checks
		# =============================
		
		$my_branch = (git rev-parse --abbrev-ref HEAD).Trim()
		Write-Host "On branch: $my_branch" -ForegroundColor Green

		# Check if on master branch
		if ($my_branch -ne "integrate_with_prs") {
			Write-Host "⚠️  WARNING: You are not on the 'integrate_with_prs' branch!" -ForegroundColor Yellow
			Write-Host "Current branch: $my_branch" -ForegroundColor Yellow
			$choice = Read-Host "Do you want to continue anyway? (y/n)"
			if ($choice -ne 'y') {
				Write-Host "❌ Aborted. Please switch to 'integrate_with_prs' branch and try again." -ForegroundColor Red
				exit 1
			}
			Write-Host "✅ Continuing on branch: $my_branch" -ForegroundColor Green
		}

		Write-Host "🟢 Checking for local changes in my main repo..." -ForegroundColor Cyan

		# Check if the working directory is dirty (has uncommitted changes)
		if (git status --porcelain) {
			Write-Host "❌ Uncommitted changes detected." -ForegroundColor Red
			git status --short
			Write-Host "Staging and committing resolved files..." -ForegroundColor Yellow
			git add -A
			git commit -m "Remediation."
			if ($LASTEXITCODE -ne 0) {
				Write-Host "❌ Commit failed after conflict resolution. Please check manually." -ForegroundColor Red
				exit 1
			}
			git push
		} else {
			Write-Host "✅ Working directory is clean. No local changes." -ForegroundColor Green
		}

		Write-Host "🟢 FYI, the remotes..." -ForegroundColor Green
		git remote -v

		Write-Host "🟢 Fetching all remotes..." -ForegroundColor Cyan
		git fetch --all --prune

		# ==============================
		# 2. Pre-merge Analysis
		# ==============================

		#Write-Host "📊 Comparing commit counts (Playerbot):" -ForegroundColor Yellow
		#git rev-list --left-right --count "origin/$($my_branch)...pbazerothcore/test-staging"
		Write-Host "📈 Whats new in playerbot, that I do not have:" -ForegroundColor Yellow
		git --no-pager diff origin/$($my_branch)...pbazerothcore/test-staging --stat

		#Write-Host "📊 Comparing commit counts (azerothcore):" -ForegroundColor Yellow
		#git rev-list --left-right --count origin/$($my_branch)...azerothcore/master
		Write-Host "📈 Whats new in azerothcore, that I do not have:" -ForegroundColor Yellow
		git --no-pager diff origin/$($my_branch)...azerothcore/master --stat

		# ==============================
		# 3. Merge from Playerbot (Bot fixes + AC changes)
		# ==============================
		Write-Host "🔄 Merging from pbazerothcore/test-staging..." -ForegroundColor Cyan

		git merge --no-ff --no-edit pbazerothcore/test-staging

		if ($LASTEXITCODE -ne 0) {
			Write-Host "🧩 Conflicts detected with pbazerothcore/test-staging. Please resolve." -ForegroundColor Yellow
			Write-Host "Opening mergetool..."
			git mergetool
		
			if ($LASTEXITCODE -ne 0) {
				Write-Host "❌ Mergetool failed or was aborted. Halting." -ForegroundColor Red
				exit 1
			}
			
			# Check if there are still unresolved conflicts
			$conflictFiles = git diff --name-only --diff-filter=U
			if ($conflictFiles) {
				Write-Host "❌ Unresolved conflicts remain in the following files:" -ForegroundColor Red
				$conflictFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
				Write-Host "Please resolve all conflicts before continuing." -ForegroundColor Red
				exit 1
			}
			
			Write-Host "✅ Conflicts resolved successfully." -ForegroundColor Green
		} else {
			Write-Host "✅ Clean merge from pbazerothcore/test-staging." -ForegroundColor Green
		}

		Write-Host "Staging and committing resolved from files pbazerothcore/test-staging...." -ForegroundColor Yellow
		git add -A
		git commit -m "Merge test-staging branch into $($my_branch)"

		# ==============================
		# 4. Merge from AzerothCore (Remaining AC changes)
		# ==============================
		Write-Host "🔄 Merging from azerothcore/master..." -ForegroundColor Cyan

		git merge --no-ff --no-edit azerothcore/master

		if ($LASTEXITCODE -ne 0) {
			Write-Host "🧩 Conflicts detected with azerothcore/master. Please resolve." -ForegroundColor Yellow
			Write-Host "Opening mergetool..."
			git mergetool
			
			if ($LASTEXITCODE -ne 0) {
				Write-Host "❌ Mergetool failed or was aborted. Halting." -ForegroundColor Red
				exit 1
			}
			
			# Check if there are still unresolved conflicts
			$conflictFiles = git diff --name-only --diff-filter=U
			if ($conflictFiles) {
				Write-Host "❌ Unresolved conflicts remain in the following files:" -ForegroundColor Red
				$conflictFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
				Write-Host "Please resolve all conflicts before continuing." -ForegroundColor Red
				exit 1
			}
			
			Write-Host "✅ Conflicts resolved successfully." -ForegroundColor Green
		} else {
			Write-Host "✅ Clean merge from azerothcore/master." -ForegroundColor Green
		}

		Write-Host "Staging and committing resolved files from azerothcore/master..."
		git add -A
		git commit -m "Merge azerothcore/master into $($my_branch)."

		# ==============================
		# 5. Merge PRs
		# ==============================

		if ($merge_prs) {check_dir_then_merge}

		# ==============================
		# 6. Push & Verify
		# ==============================
		Write-Host "🎉 Both upstreams merged successfully. Pushing to origin..." -ForegroundColor Green
		git push

		Write-Host "✅ Verifying synchronization..." -ForegroundColor Green
		#Write-Host "📊 Comparing commit counts (Playerbot):" -ForegroundColor Yellow
		#git rev-list --left-right --count "origin/$($my_branch)...pbazerothcore/test-staging
		Write-Host "📈 Whats new in playerbot, that I do not have:" -ForegroundColor Yellow
		git --no-pager diff origin/$($my_branch)...pbazerothcore/test-staging --stat

		#Write-Host "📊 Comparing commit counts (azerothcore):" -ForegroundColor Yellow
		#git rev-list --left-right --count origin/$($my_branch)...azerothcore/master
		Write-Host "📈 Whats new in azerothcore, that I do not have:" -ForegroundColor Yellow
		git --no-pager diff origin/$($my_branch)...azerothcore/master --stat

		Write-Host "🎉 All merges and sync operations completed successfully!" -ForegroundColor Green

	} else {
		#update from original repo
		#Write-Host "Updating ${basepath}" -ForegroundColor Green
		#git pull --recurse-submodules
		#if ($LASTEXITCODE -ne 0) { Write-Host "❌ Error. Halting."; exit 1 }
		#git submodule update --init --recursive
		#if ($LASTEXITCODE -ne 0) { Write-Host "❌ Error. Halting."; exit 1 }
	}
}
if ($updatemodules) {
	Get-ChildItem -Path "${basepath}\modules\" -Directory | ForEach-Object {
		Push-Location $_.FullName
		$my_branch = (git rev-parse --abbrev-ref HEAD).Trim()
		Write-Host "On branch: $my_branch" -ForegroundColor Green
		if ($mymodulerepo -and $_.FullName -like "*mod-character-services*") {
			# ==============================
			# Update my fork of mod-character-services 
			# ==============================
			Write-Host "Updating my fork of module mod-character-services..." -ForegroundColor Green
			Set-Location "${basepath}\modules\mod-character-services"
			git add -A && git commit -m "Upstream merge" && git push
			git fetch --all --prune
			Write-Host "My differences from badgermilk/main:" -ForegroundColor Green
			git diff badgermilk/main --stat
			Write-Host "My differences from zerkenn/main:" -ForegroundColor Green
			git diff zerkenn/main --stat
			git merge --no-commit --no-ff badgermilk/main  #this updates my files
			if ($LASTEXITCODE -ne 0) {
				git mergetool
				if ($LASTEXITCODE -ne 0) {
					Write-Host "❌ Mergetool failed or was aborted for badgermilk/main. Halting." -ForegroundColor Red
					exit 1
				}
				$conflictFiles = git diff --name-only --diff-filter=U
				if ($conflictFiles) {
					Write-Host "❌ Unresolved conflicts remain. Halting." -ForegroundColor Red
					exit 1
				}
			}
			git merge --no-commit --no-ff zerkenn/main  #this updates my files
			if ($LASTEXITCODE -ne 0) {
				git mergetool
				if ($LASTEXITCODE -ne 0) {
					Write-Host "❌ Mergetool failed or was aborted for zerkenn/main. Halting." -ForegroundColor Red
					exit 1
				}
				$conflictFiles = git diff --name-only --diff-filter=U
				if ($conflictFiles) {
					Write-Host "❌ Unresolved conflicts remain. Halting." -ForegroundColor Red
					exit 1
				}
			}
			if ($merge_prs) {check_dir_then_merge }
			git add -A && git commit -m "Upstream merge." && git push
			Write-Host "My fork of module mod-character-services is now current." -ForegroundColor Green
		}
		elseif ($mymodulerepo -and $_.FullName -like "*mod-playerbots*") {
			# ==============================
			# Update my fork of mod-playerbots
			# ==============================
			Write-Host "Updating my fork of module mod-playerbots..." -ForegroundColor Green
			Set-Location "${basepath}\modules\mod-playerbots"
			git add -A && git commit -m "Upstream merge" && git push
			git fetch --all --prune
			Write-Host "My differences from upstream:" -ForegroundColor Green
			git diff upstream/test-staging --stat
			git merge --no-commit --no-ff upstream/test-staging #this updates my files
			if ($LASTEXITCODE -ne 0) {
				git mergetool
				if ($LASTEXITCODE -ne 0) {
					Write-Host "❌ Mergetool failed or was aborted for upstream/test-staging Halting." -ForegroundColor Red
					exit 1
				}
				$conflictFiles = git diff --name-only --diff-filter=U
				if ($conflictFiles) {
					Write-Host "❌ Unresolved conflicts remain. Halting." -ForegroundColor Red
					exit 1
				}
			}
			if ($merge_prs) {check_dir_then_merge }
			git add -A && git commit -m "Upstream merge." && git push
			Write-Host "My fork of module mod-playerbot is now current." -ForegroundColor Green
			}
		elseif ($mymodulerepo -and $_.Name -eq "mod-ale") {
			# ==============================
			# Update my fork of mod-ale
			# ==============================
			Write-Host "Updating my fork of module mod-ale..." -ForegroundColor Green
			Set-Location "${basepath}\modules\mod-ale"

			$currentBranch = (git branch --show-current).Trim()
			if ($currentBranch -ne "master") {
				Write-Host "❌ mod-ale must be on master; currently on '$currentBranch'." -ForegroundColor Red
				exit 1
			}

			# Commit any existing local changes without failing when there are none.
			git add -A
			git diff --cached --quiet
			if ($LASTEXITCODE -ne 0) {
				git commit -m "Local changes before upstream merge."
				if ($LASTEXITCODE -ne 0) {
					Write-Host "❌ Could not commit existing mod-ale changes." -ForegroundColor Red
					exit 1
				}
			}

			git fetch --all --prune
			if ($LASTEXITCODE -ne 0) {
				Write-Host "❌ Failed to fetch mod-ale remotes." -ForegroundColor Red
				exit 1
			}

			# Incorporate any changes previously pushed to my fork.
			git merge --ff-only origin/master
			if ($LASTEXITCODE -ne 0) {
				Write-Host "❌ Local master and origin/master have diverged. Halting." -ForegroundColor Red
				exit 1
			}

			# Merge AzerothCore first, then Aldori's additional changes.
			foreach ($sourceBranch in @("official/master", "aldori/master")) {
				Write-Host "My differences from ${sourceBranch}:" -ForegroundColor Green
				git diff $sourceBranch --stat

				Write-Host "Merging ${sourceBranch}..." -ForegroundColor Green
				git merge --no-edit --no-ff $sourceBranch

				if ($LASTEXITCODE -ne 0) {
					git mergetool
					if ($LASTEXITCODE -ne 0) {
						Write-Host "❌ Mergetool failed or was aborted for ${sourceBranch}. Halting." -ForegroundColor Red
						exit 1
					}

					$conflictFiles = git diff --name-only --diff-filter=U
					if ($conflictFiles) {
						Write-Host "❌ Unresolved conflicts remain after merging ${sourceBranch}:" -ForegroundColor Red
						$conflictFiles | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
						exit 1
					}

					git add -A
					git commit --no-edit
					if ($LASTEXITCODE -ne 0) {
						Write-Host "❌ Could not complete merge of ${sourceBranch}." -ForegroundColor Red
						exit 1
					}
				}
			}

			if ($merge_prs) {
				check_dir_then_merge
			}

			git push origin master
			if ($LASTEXITCODE -ne 0) {
				Write-Host "❌ Failed to push mod-ale to origin/master." -ForegroundColor Red
				exit 1
			}

			Write-Host "✅ My fork of module mod-ale is now current." -ForegroundColor Green
		}
		else {
			# Continue with existing error handling (applies to all paths)
			Write-Host "Updating module: $($_.Name)" -ForegroundColor Green

			git pull --no-edit --recurse-submodules
			if ($LASTEXITCODE -ne 0) {
				Write-Host "❌ git pull failed." -ForegroundColor Yellow
				$ans = Read-Host "Hard reset to origin/$(git rev-parse --abbrev-ref HEAD)? (y/N)"
				if ($ans -ne 'y') { Write-Host "Aborting."; exit 1 }
					git fetch origin
					git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
				if ($LASTEXITCODE -ne 0) { Write-Host "❌ Reset failed."; exit 1 }
					git pull --no-edit --recurse-submodules
				if ($LASTEXITCODE -ne 0) { Write-Host "❌ Pull failed after reset."; exit 1 }
			}
			git submodule update --init --recursive
			if ($LASTEXITCODE -ne 0) { Write-Host "❌ Submodule update failed."; exit 1 }
			if ($merge_prs) {check_dir_then_merge }
			git add -A && git commit -m "Upstream merge."
			Write-Host "✅ Module updated successfully." -ForegroundColor Green
		}
		Pop-Location
	}
}
if ($updateeluna) {
	Set-Location "J:\Code\Games\wow\eluna"
	Get-ChildItem . -Directory | ForEach-Object {
		Write-Host "Updating Eluna module: $($_.Name)" -ForegroundColor Green
		Push-Location $_.FullName
		git pull --recurse-submodules
		if ($LASTEXITCODE -ne 0) { Write-Host "⚠️ Error updating $($_.Name). Continuing..."; }
		Pop-Location
	}
	Set-Location "${basepath}"
}
if ($updatetools) {
	Set-Location "J:\Code\Games\wow\tools"
	Get-ChildItem . -Directory | ForEach-Object {
		Write-Host "Updating tool: $($_.Name)" -ForegroundColor Green
		Push-Location $_.FullName
		git pull --recurse-submodules
		if ($LASTEXITCODE -ne 0) { Write-Host "⚠️ Error updating $($_.Name). Continuing..."; }
		Pop-Location
	}
	Set-Location "${basepath}"
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

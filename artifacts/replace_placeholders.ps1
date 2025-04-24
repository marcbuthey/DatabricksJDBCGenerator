#Requires -Version 7

param (
	[Parameter()][string] $ReplacementConfigPath,
	[Parameter()][string] $ArtifactInputPath,
	[Parameter()][string] $ArtifactOutputPath,
	[Parameter()][string] $ArtifactBackupPath,
	[Parameter()][string] $EnvironmentName,
	[Parameter()][switch] $Help
)

Remove-Variable * -Exclude ReplacementConfigPath, ArtifactInputPath, ArtifactOutputPath, ArtifactBackupPath, EnvironmentName, Help -ErrorAction SilentlyContinue



function Copy-Folder
{
	param (
		[Parameter()][string] $SourceFolder,
		[Parameter()][string] $TargetFolder,
		[Parameter()][string[]] $ExcludeFolders
	)

	if (!(Test-Path $SourceFolder -PathType Container))
	{
		Write-Error "Source folder '$SourceFolder' not found."
	}
	if (!(Test-Path $TargetFolder -PathType Container))
	{
		Write-Error "Target folder '$TargetFolder' not found."
	}
	
	$ChildItems = Get-ChildItem -Path $SourceFolder -Recurse
	foreach ($Item in $ChildItems)
	{
		# ignore subfolders (but not the included files)
		if ($Item.PSIsContainer -eq $true)
		{
			continue
		}

		# ignore if in $ExcludeFolders
		$IsExcluded = $false
		foreach ($Exclude in $ExcludeFolders)
		{
			if ($Item.FullName.Contains($Exclude))
			{
				$IsExcluded = $true
				break
			}
		}
		if ($IsExcluded -eq $true)
		{
			continue
		}

		# calculate destination path
		$Destination = Join-Path $TargetFolder $Item.FullName.Substring($SourceFolder.length)

		# touch the file to create it within it's subfolder
		New-Item -ItemType File -Path $Destination -Force | out-null

		# actually copy the file
		Copy-Item -Path $Item -Destination $Destination -Force | out-null
	}
}



$ErrorActionPreference = 'stop'
$CurrentFolder = Get-Location
$ScriptName = $MyInvocation.MyCommand.Name
$ExcludeFolders = @()



Write-Host
Write-Host '--------------------------------------------------------------------------------'
Write-Host
Write-Host "Running $ScriptName ..."



# Help
if ($Help.IsPresent)
{
	Write-Host
	Write-Host '--------------------------------------------------------------------------------'
	Write-Host;
	Write-Host 'This script will replace placeholders within the deployment files in the folder'
	Write-Host 'and subfolders of the generator output with values provided by a replacement'
	Write-Host 'configuration file.'
	Write-Host 'Only placeholders in *.sql, *.txt, *.py, *.json, *.ipynb files are replaced.'
	Write-Host;
	Write-Host '--------------------------------------------------------------------------------'
	Write-Host;
	Write-Host 'Parameters:'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-ReplacementConfigPath "<string>"'
	Write-Host 'Specify the path and name for the replacement configuration file.'
	Write-Host 'If parameter is not specified, the current folder is used and a file named'
	Write-Host '"replacement_config.json" is expected.';
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-ArtifactInputPath "<string>"'
	Write-Host 'Specify the path where the deployment files to modify are located.'
	Write-Host 'If parameter is not specified, the current folder is used.'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-ArtifactOutputPath "<string>"'
	Write-Host 'Specify the path where the deployment files should be stored after modification.'
	Write-Host 'If parameter is not specified, the current folder is used and files will be'
	Write-Host 'overwritten.'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-ArtifactBackupPath "<string>"'
	Write-Host 'Specify the path where the backup with the untouched original deployment files'
	Write-Host 'should be stored. For each backup a dedicated subfolder will be created.'
	Write-Host 'If parameter is not specified, no backup will be created.'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-EnvironmentName "<string>"'
	Write-Host 'Specify the environment name for which the replacement configuration should be'
	Write-Host 'applied. This environement must be configured in the configuration file.'
	Write-Host 'If parameter is not specified, the first environment specified in the'
	Write-Host 'replacement configuration file is used.'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-Help'
	Write-Host 'If parameter is used, this help will be displayed.'
	Write-Host;
	Write-Host '--------------------------------------------------------------------------------'
	exit
}



# ReplacementConfigPath
if (-Not [String]::IsNullOrWhiteSpace($ReplacementConfigPath))
{
	$ReplacementConfigPath = [IO.Path]::Combine($CurrentFolder, $ReplacementConfigPath)
}
else
{
	$ReplacementConfigPath = [IO.Path]::Combine($CurrentFolder, 'replacement_config.json')
}
if (!(Test-Path $ReplacementConfigPath -PathType Leaf))
{
	Write-Error "Replacement configuration file '$ReplacementConfigPath' not found."
}
else
{
	Write-Host "-> using replacement configuration file $ReplacementConfigPath"
}



# ArtifactInputPath
if (-Not [String]::IsNullOrWhiteSpace($ArtifactInputPath))
{
	$ArtifactInputPath = [IO.Path]::Combine($CurrentFolder, $ArtifactInputPath)
}
else
{
	$ArtifactInputPath = $CurrentFolder
}
if (!(Test-Path $ArtifactInputPath -PathType Container))
{
	Write-Error "Input folder '$ArtifactInputPath' not found."
}
else
{
	Write-Host "-> using input folder $ArtifactInputPath"
}



# ArtifactOutputPath
if (-Not [String]::IsNullOrWhiteSpace($ArtifactOutputPath))
{
	$ArtifactOutputPath = [IO.Path]::Combine($CurrentFolder, $ArtifactOutputPath)
}
else
{
	$ArtifactOutputPath = $CurrentFolder
}
if (!(Test-Path $ArtifactOutputPath -PathType Container))
{
	Write-Error "Output folder '$ArtifactOutputPath' not found."
}
else
{
	Write-Host "-> using output folder $ArtifactOutputPath"
}



# ArtifactBackupPath
$doBackup = $false
if (-Not [String]::IsNullOrWhiteSpace($ArtifactBackupPath))
{
	$ArtifactBackupPath = [IO.Path]::Combine($CurrentFolder, $ArtifactBackupPath)

	if (!(Test-Path $ArtifactBackupPath -PathType Container))
	{
		Write-Error "Backup folder '$ArtifactBackupPath' not found."
	}

	Write-Host "-> using backup folder $ArtifactBackupPath"
if ($ArtifactInputPath -ne $ArtifactBackupPath)
	{
		$ExcludeFolders += $ArtifactBackupPath
	}
	$doBackup = $true
}
else
{
	Write-Host "-> not creating backup"
}



# EnvironmentName
$ReplacementConfigContent = Get-Content $ReplacementConfigPath | ConvertFrom-Json
$Environments = $ReplacementConfigContent.environments
$EnvironmentIndex = -1
if (-Not [String]::IsNullOrWhiteSpace($EnvironmentName))
{
	$index = 0

	foreach ($Environment in $Environments)
	{
		if ($EnvironmentName -eq $Environment.name)
		{
			$EnvironmentIndex = $index;
			$EnvironmentName = $Environment.name
			break;
		}
		$index++
	}

	if ($EnvironmentIndex -eq -1)
	{
		Write-Error "Environment '$EnvironmentName' not found in replacement configuration file."
	}
}
else {
	$EnvironmentIndex = 0
	$EnvironmentName = $Environments[$EnvironmentIndex].name
}
Write-Host "-> using environment '$EnvironmentName'"



# Copy files to backup folder
if ($doBackup -eq $true)
{
	Write-Host
	Write-Host '--------------------------------------------------------------------------------'
	Write-Host

	# Create new subfolder (Format:yyyyMMddHHmmssfff)
	$ArtifactBackupPath = Join-Path $ArtifactBackupPath $(get-date -Format yyyyMMddHHmmssfff)
	New-Item $ArtifactBackupPath -ItemType Directory | out-null

	Write-Host "Copy backup files to $ArtifactBackupPath"

	# Copy all folders, subfolders and included files to backup folder
	$ExcludeFolders += $ArtifactBackupPath
	$ExcludeFoldersForBackup = $ExcludeFolders
	Copy-Folder -SourceFolder $ArtifactInputPath -TargetFolder $ArtifactBackupPath -ExcludeFolders $ExcludeFoldersForBackup
}



# Copy files to output folder
if ($ArtifactOutputPath -ne $ArtifactInputPath)
{
	Write-Host
	Write-Host '--------------------------------------------------------------------------------'
	Write-Host
	Write-Host "Copy output files to $ArtifactOutputPath"

	# Copy all folders, subfolders and included files to output folder
	$ExcludeFoldersForOutput = $ExcludeFolders
	if ($ArtifactOutputPath -ne $ArtifactInputPath)
	{
		$ExcludeFoldersForOutput += $ArtifactOutputPath
	}
	Copy-Folder -SourceFolder $ArtifactInputPath -TargetFolder $ArtifactOutputPath -ExcludeFolders $ExcludeFoldersForOutput
}



# Process all files in output folder and subfolders
Write-Host
Write-Host '--------------------------------------------------------------------------------'
Write-Host
Write-Host "Processing files in $ArtifactOutputPath ..."

$ExcludeFoldersForProcessing += $ExcludeFolders
$ExcludeFoldersForProcessing += Join-Path $CurrentFolder $ScriptName
$ExcludeFoldersForProcessing += Join-Path $ArtifactOutputPath $ScriptName
$ExcludeFoldersForProcessing += $ReplacementConfigPath
$ExcludeFoldersForProcessing += Join-Path $ArtifactOutputPath "replacement_config.json"

$FileCount = 0

# Loop through all relevant files
$ChildItems = Get-ChildItem $ArtifactOutputPath -Recurse -Include *.sql, *.txt, *.py, *.json, *.ipynb
foreach ($Item in $ChildItems)
{
	# ignore subfolders (but not the included files)
	if ($Item.PSIsContainer -eq $true)
	{
		continue
	}

	# ignore if in $ExcludeFoldersForProcessing
	$IsExcluded = $false
	foreach ($Exclude in $ExcludeFoldersForProcessing)
	{
		if ($Item.FullName.Contains($Exclude))
		{
			$IsExcluded = $true
			break
		}
	}
	if ($IsExcluded -eq $true)
	{
		continue
	}

	Write-Host
	Write-Host "-> working on file $Item"

	$FileContent = Get-Content $Item

	# Replace placeholders in variable $FileContent with concrete values from JSON file
	foreach ($Project in $Environments[$EnvironmentIndex].projects)
	{
		$ProjectName = $Project.name
		Write-Verbose "  -> project $ProjectName"

		foreach ($Variable in $Project.variables)
		{
			$Placeholder = '{' + $Variable.name + '}'

			# get replacement value
			$ReplacementValue = $Variable.value

			# handle empty replacement value
			if ([String]::IsNullOrWhiteSpace($ReplacementValue))
			{
				$ReplacementValue = "~~~replacement_value_skipped~~~" # unconfigured values are marked and later replaced below
			}

			Write-Verbose "    -> search and replace $Placeholder"
			# Replace placeholder with value
			$FileContent = $FileContent -replace $Placeholder, $ReplacementValue

			# Remove empty identifier quotation
			# If a identifier part (like servername) was not configured in the replacement configuration file,
			# it should be removed from the output, together with the quotation and punctuation around it.
			# For example: SQL Server uses square brackets as identifier quotation that must be removed as well.

			$FileContent = $FileContent -replace ([regex]::Escape('[~~~replacement_value_skipped~~~].')), ''
			$FileContent = $FileContent -replace ([regex]::Escape('"~~~replacement_value_skipped~~~".')), ''
			$FileContent = $FileContent -replace ([regex]::Escape('`~~~replacement_value_skipped~~~`.')), ''
			$FileContent = $FileContent -replace ([regex]::Escape('''~~~replacement_value_skipped~~~''.')), ''
			$FileContent = $FileContent -replace ([regex]::Escape('~~~replacement_value_skipped~~~.')), ''
			$FileContent = $FileContent -replace ([regex]::Escape('~~~replacement_value_skipped~~~')), ''
		}
	}

	# write the processed content back to the file
	Set-Content -Path $Item -Value $FileContent
	
	$FileCount++
}

Write-Host
Write-Host '--------------------------------------------------------------------------------'
Write-Host
Write-Host "Finished - $FileCount files processed"

# SIG # Begin signature block
# MII9eAYJKoZIhvcNAQcCoII9aTCCPWUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDvSRWNx3fOj8e4
# 1JLX6PUIqfHPuAxyR4ILjybBBApuXaCCIqYwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbnMIIEz6ADAgECAhMzAAFyxGUw
# MloBvx19AAAAAXLEMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDIwHhcNMjQwOTAzMTMxODMwWhcNMjQwOTA2
# MTMxODMwWjBnMQswCQYDVQQGEwJDSDEZMBcGA1UECBMQQmFzZWwtTGFuZHNjaGFm
# dDERMA8GA1UEBxMIUHJhdHRlbG4xFDASBgNVBAoTC2JpR0VOSVVTIEFHMRQwEgYD
# VQQDEwtiaUdFTklVUyBBRzCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGB
# AK+rgWAzj7DeXe4joieL6L5fPR7jC6CcRnGd+mvNGo7KVtWViD0jLS2uM2HPz1uI
# u6bnsE/bCVB+R1IB3Bxti59IxxW72PgGqpEgX6pHZTWHDKme1iDowso+8W/qjRAu
# zz+3xyuGw76987oB4tXPETsLOLU+C1E0Tg5N+LFsx+zOUUWZFn0Zj5QFHzc3pxyC
# QT9OKjM5d4mbxFm0AL0etfihQoIAq00PhRS90ei+A1HXsGt3lEkRJs3sljEKGKwR
# id6CJcVcqbAFFDrLywgRAysE47u0IcHzomQkuarpSPlVyQAA45rHKBfjEH2G6OEE
# TjwNZitjlFkypReYCS0Eq73r+3cYgXaS+YsCmwwbGJmvZUuJUe5K9sWBxgvr2KB0
# k5CBvq/MQnpgSDMuUwWJEpeafit+Q5yCh9wnKXngf6kQaMHKPK6Sbmb2WB9FkRDX
# Q3XyewA2VM/iVB3TPKA5oQQu2wmWOyUcnN0yucb7k14rQWx+0fRJbEU7ARf9Pz3A
# WQIDAQABo4ICFzCCAhMwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwOgYD
# VR0lBDMwMQYKKwYBBAGCN2EBAAYIKwYBBQUHAwMGGSsGAQQBgjdhgsaA6WLf0W6B
# 6fmZVeSkpA0wHQYDVR0OBBYEFLANWdPM3wDG8wt0v0ogAz22m4JmMB8GA1UdIwQY
# MBaAFCRFmaF3kCp8w8qDsG5kFoQq+CxnMGcGA1UdHwRgMF4wXKBaoFiGVmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIw
# VmVyaWZpZWQlMjBDUyUyMEFPQyUyMENBJTIwMDIuY3JsMIGlBggrBgEFBQcBAQSB
# mDCBlTBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBD
# QSUyMDAyLmNydDAtBggrBgEFBQcwAYYhaHR0cDovL29uZW9jc3AubWljcm9zb2Z0
# LmNvbS9vY3NwMGYGA1UdIARfMF0wUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUH
# AgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0
# b3J5Lmh0bTAIBgZngQwBBAEwDQYJKoZIhvcNAQEMBQADggIBAFsuTuDafaUg4ikh
# eivS6K76TngAQ7G7eI+n5ym0BGTzZ8EZFwptvyrxoHIhHqgfx1fsikyJkuHx0L+0
# ZVrpNKBYQKERxlmuAqIQfcq+rpaLI7xcxElwaKFquUOzV60qRAATyVyEBd5CFL62
# 1yDOreEwvnqNNOHVhu2r73PSrL0NOw90IRo0fSZdpMMpNkWwaWysmJH1nFAZZyDR
# HAiCIXx7goSbK0hb9bK+WfmV+3KUgrtfw/3KdttTl/XXVAlGLS/a9BUWIifYKmAH
# mOUYBrqzZlhe9qCcdMbbrE131q/l7boQZESS8CtbzN45PgWiZPV+r4hWBqIJPcX4
# gHCJNH65miH0sCx7Dm9pc/xO1C1WXWYp/3zJu9O1aJRurf5ZcDdpo79q6tdsqj/7
# Wxm2xewmNxAUZrZOk3qyqwbBHTQkPxaPXGt+aTOgYexib3SeAvuR1ZiYzKe2eXMO
# 84MVehV36mslKv8ghFB29n+JKj7Pg0oOD76lp/NmUoTokYU49Tf1SHOyk8tfU/ng
# hupskJVOCBvjQh2W7M5hJt6qRNzwwbClqeFPtkbk9/TSDtZ1/r3yL9YSF3+UfvoZ
# +bD41LHiL6H8Uy9drZbhXmIPp/7sIN1dLarVdvUpdgPyJUG5OsOpaUiRde6jEZlb
# lIEAGXhZrvmp4sNLwusgS//GT2sjMIIG5zCCBM+gAwIBAgITMwABcsRlMDJaAb8d
# fQAAAAFyxDANBgkqhkiG9w0BAQwFADBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVy
# aWZpZWQgQ1MgQU9DIENBIDAyMB4XDTI0MDkwMzEzMTgzMFoXDTI0MDkwNjEzMTgz
# MFowZzELMAkGA1UEBhMCQ0gxGTAXBgNVBAgTEEJhc2VsLUxhbmRzY2hhZnQxETAP
# BgNVBAcTCFByYXR0ZWxuMRQwEgYDVQQKEwtiaUdFTklVUyBBRzEUMBIGA1UEAxML
# YmlHRU5JVVMgQUcwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCvq4Fg
# M4+w3l3uI6Ini+i+Xz0e4wugnEZxnfprzRqOylbVlYg9Iy0trjNhz89biLum57BP
# 2wlQfkdSAdwcbYufSMcVu9j4BqqRIF+qR2U1hwypntYg6MLKPvFv6o0QLs8/t8cr
# hsO+vfO6AeLVzxE7Czi1PgtRNE4OTfixbMfszlFFmRZ9GY+UBR83N6ccgkE/Tioz
# OXeJm8RZtAC9HrX4oUKCAKtND4UUvdHovgNR17Brd5RJESbN7JYxChisEYnegiXF
# XKmwBRQ6y8sIEQMrBOO7tCHB86JkJLmq6Uj5VckAAOOaxygX4xB9hujhBE48DWYr
# Y5RZMqUXmAktBKu96/t3GIF2kvmLApsMGxiZr2VLiVHuSvbFgcYL69igdJOQgb6v
# zEJ6YEgzLlMFiRKXmn4rfkOcgofcJyl54H+pEGjByjyukm5m9lgfRZEQ10N18nsA
# NlTP4lQd0zygOaEELtsJljslHJzdMrnG+5NeK0FsftH0SWxFOwEX/T89wFkCAwEA
# AaOCAhcwggITMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDoGA1UdJQQz
# MDEGCisGAQQBgjdhAQAGCCsGAQUFBwMDBhkrBgEEAYI3YYLGgOli39Fugen5mVXk
# pKQNMB0GA1UdDgQWBBSwDVnTzN8AxvMLdL9KIAM9tpuCZjAfBgNVHSMEGDAWgBQk
# RZmhd5AqfMPKg7BuZBaEKvgsZzBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDAyLmNybDCBpQYIKwYBBQUHAQEEgZgwgZUw
# ZAYIKwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2Vy
# dHMvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAw
# Mi5jcnQwLQYIKwYBBQUHMAGGIWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20v
# b2NzcDBmBgNVHSAEXzBdMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wCAYGZ4EMAQQBMA0GCSqGSIb3DQEBDAUAA4ICAQBbLk7g2n2lIOIpIXor0uiu
# +k54AEOxu3iPp+cptARk82fBGRcKbb8q8aByIR6oH8dX7IpMiZLh8dC/tGVa6TSg
# WEChEcZZrgKiEH3Kvq6WiyO8XMRJcGiharlDs1etKkQAE8lchAXeQhS+ttcgzq3h
# ML56jTTh1Ybtq+9z0qy9DTsPdCEaNH0mXaTDKTZFsGlsrJiR9ZxQGWcg0RwIgiF8
# e4KEmytIW/Wyvln5lftylIK7X8P9ynbbU5f111QJRi0v2vQVFiIn2CpgB5jlGAa6
# s2ZYXvagnHTG26xNd9av5e26EGREkvArW8zeOT4FomT1fq+IVgaiCT3F+IBwiTR+
# uZoh9LAsew5vaXP8TtQtVl1mKf98ybvTtWiUbq3+WXA3aaO/aurXbKo/+1sZtsXs
# JjcQFGa2TpN6sqsGwR00JD8Wj1xrfmkzoGHsYm90ngL7kdWYmMyntnlzDvODFXoV
# d+prJSr/IIRQdvZ/iSo+z4NKDg++pafzZlKE6JGFOPU39UhzspPLX1P54IbqbJCV
# Tggb40IdluzOYSbeqkTc8MGwpanhT7ZG5Pf00g7Wdf698i/WEhd/lH76Gfmw+NSx
# 4i+h/FMvXa2W4V5iD6f+7CDdXS2q1Xb1KXYD8iVBuTrDqWlIkXXuoxGZW5SBABl4
# Wa75qeLDS8LrIEv/xk9rIzCCB1owggVCoAMCAQICEzMAAAAEllBL0tvuy4gAAAAA
# AAQwDQYJKoZIhvcNAQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVk
# IENvZGUgU2lnbmluZyBQQ0EgMjAyMTAeFw0yMTA0MTMxNzMxNTJaFw0yNjA0MTMx
# NzMxNTJaMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0Eg
# MDIwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDhzqDoM6JjpsA7AI9s
# GVAXa2OjdyRRm5pvlmisydGnis6bBkOJNsinMWRn+TyTiK8ElXXDn9v+jKQj55cC
# pprEx3IA7Qyh2cRbsid9D6tOTKQTMfFFsI2DooOxOdhz9h0vsgiImWLyTnW6locs
# vsJib1g1zRIVi+VoWPY7QeM73L81GZxY2NqZk6VGPFbZxaBSxR1rNIeBEJ6TztXZ
# sz/Xtv6jxZdRb3UimCBFqyaJnrlYQUdcpvKGbYtuEErplaZCgV4T4ZaspYIYr+r/
# hGJNow2Edda9a/7/8jnxS07FWLcNorV9DpgvIggYfMPgKa1ysaK/G6mr9yuse6cY
# 0Hv/9Ca6XZk/0dw6Zj9qm2BSfBP7bSD8DfuIN+65XDrJLYujT+Sn+Nv4ny8TgUyo
# iLDEYHIvjzY8xUELep381sVBrwyaPp6exT4cSq/1qv4BtwrC6ZtmokkqZCsZpI11
# Z+TY2h2BxY6aruPKFvHBk6OcuPT9vCexQ1w0B7T2/6qKjPJBB6zwDdRc9xFBvwb5
# zTJo7YgKJ9ZMrvJK7JQnzyTWa03bYI1+1uOK2IB5p+hn1WaGflF9v5L8rlqtW9Nw
# u6S3k91MNDGXnnsQgToD7pcUGl2yM7OQvN0SHsQuTw9U8yNB88KAq0nzhzXt93YL
# 36nEXWURBQVdj9i0Iv42az1xZQIDAQABo4ICDjCCAgowDgYDVR0PAQH/BAQDAgGG
# MBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBQkRZmhd5AqfMPKg7BuZBaEKvgs
# ZzBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgw
# FoAU2UEpsA8PY2zvadf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBW
# ZXJpZmllZCUyMENvZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwga4GCCsG
# AQUFBwEBBIGhMIGeMG0GCCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2Rl
# JTIwU2lnbmluZyUyMFBDQSUyMDIwMjEuY3J0MC0GCCsGAQUFBzABhiFodHRwOi8v
# b25lb2NzcC5taWNyb3NvZnQuY29tL29jc3AwDQYJKoZIhvcNAQEMBQADggIBAGct
# OF2Vsw0iiR0q3NJryKj6kQ73kJzdU7Jj+FCwghx0zKTaEk7Mu38zVZd9DISUOT9C
# 3IvNfrdN05vkn6c7y3SnPPCLtli8yI2oq8BA7nSww4mfdPeEI+mnE02GgYVXHPZT
# KJDhva86tywsr1M4QVdZtQwk5tH08zTBmwAEiG7iTpVUvEQN7QZJ5Bf9kTs8d9OD
# jgu5+3ggqpiae/UK6iyneCUVixV6AucxZlRnxS070XxAKICi4liEvk6UKSyANv29
# 78dCEsWd6V+Dp1C5sgWyoH0iUKidgoln8doxm9i0DvL0Q5ErhzGW9N60JcAdrKJJ
# cfS54T9P3bBUbRyy/lV1TKPrJWubba+UpgCRcg0q8M4Hz6ziH5OBKGVRrYAK7YVa
# fsnOVNJumTQgTxES5iaS7IT8FOST3dYMzHs/Auefgn7l+S9uONDTw57B+kyGHxK4
# 91AqqZnjQjhbZTIkowxNt63XokWKZKoMKGCcIHqXCWl7SB9uj3tTumult8EqnoHa
# TZ/tj5ONatBg3451w87JAB3EYY8HAlJokbeiF2SULGAAnlqcLF5iXtKNDkS5rpq2
# Mh5WE3Qp88sU+ljPkJBT4kLYfv3Hh387pg4VH1ph7nj8Ia6nt1FQh8tK/X+PQM9z
# oSV/djJbGWhaPzJ5jeQetkVoCVEzCEBfI9DesRf3MIIHnjCCBYagAwIBAgITMwAA
# AAeHozSje6WOHAAAAAAABzANBgkqhkiG9w0BAQwFADB3MQswCQYDVQQGEwJVUzEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMUgwRgYDVQQDEz9NaWNyb3Nv
# ZnQgSWRlbnRpdHkgVmVyaWZpY2F0aW9uIFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9y
# aXR5IDIwMjAwHhcNMjEwNDAxMjAwNTIwWhcNMzYwNDAxMjAxNTIwWjBjMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTQwMgYDVQQD
# EytNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ29kZSBTaWduaW5nIFBDQSAyMDIxMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsvDArxmIKOLdVHpMSWxpCFUJ
# tFL/ekr4weslKPdnF3cpTeuV8veqtmKVgok2rO0D05BpyvUDCg1wdsoEtuxACEGc
# gHfjPF/nZsOkg7c0mV8hpMT/GvB4uhDvWXMIeQPsDgCzUGzTvoi76YDpxDOxhgf8
# JuXWJzBDoLrmtThX01CE1TCCvH2sZD/+Hz3RDwl2MsvDSdX5rJDYVuR3bjaj2Qfz
# ZFmwfccTKqMAHlrz4B7ac8g9zyxlTpkTuJGtFnLBGasoOnn5NyYlf0xF9/bjVRo4
# Gzg2Yc7KR7yhTVNiuTGH5h4eB9ajm1OCShIyhrKqgOkc4smz6obxO+HxKeJ9bYmP
# f6KLXVNLz8UaeARo0BatvJ82sLr2gqlFBdj1sYfqOf00Qm/3B4XGFPDK/H04kteZ
# EZsBRc3VT2d/iVd7OTLpSH9yCORV3oIZQB/Qr4nD4YT/lWkhVtw2v2s0TnRJubL/
# hFMIQa86rcaGMhNsJrhysLNNMeBhiMezU1s5zpusf54qlYu2v5sZ5zL0KvBDLHtL
# 8F9gn6jOy3v7Jm0bbBHjrW5yQW7S36ALAt03QDpwW1JG1Hxu/FUXJbBO2AwwVG4F
# re+ZQ5Od8ouwt59FpBxVOBGfN4vN2m3fZx1gqn52GvaiBz6ozorgIEjn+PhUXILh
# AV5Q/ZgCJ0u2+ldFGjcCAwEAAaOCAjUwggIxMA4GA1UdDwEB/wQEAwIBhjAQBgkr
# BgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQU2UEpsA8PY2zvadf1zSmepEhqMOYwVAYD
# VR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIE
# DB4KAFMAdQBiAEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFMh+0mqF
# KhvKGZgEByfPUBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZl
# cmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIw
# MjAuY3JsMIHDBggrBgEFBQcBAQSBtjCBszCBgQYIKwYBBQUHMAKGdWh0dHA6Ly93
# d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSWRlbnRp
# dHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3Jp
# dHklMjAyMDIwLmNydDAtBggrBgEFBQcwAYYhaHR0cDovL29uZW9jc3AubWljcm9z
# b2Z0LmNvbS9vY3NwMA0GCSqGSIb3DQEBDAUAA4ICAQB/JSqe/tSr6t1mCttXI0y6
# XmyQ41uGWzl9xw+WYhvOL47BV09Dgfnm/tU4ieeZ7NAR5bguorTCNr58HOcA1tcs
# HQqt0wJsdClsu8bpQD9e/al+lUgTUJEV80Xhco7xdgRrehbyhUf4pkeAhBEjABvI
# UpD2LKPho5Z4DPCT5/0TlK02nlPwUbv9URREhVYCtsDM+31OFU3fDV8BmQXv5hT2
# RurVsJHZgP4y26dJDVF+3pcbtvh7R6NEDuYHYihfmE2HdQRq5jRvLE1Eb59PYwIS
# FCX2DaLZ+zpU4bX0I16ntKq4poGOFaaKtjIA1vRElItaOKcwtc04CBrXSfyL2Op6
# mvNIxTk4OaswIkTXbFL81ZKGD+24uMCwo/pLNhn7VHLfnxlMVzHQVL+bHa9KhTyz
# wdG/L6uderJQn0cGpLQMStUuNDArxW2wF16QGZ1NtBWgKA8Kqv48M8HfFqNifN6+
# zt6J0GwzvU8g0rYGgTZR8zDEIJfeZxwWDHpSxB5FJ1VVU1LIAtB7o9PXbjXzGifa
# IMYTzU4YKt4vMNwwBmetQDHhdAtTPplOXrnI9SI6HeTtjDD3iUN/7ygbahmYOHk7
# VB7fwT4ze+ErCbMh6gHV1UuXPiLciloNxH6K4aMfZN1oLVk6YFeIJEokuPgNPa6E
# nTiOL60cPqfny+Fq8UiuZzGCGigwghokAgEBMHEwWjELMAkGA1UEBhMCVVMxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjErMCkGA1UEAxMiTWljcm9zb2Z0
# IElEIFZlcmlmaWVkIENTIEFPQyBDQSAwMgITMwABcsRlMDJaAb8dfQAAAAFyxDAN
# BglghkgBZQMEAgEFAKBeMBAGCisGAQQBgjcCAQwxAjAAMBkGCSqGSIb3DQEJAzEM
# BgorBgEEAYI3AgEEMC8GCSqGSIb3DQEJBDEiBCD/zi+eEsi1MT+Onzllb20XzRZW
# p5cHLWJAqdiZYJ1A+jANBgkqhkiG9w0BAQEFAASCAYB88uDqrxzhVULInxjcIsPw
# AiOlgiVqQkbM+IFxuWF5hogZ0HGywyCxcUpgDy75uVaHjRF0VVqz1iazK7uIIbtA
# gEYLUVhnDb0D3OJXn2Z9mHgvSjNnTuk/xhATvJk70VZ/RQ89hUYxsfqzW2Yfet8U
# kfr+Gg+8huG0C0KldUo6pRb/Dh99yev0okbwo9ZSlKkWZYZ8DtYJks0GmX+R1WCP
# GGQrm8fJ4XH6J7X0PSmWaDY7DEOHJnFJ57fafKXncVThFPpivLuEKMIUwAPTLLwU
# jaD2+EhIaVTiQMhwReQ3+M2WzCU/tIJM6D0/50mB9tTSLIXDLx9PrZjGwlLqVaYo
# fhURTB42Pvj4V4PQrv0YunCFGyG3E1Bh42tn2Y8iEUFrlFDYcMXAUhgqDO7dQ3d4
# vowunoPeu0WNYFp+XsJBcgHpWPLJUQMer+IMn1OmYGD826zfk5IPnPmjrteeYF6O
# R7YjrquIsg0mFPbTw4QBr2CRbPZ0gxxcKNEl6PAjV56hgheoMIIXpAYKKwYBBAGC
# NwMDATGCF5QwgheQBgkqhkiG9w0BBwKggheBMIIXfQIBAzEPMA0GCWCGSAFlAwQC
# AQUAMIIBaQYLKoZIhvcNAQkQAQSgggFYBIIBVDCCAVACAQEGCisGAQQBhFkKAwEw
# MTANBglghkgBZQMEAgEFAAQge/8HUoXHKiHWVECL5sX1oSfpGYy+NJ3idQc4WYy+
# 3YECBmbHIoY9YhgTMjAyNDA5MDMxODE4NDQuNjA0WjAEgAIB9KCB6KSB5TCB4jEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEtMCsGA1UECxMkTWlj
# cm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMSYwJAYDVQQLEx1UaGFs
# ZXMgVFNTIEVTTjo0RTg5LTk2NjYtRkZFNzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1
# YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHmggg8oMIIHgjCCBWqgAwIB
# AgITMwAAAAXlzw//Zi7JhwAAAAAABTANBgkqhkiG9w0BAQwFADB3MQswCQYDVQQG
# EwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMUgwRgYDVQQDEz9N
# aWNyb3NvZnQgSWRlbnRpdHkgVmVyaWZpY2F0aW9uIFJvb3QgQ2VydGlmaWNhdGUg
# QXV0aG9yaXR5IDIwMjAwHhcNMjAxMTE5MjAzMjMxWhcNMzUxMTE5MjA0MjMxWjBh
# MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAy
# MDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ5851Jj/eDFnwV9Y7UG
# IqMcHtfnlzPREwW9ZUZHd5HBXXBvf7KrQ5cMSqFSHGqg2/qJhYqOQxwuEQXG8kB4
# 1wsDJP5d0zmLYKAY8Zxv3lYkuLDsfMuIEqvGYOPURAH+Ybl4SJEESnt0MbPEoKdN
# ihwM5xGv0rGofJ1qOYSTNcc55EbBT7uq3wx3mXhtVmtcCEr5ZKTkKKE1CxZvNPWd
# GWJUPC6e4uRfWHIhZcgCsJ+sozf5EeH5KrlFnxpjKKTavwfFP6XaGZGWUG8TZaiT
# ogRoAlqcevbiqioUz1Yt4FRK53P6ovnUfANjIgM9JDdJ4e0qiDRm5sOTiEQtBLGd
# 9Vhd1MadxoGcHrRCsS5rO9yhv2fjJHrmlQ0EIXmp4DhDBieKUGR+eZ4CNE3ctW4u
# vSDQVeSp9h1SaPV8UWEfyTxgGjOsRpeexIveR1MPTVf7gt8hY64XNPO6iyUGsEgt
# 8c2PxF87E+CO7A28TpjNq5eLiiunhKbq0XbjkNoU5JhtYUrlmAbpxRjb9tSreDdt
# ACpm3rkpxp7AQndnI0Shu/fk1/rE3oWsDqMX3jjv40e8KN5YsJBnczyWB4JyeeFM
# W3JBfdeAKhzohFe8U5w9WuvcP1E8cIxLoKSDzCCBOu0hWdjzKNu8Y5SwB1lt5dQh
# ABYyzR3dxEO/T1K/BVF3rV69AgMBAAGjggIbMIICFzAOBgNVHQ8BAf8EBAMCAYYw
# EAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFGtpKDo1L0hjQM972K9J6T7ZPdsh
# MFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAww
# CgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwDwYDVR0TAQH/
# BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2ioojCBhAYDVR0f
# BH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2Vy
# dGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBlAYIKwYBBQUHAQEEgYcw
# gYQwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3Bz
# L2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9v
# dCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQwDQYJKoZIhvcN
# AQEMBQADggIBAF+Idsd+bbVaFXXnTHho+k7h2ESZJRWluLE0Oa/pO+4ge/XEizXv
# hs0Y7+KVYyb4nHlugBesnFqBGEdC2IWmtKMyS1OWIviwpnK3aL5JedwzbeBF7POy
# g6IGG/XhhJ3UqWeWTO+Czb1c2NP5zyEh89F72u9UIw+IfvM9lzDmc2O2END7MPnr
# cjWdQnrLn1Ntday7JSyrDvBdmgbNnCKNZPmhzoa8PccOiQljjTW6GePe5sGFuRHz
# dFt8y+bN2neF7Zu8hTO1I64XNGqst8S+w+RUdie8fXC1jKu3m9KGIqF4aldrYBam
# yh3g4nJPj/LR2CBaLyD+2BuGZCVmoNR/dSpRCxlot0i79dKOChmoONqbMI8m04uL
# aEHAv4qwKHQ1vBzbV/nG89LDKbRSSvijmwJwxRxLLpMQ/u4xXxFfR4f/gksSkbJp
# 7oqLwliDm/h+w0aJ/U5ccnYhYb7vPKNMN+SZDWycU5ODIRfyoGl59BsXR/HpRGti
# JquOYGmvA/pk5vC1lcnbeMrcWD/26ozePQ/TWfNXKBOmkFpvPE8CH+EeGGWzqTCj
# dAsno2jzTeNSxlx3glDGJgcdz5D/AAxw9Sdgq/+rY7jjgs7X6fqPTXPmaCAJKVHA
# P19oEjJIBwD1LyHbaEgBxFCogYSOiUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHnjCC
# BYagAwIBAgITMwAAAEF2EbJNqqmrPwAAAAAAQTANBgkqhkiG9w0BAQwFADBhMQsw
# CQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYD
# VQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAe
# Fw0yNDA0MTgxNzU5MTVaFw0yNTA0MTcxNzU5MTVaMIHiMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOjRF
# ODktOTY2Ni1GRkU3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# IFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBANnQDX7XfgF+vmOg2hU5bVrbGY/59ZKqnvgVHqwS3g8Jjx5snov8HM3d4CC4
# KZFbfMjDnPDuxFPTtuYcrtFkky+e3X4cVa7bjNEhiRwT4G11eBO7ng93ccm8/Xee
# dEpGMPbSNPIibys9DHow73CcARnoH6hOVUVS61f4l15Xh5JSXnI7FirIVbnYSciF
# RZjB91BjQCofrd12ZjSowYbK9w6ZZVCMK7kTOOaqapGAF4tYCnaZb+Jpa6oBgv//
# QWSFPWUhcVxJdR8gAZVCGTc/6Ug2VOwVLtqFoHsUPj01a2Nz9Nj/1myPYVCEoh7W
# QjEmtJKZE5XGvzqr181zQNZYyoaxGjKcM1+/+Ew/eFuOgVsxPDrnzK5Bbpce3poz
# Rmlr1dZ8FZJh7lfwScmczT/PhfHn9jIsSV37618har/dNck2B/gtbOTWeJZoLoBh
# Zrp2ar/inzcKsQeLXT1qQmhcVaWOIMBy1jM1zGioFkkaxPFi+TlfaWQVPayrLC3r
# wVFarqndtkhsPLmJzSVzrtYbomBhWpgHUWztxXi2i30t5Ft4NLR7FVCuukw/ogVn
# OwY7BZNBxfue06gOZWlCtqsfsv8fKuOzQ9fytXHnFLLpYb05YN9BBQ7zbN5o9Mxt
# /zw/tTxi6KGpLO1LXg+NXtkQeVsCb9SsT5R24wgnsuM4M0ifAgMBAAGjggHLMIIB
# xzAdBgNVHQ4EFgQUJfHwo+kTcpYxJPeJ3GIeJ4CYyIowHwYDVR0jBBgwFoAUa2ko
# OjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBhoF+gXYZbaHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNB
# JTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNybDB5BggrBgEFBQcBAQRtMGsw
# aQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2Vy
# dHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0El
# MjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEGDCsGAQQBgjdMg30BATBBMD8G
# CCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3Mv
# UmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqGSIb3DQEBDAUAA4ICAQBeJyJn
# AuTqA2fMbfPWaYTZkJyZdJ7+luhIw5TzBkH7WhPU9M9eHoc9cm1qOJL/AkL/m7kn
# s7Ei2M0uWGndiSKoYz0EOuFCPT/wdtNFnxdvpb9A5RJAAJAU2Vj5kj4MivwSOtFe
# ZbJMXBSAD9OxEwq/TSAK2t0IrI4OsYBVpmPGX1z9On6FVwaCCBFG7+5X4+3Y0SFR
# 8tvsZXx7qZqThdntxlC4HCYuEDSgDftSmKDwqkmfxZLggZuF+xV8t/7sTOjWsVK3
# evkiu4uWdRhlGzRtzXa9B+wVHzx9kCE1w/2KF+B5W8IE70kJXxUn1ZH2MIQK5OAu
# ZsLeeHn/RfOOMh2cF+DEQbNNcYA8iFzmrC+rkGhXmmLpcv3H4RC5mlV0pEw0Fl33
# kZx3fYOS9xq7T1XN1RDWfuj4zKWKEj6MYFCIUEszHsRgSlUoIepbLkoceWJcbySB
# JbTkiK5xzT+swFIumiEXKCp2X98fj/35x2TMt/zu03m1xyjdbF0W7WuleXzZNT27
# 07k6fYujcJBcjA0F1oPSUDQtfZgT8ZuxzjbSBVJ+26Es5kjWCR1qNwpDwxVYCI80
# TnQmdaNk7qXnqcryQ36h7I52k5AzgdLYvwqeDIzOtKCHh03wUwQj7Q+0HwlKt7z9
# uwKExhKcwG8HkGJbYxW00ypErCGbaTRh6y3ThDGCBswwggbIAgEBMHgwYTELMAkG
# A1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UE
# AxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENBIDIwMjACEzMA
# AABBdhGyTaqpqz8AAAAAAEEwDQYJYIZIAWUDBAIBBQCgggQlMBEGCyqGSIb3DQEJ
# EAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwHAYJKoZIhvcNAQkF
# MQ8XDTI0MDkwMzE4MTg0NFowLwYJKoZIhvcNAQkEMSIEIK6VDFR5tBodEYLaxV8o
# Z0x2ZOSkfKuEfZYejxPAuKMqMIG5BgsqhkiG9w0BCRACLzGBqTCBpjCBozCBoAQg
# zYyv3iKy9GAmWwU3uRFfX4XFhdM/QUANop3sUSKvDZswfDBlpGMwYTELMAkGA1UE
# BhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMp
# TWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENBIDIwMjACEzMAAABB
# dhGyTaqpqz8AAAAAAEEwggLnBgsqhkiG9w0BCRACEjGCAtYwggLSoYICzjCCAsow
# ggIzAgEBMIIBEKGB6KSB5TCB4jELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBM
# aW1pdGVkMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjo0RTg5LTk2NjYtRkZFNzE1
# MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRo
# b3JpdHmiIwoBATAHBgUrDgMCGgMVAOLFr7AvgDRUWdGSNOLtRTA3WMSCoGcwZaRj
# MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# MjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAy
# MDIwMA0GCSqGSIb3DQEBBQUAAgUA6oFzBTAiGA8yMDI0MDkwMzExMzUzM1oYDzIw
# MjQwOTA0MTEzNTMzWjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDqgXMFAgEAMAoC
# AQACAiIwAgH/MAcCAQACAhETMAoCBQDqgsSFAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQEFBQADgYEAefVs+uybkU43Sujz6v/h7fGIl74kmPlb3LZp4FinBzexMR68/La4
# pkhCn1o6q+5Z9EXaxvISaQOWBfNA1UX3BH6WgByxBkaHPX3DTe2BvDjDSb9QuOR6
# vBf1QLKFPmh6iAHuEultcghoRGDsWMj+UEu+FyO552OcrnApmvjRSqQwDQYJKoZI
# hvcNAQEBBQAEggIAd5Fwth7Ao3YqRlVisUEbJNM5B2AMVCdSt+WK/B/HMbffceco
# gvlTtvNTI8HhaN7Lom6x+Sg3ILo67QmkuZHfKlOJolmjt/7l1yKuh5cCmFsAFDcG
# nAuP6W+ce2N3Lz26MuVQBEqQJUXrD5nRSsmtjh2lll6MmDQUFL5L7PxgWOImz7GA
# aX7Pqfw0RdnKQFt8jrQLtBHgR0ygjFNOKAyb8011QpDUCxi9Us2cmFzYBukWJjrE
# w/Yc1u7DKm/UnMgMtyEx/krRthO771fyDw1OKUnTa8rXgIW6mWH+K9FADpFMe51s
# 6xslRR0Fq3smA41C/y9AAmvlP8mkaJw/cOWanIMaT0Naj02XixQaPMS7DQFbY+tx
# qZOaGuT7mgUhSZ5kV68hb6r+bERVDftGY40ZWujcoQJw3bu94xQaJ++1KDELFNzD
# dsU/6s+mphwB0QDYf9GYSQk551ahzPVQLCltcQCYpggXBAabohTE9fRZFNsjZwdd
# n1Gej/3adit7XgUPpHq5RHCheNUWR6iQG+kl/9nLB4PNWHEU6FZVn8dWzm+HfnAw
# rnKAu9d35kpHwr2dAEyHL+gxYAeAruE2AjySAx0Fed6kTl58ABIGVbJmNDyYpUk9
# GUz3TwMZfZI379esiHzYwhKmTZYua8k6EmGS9/OcauBGsqvzM5K1xbLUw2c=
# SIG # End signature block

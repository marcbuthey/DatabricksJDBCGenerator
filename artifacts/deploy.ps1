#Requires -Version 7

param (
    [Parameter()][string] $ProfileName,
    [Parameter()][string] $WorkspacePath,
    [Parameter()][string] $ClusterName,
    [Parameter()][string] $ArtifactInputPath,
    [Parameter()][switch] $SkipDeployment,
    [Parameter()][switch] $Help
)

Remove-Variable * -Exclude ProfileName, WorkspacePath, ClusterName, ArtifactInputPath, SkipDeployment, Help -ErrorAction SilentlyContinue

$deploymentNotebookName = "_Deployment" # name of the deployment notebook



# Check if Databricks CLI is installed
try
{
    $null = databricks -v # trivial command to check if databricks CLI is installed
}
catch
{
    # Output an error message if the command fails
    Write-Error "Databricks CLI is not installed, not recognized or the PATH environment variable is not properly configured. To install it you can use: winget install Databricks.DatabricksCLI"
}



function Get-Notebooks
{
    param (
        [string]$WorkspacePath,
        [string]$ProfileName
    )
    
    # prepare list of notebooks
    $notebooks = @()

    # get items in the current path
    $itemsResponse = databricks workspace list $WorkspacePath --output json --profile $ProfileName | ConvertFrom-Json

    # find notebook in current path
    foreach ($item in $itemsResponse)
    {
        # add to list of notebooks
        if ($item.object_type -eq "NOTEBOOK")
        {
            $notebooks += $item
        }
        # recursively handle items in subfolders
        elseif ($item.object_type -eq "DIRECTORY")
        {
            $notebooks += Get-Notebooks -WorkspacePath $item.path -ProfileName $ProfileName
        }
    }

    # return list of notebooks
    return $notebooks
}



$CurrentFolder = Get-Location
$ScriptName = $MyInvocation.MyCommand.Name



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
	Write-Host 'This script will run the deploy.sql script in the generator output on a'
	Write-Host 'Databricks instance.'
	Write-Host;
	Write-Host '--------------------------------------------------------------------------------'
	Write-Host;
	Write-Host 'Parameters:'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-ProfileName "<string>"'
	Write-Host 'Specify the Databricks CLI connection profile that will be used to connect.'
    Write-Host 'If parameter is not specified, a prompt will appear.'
    Write-Host 'If specified profile does not yet exist, the script will prompt to create it.'
    Write-Host 'If specified profile is not yet logged in, the script will prompt to log in.'
    Write-Host 'To setup the connection profile in advance you can use the Databricks CLI:'
    Write-Host -ForegroundColor DarkYellow 'databricks configure --profile <profileName> <--token>'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-WorkspacePath "<string>"'
	Write-Host 'Specify the relative path to the workspace where the deployment files should be'
    Write-Host 'executed.'
	Write-Host 'If parameter is not specified, a prompt will appear.'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-ClusterName "<string>"'
	Write-Host 'Specify the compute cluster where the deployment notebook should be executed.'
	Write-Host 'If parameter is not specified, a prompt will appear.'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-ArtifactInputPath "<string>"'
	Write-Host 'Specify the path where the deployment files to execute are located.'
	Write-Host 'If parameter is not specified, the current folder is used.'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-SkipDeployment'
	Write-Host 'If parameter is used, the deployment notebook will not run after the upload and'
    Write-Host 'must be executed manually.'
	Write-Host;
	Write-Host -ForegroundColor DarkGreen '-Help'
	Write-Host 'If parameter is used, this help will be displayed.'
	Write-Host;
	Write-Host '--------------------------------------------------------------------------------'
	exit
}



# ProfileName
if ($PSBoundParameters.ContainsKey('ProfileName') -eq $false)
{
	$ProfileName = Read-Host "Please specify the profile name"
}
Write-Host "-> using profile $ProfileName"



# WorkspaceName
if ($PSBoundParameters.ContainsKey('WorkspacePath') -eq $false)
{
	$WorkspacePath = Read-Host "Please specify the workspace path"
}
$WorkspacePath = $WorkspacePath.Replace("\", "/").TrimEnd("/")
Write-Host "-> using workspace $WorkspacePath"



# ClusterName
if (-not $SkipDeployment.IsPresent)
{
    if ($PSBoundParameters.ContainsKey('ClusterName') -eq $false)
    {
        $ClusterName = Read-Host "Please specify the cluster name"
    }
    Write-Host "-> using cluster $ClusterName"
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
	exit
}
else
{
	Write-Host "-> using input folder $ArtifactInputPath"
}



Write-Host
Write-Host '--------------------------------------------------------------------------------'



# check profile
$databricksProfiles = databricks auth profiles # get list of profiles and authentication status
if ($databricksProfiles -match $ProfileName) # check if profile exists
{
    if ($databricksProfiles -match "$ProfileName\s+\S+\s+YES") # check if profile is authenticated
    {
        # profile authenticated
        Write-Host "-> profile '$ProfileName' authenticated"
    }
    else
    {
        # profile not authenticated
        Write-Host "-> profile '$ProfileName' not authenticated - logging in using browser authentification"
        databricks auth login --profile $ProfileName
    }
}
else
{
    # profile not found
    Write-Host "-> profile '$ProfileName' not found - creating new profile using browser authentification"
    databricks auth login --profile $ProfileName
}



# check workspace
try
{
    $null = databricks workspace get-status "$WorkspacePath" --profile $ProfileName # trivial command to check if workspace exists
    Write-Host "Workspace $WorkspacePath found"
}
catch
{
    Write-Error "Workspace $WorkspacePath not found"
    exit
}



if (-not $SkipDeployment.IsPresent)
{
    # get clusters
    $clustersResponse = databricks clusters list --output json --profile $ProfileName | ConvertFrom-Json

    # find cluster
    $clusterId = $null
    foreach ($cluster in $clustersResponse)
    {
        if ($cluster.cluster_name -eq $ClusterName)
        {
            $clusterId = $cluster.cluster_id
            break
        }
    }
    if ($clusterId)
    {
        Write-Host "Cluster $ClusterName found with id $clusterId"
    }
    else
    {
        Write-Error "Cluster $ClusterName not found"
        exit
    }
}



# get notebooks to upload
$uploadItems = Get-ChildItem -Path "$ArtifactInputPath\*" -Include "*.ipynb" -Recurse

# loop notebooks to upload
foreach ($uploadItem in $uploadItems)
{
    # get source path
    $sourcePath = $uploadItem.FullName

    # get upload file
    $uploadFile = "/" # add leading forward slash
    $uploadFile += $uploadItem.BaseName # without file extension

    # get upload folder
    $uploadFolder = "/" # add leading forward slash
    $uploadFolder += [IO.Path]::GetRelativePath($ArtifactInputPath, $uploadItem.Directory.FullName).Replace('\', '/') # relative path
    $uploadFolder = $uploadFolder.TrimEnd("/") # remove trailing forward slash (e.g. in the root folder)

    # get upload path
    $uploadPath = $WorkspacePath + $uploadFolder

    # upload notebook
    Write-Host "Uploading notebook $sourcePath to $uploadPath$uploadFile"
    databricks workspace mkdirs $uploadPath --profile $ProfileName
    databricks workspace import $uploadPath$uploadFile --file $sourcePath --format JUPYTER --overwrite --profile $ProfileName
}



if (-not $SkipDeployment.IsPresent)
{

    # get notebooks
    $notebooks = Get-Notebooks -WorkspacePath $WorkspacePath -ProfileName $ProfileName

    # find deployment notebook
    $notebookPath = $null
    foreach ($notebook in $notebooks)
    {
        if ($notebook.path.EndsWith($deploymentNotebookName))
        {
            $notebookPath = $notebook.path
            break
        }
    }
    if ($notebookPath)
    {
        Write-Host "Deployment notebook $notebookPath found"
    }
    else
    {
        Write-Error "Deployment notebook not found"
        exit
    }



    # prepare deployment payload
    $payload = @{
        name = Split-Path -Path $notebookPath -Leaf
        tags = @{
            deployment = ""
        }
        tasks = @(
            @{
                task_key = "run_notebook_task"
                notebook_task = @{
                    notebook_path = $notebookPath
                }
                existing_cluster_id = $clusterId
            }
        )
    } | ConvertTo-Json -Depth 10

    # create deployment job
    $jobResponse = databricks jobs create --json $payload --output json --profile $ProfileName | ConvertFrom-Json
    $jobId = $jobResponse.job_id

    if ($jobId)
    {
        Write-Host "Deployment job created with id $jobId"
    }
    else
    {
        Write-Error "Deployment job not found"
        exit
    }

    # create deployment job run
    $jobRunResponse = databricks jobs run-now $jobId --no-wait --output json --profile $ProfileName | ConvertFrom-Json
    $jobRunId = $jobRunResponse.run_id

    if ($jobRunId)
    {
        Write-Host "Deployment job run created with id $jobRunId"
    }
    else
    {
        Write-Error "Deployment job run not found"
        exit
    }

    # get the deployment job run status
    $retry = $true
    while ($retry)
    {
        $jobStatusResponse = databricks jobs get-run $jobRunId --no-wait --output json --profile $ProfileName | ConvertFrom-Json
        $status = $jobStatusResponse.status.state
        $state = $jobStatusResponse.state.result_state

        Write-Host "Deployment job run status: $status" -NoNewline

        if ($status -ne "TERMINATED")
        {
            Write-Host ". Checking again in 15 seconds..."
            Start-Sleep -Seconds 15
        }
        else
        {
            Write-Host " - $state."
            $retry = $false
        }
    }

    # show final status
    if ($state -eq "SUCCESS")
    {
        Write-Host "Deployment job run completed successfully"
    }
    else
    {
        Write-Error "Deployment job run failed"
        exit
    }
}



Write-Host
Write-Host '--------------------------------------------------------------------------------'
Write-Host
Write-Host "Finished"

# SIG # Begin signature block
# MII6ggYJKoZIhvcNAQcCoII6czCCOm8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAzXgG5776CUO5j
# xo04u2t0j8Iii8mh4ni3yP0RkqYFn6CCIqYwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbnMIIEz6ADAgECAhMzAAJW2DSk
# HdEy4l0hAAAAAlbYMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDIwHhcNMjUwNDA3MjAxODIwWhcNMjUwNDEw
# MjAxODIwWjBnMQswCQYDVQQGEwJDSDEZMBcGA1UECBMQQmFzZWwtTGFuZHNjaGFm
# dDERMA8GA1UEBxMIUHJhdHRlbG4xFDASBgNVBAoTC2JpR0VOSVVTIEFHMRQwEgYD
# VQQDEwtiaUdFTklVUyBBRzCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGB
# AIpOuVtS2ik0TL2CKa4ZOALbzGsyLzPmS9CsoQ5zKxH6lTFyopTI+8HHJwIuVqFO
# auekdzIQqEEmWY+20a4SEG+KZWFqKqGeA4IEHxGnycB1eW1Sl4rZsRFM6zczbloa
# xMTtj1T8e9YcE99MO9MeaeqfmxumKvCEud6hePEZAM3QcdPDyM+HPgMj/YvTsuOM
# +wsiAb6yWU7HK5q1lhSXhl18NpXGwMbMTiGhrDrx8fBb09c5Kpa+YMXQHq+Er2Xy
# LdOuNxhQ53Nki+w+IeU0/02Gy72jX79+E5YViKnHgnNpp6WIJUS2EGentU3TvCmC
# V2T7W4PS6Fc1hFHjunRd369E2hlNXAv5+/DWw+ww5gx4IyPXJyGk6rJ7pc+naGah
# D06ZGgIheEmqWdQFttQMAjKo5qaacEqAse4KiW0GzA9saizUb7solDQLKyitcCB+
# Xe+yXAmdluuXkapKFTJumOeE2CsNygC77ihNTlfPo2U5v5pGLIBB8n45BTA61kp/
# BQIDAQABo4ICFzCCAhMwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwOgYD
# VR0lBDMwMQYKKwYBBAGCN2EBAAYIKwYBBQUHAwMGGSsGAQQBgjdhgsaA6WLf0W6B
# 6fmZVeSkpA0wHQYDVR0OBBYEFIqC51uS/QlVfwnWI14eNsQQG6mZMB8GA1UdIwQY
# MBaAFGWfUc6FaH8vikWIqt2nMbseDQBeMGcGA1UdHwRgMF4wXKBaoFiGVmh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIw
# VmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDIuY3JsMIGlBggrBgEFBQcBAQSB
# mDCBlTBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDAyLmNydDAtBggrBgEFBQcwAYYhaHR0cDovL29uZW9jc3AubWljcm9zb2Z0
# LmNvbS9vY3NwMGYGA1UdIARfMF0wUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUH
# AgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0
# b3J5Lmh0bTAIBgZngQwBBAEwDQYJKoZIhvcNAQEMBQADggIBAFZE4k+MjBRdukKv
# s6EQqWniPZXVJd/eqU8bXzARkUAAzGh9aTKJi/lfmtvv5d8uSwhcxGtI5nSKbaVH
# agHiZJIXVNYgu5Aw3P/1AyCRiK/ITodMv+//f3kYvcjP6+Tg4LOmn+Tzb0cLE1bp
# NzCkBWyQf5RUrUxye7Yi93dqutxRkUKsnIfTZ4D15s8EbDn44DMP0At0GuUT/7Ub
# q4UVz7+eh3ksT81YAhTSCzRvJ+rxdy21ffeEzBtuzLKbfWbisJip3ZzobVH6OnRP
# 2bjqrphKMqg7oDdi0QAIdGwZ/fd2rQWyxmNUlOckcfYig21k+FmlBfDfq/rkAslO
# 122tPV+12MkJe9ywzxQLwjQYOJ2dj2qBQKZZDxc7KlODx2//VWAiCACvNmrvqXTf
# dipdCWcoUPl+uXvW7Dn3LnMQZMyEu1Tw/YW6q9fwxbFa7RpePCwzFExTxleKcLxx
# G0p3pD0ZomR51wQaDAK49rm4D+4GleHf+O2scwl33RgPHhUNpPT8B1eLgydLSL5v
# FEG/BqiJF1GVcZcdkXjps/mWPr+kEZ25IM5itrr/oG6eFk9EwmGbyQr0XJFa3xhn
# 3bFtyXnp93KERPJbfXsTUhkZsdhh9AAuldJR7/Kbwljq99u9RiJPkvj1sFpyWdMb
# 8rlLXImo/5pPTeTafD7ZBQMVtcnnMIIG5zCCBM+gAwIBAgITMwACVtg0pB3RMuJd
# IQAAAAJW2DANBgkqhkiG9w0BAQwFADBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVy
# aWZpZWQgQ1MgRU9DIENBIDAyMB4XDTI1MDQwNzIwMTgyMFoXDTI1MDQxMDIwMTgy
# MFowZzELMAkGA1UEBhMCQ0gxGTAXBgNVBAgTEEJhc2VsLUxhbmRzY2hhZnQxETAP
# BgNVBAcTCFByYXR0ZWxuMRQwEgYDVQQKEwtiaUdFTklVUyBBRzEUMBIGA1UEAxML
# YmlHRU5JVVMgQUcwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCKTrlb
# UtopNEy9gimuGTgC28xrMi8z5kvQrKEOcysR+pUxcqKUyPvBxycCLlahTmrnpHcy
# EKhBJlmPttGuEhBvimVhaiqhngOCBB8Rp8nAdXltUpeK2bERTOs3M25aGsTE7Y9U
# /HvWHBPfTDvTHmnqn5sbpirwhLneoXjxGQDN0HHTw8jPhz4DI/2L07LjjPsLIgG+
# sllOxyuatZYUl4ZdfDaVxsDGzE4hoaw68fHwW9PXOSqWvmDF0B6vhK9l8i3TrjcY
# UOdzZIvsPiHlNP9Nhsu9o1+/fhOWFYipx4JzaaeliCVEthBnp7VN07wpgldk+1uD
# 0uhXNYRR47p0Xd+vRNoZTVwL+fvw1sPsMOYMeCMj1ychpOqye6XPp2hmoQ9OmRoC
# IXhJqlnUBbbUDAIyqOammnBKgLHuColtBswPbGos1G+7KJQ0CysorXAgfl3vslwJ
# nZbrl5GqShUybpjnhNgrDcoAu+4oTU5Xz6NlOb+aRiyAQfJ+OQUwOtZKfwUCAwEA
# AaOCAhcwggITMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDoGA1UdJQQz
# MDEGCisGAQQBgjdhAQAGCCsGAQUFBwMDBhkrBgEEAYI3YYLGgOli39Fugen5mVXk
# pKQNMB0GA1UdDgQWBBSKgudbkv0JVX8J1iNeHjbEEBupmTAfBgNVHSMEGDAWgBRl
# n1HOhWh/L4pFiKrdpzG7Hg0AXjBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDAyLmNybDCBpQYIKwYBBQUHAQEEgZgwgZUw
# ZAYIKwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2Vy
# dHMvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAw
# Mi5jcnQwLQYIKwYBBQUHMAGGIWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20v
# b2NzcDBmBgNVHSAEXzBdMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wCAYGZ4EMAQQBMA0GCSqGSIb3DQEBDAUAA4ICAQBWROJPjIwUXbpCr7OhEKlp
# 4j2V1SXf3qlPG18wEZFAAMxofWkyiYv5X5rb7+XfLksIXMRrSOZ0im2lR2oB4mSS
# F1TWILuQMNz/9QMgkYivyE6HTL/v/395GL3Iz+vk4OCzpp/k829HCxNW6TcwpAVs
# kH+UVK1Mcnu2Ivd3arrcUZFCrJyH02eA9ebPBGw5+OAzD9ALdBrlE/+1G6uFFc+/
# nod5LE/NWAIU0gs0byfq8XcttX33hMwbbsyym31m4rCYqd2c6G1R+jp0T9m46q6Y
# SjKoO6A3YtEACHRsGf33dq0FssZjVJTnJHH2IoNtZPhZpQXw36v65ALJTtdtrT1f
# tdjJCXvcsM8UC8I0GDidnY9qgUCmWQ8XOypTg8dv/1VgIggArzZq76l033YqXQln
# KFD5frl71uw59y5zEGTMhLtU8P2FuqvX8MWxWu0aXjwsMxRMU8ZXinC8cRtKd6Q9
# GaJkedcEGgwCuPa5uA/uBpXh3/jtrHMJd90YDx4VDaT0/AdXi4MnS0i+bxRBvwao
# iRdRlXGXHZF46bP5lj6/pBGduSDOYra6/6BunhZPRMJhm8kK9FyRWt8YZ92xbcl5
# 6fdyhETyW317E1IZGbHYYfQALpXSUe/ym8JY6vfbvUYiT5L49bBaclnTG/K5S1yJ
# qP+aT03k2nw+2QUDFbXJ5zCCB1owggVCoAMCAQICEzMAAAAF+3pcMhNh310AAAAA
# AAUwDQYJKoZIhvcNAQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVk
# IENvZGUgU2lnbmluZyBQQ0EgMjAyMTAeFw0yMTA0MTMxNzMxNTNaFw0yNjA0MTMx
# NzMxNTNaMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0Eg
# MDIwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDSGpl8PzKQpMDoINta
# +yGYGkOgF/su/XfZFW5KpXBA7doAsuS5GedMihGYwajR8gxCu3BHpQcHTrF2o6QB
# +oHp7G5tdMe7jj524dQJ0TieCMQsFDKW4y5I6cdoR294hu3fU6EwRf/idCSmHj4C
# HR5HgfaxNGtUqYquU6hCWGJrvdCDZ0eiK1xfW5PW9bcqem30y3voftkdss2ykxku
# RYFpsoyXoF1pZldik8Z1L6pjzSANo0K8WrR3XRQy7vEd6wipelMNPdDcB47FLKVJ
# Nz/vg/eiD2Pc656YQVq4XMvnm3Uy+lp0SFCYPy4UzEW/+Jk6PC9x1jXOFqdUsvKm
# XPXf83NKhTdCOE92oAaFEjCH9gPOjeMJ1UmBZBGtbzc/epYUWTE2IwTaI7gi5iCP
# tHCx4bC/sj1zE7JoeKEox1P016hKOlI3NWcooZxgy050y0oWqhXsKKbabzgaYhhl
# MGitH8+j2LCVqxNgoWkZmp1YrJick7YVXygyZaQgrWJqAsuAS3plpHSuT/WNRiyz
# JOJGpavzhCzdcv9XkpQES1QRB9D/hG2cjT24UVQgYllX2YP/E5SSxah0asJBJ6bo
# fLbrXEwkAepOoy4MqDCLzGT+Z+WvvKFc8vvdI5Qua7UCq7gjsal7pDA1bZO1AHEz
# e+1JOZ09bqsrnLSAQPnVGOzIrQIDAQABo4ICDjCCAgowDgYDVR0PAQH/BAQDAgGG
# MBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRln1HOhWh/L4pFiKrdpzG7Hg0A
# XjBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgw
# FoAU2UEpsA8PY2zvadf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBW
# ZXJpZmllZCUyMENvZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwga4GCCsG
# AQUFBwEBBIGhMIGeMG0GCCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2Rl
# JTIwU2lnbmluZyUyMFBDQSUyMDIwMjEuY3J0MC0GCCsGAQUFBzABhiFodHRwOi8v
# b25lb2NzcC5taWNyb3NvZnQuY29tL29jc3AwDQYJKoZIhvcNAQEMBQADggIBAEVJ
# YNR3TxfiDkfO9V+sHVKJXymTpc8dP2M+QKa9T+68HOZlECNiTaAphHelehK1Elon
# +WGMLkOr/ZHs/VhFkcINjIrTO9JEx0TphC2AaOax2HMPScJLqFVVyB+Y1Cxw8nVY
# fFu8bkRCBhDRkQPUU3Qw49DNZ7XNsflVrR1LG2eh0FVGOfINgSbuw0Ry8kdMbd5f
# MDJ3TQTkoMKwSXjPk7Sa9erBofY9LTbTQTo/haovCCz82ZS7n4BrwvD/YSfZWQhb
# s+SKvhSfWMbr62P96G6qAXJQ88KHqRue+TjxuKyL/M+MBWSPuoSuvt9JggILMniz
# hhQ1VUeB2gWfbFtbtl8FPdAD3N+Gr27gTFdutUPmvFdJMURSDaDNCr0kfGx0fIx9
# wIosVA5c4NLNxh4ukJ36voZygMFOjI90pxyMLqYCrr7+GIwOem8pQgenJgTNZR5q
# 23Ipe0x/5Csl5D6fLmMEv7Gp0448TPd2Duqfz+imtStRsYsG/19abXx9Zd0C/U8K
# 0sv9pwwu0ejJ5JUwpBioMdvdCbS5D41DRgTiRTFJBr5b9wLNgAjfa43Sdv0zgyvW
# mPhslmJ02QzgnJip7OiEgvFiSAdtuglAhKtBaublFh3KEoGmm0n0kmfRnrcuN2fO
# U5TGOWwBtCKvZabP84kTvTcFseZBlHDM/HW+7tLnMIIHnjCCBYagAwIBAgITMwAA
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
# nTiOL60cPqfny+Fq8UiuZzGCFzIwghcuAgEBMHEwWjELMAkGA1UEBhMCVVMxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjErMCkGA1UEAxMiTWljcm9zb2Z0
# IElEIFZlcmlmaWVkIENTIEVPQyBDQSAwMgITMwACVtg0pB3RMuJdIQAAAAJW2DAN
# BglghkgBZQMEAgEFAKBeMBAGCisGAQQBgjcCAQwxAjAAMBkGCSqGSIb3DQEJAzEM
# BgorBgEEAYI3AgEEMC8GCSqGSIb3DQEJBDEiBCA/x0SQ8uYZoBzZ3WNStHf3fkPp
# eIxGyF9yAbO6H458ZzANBgkqhkiG9w0BAQEFAASCAYABrLOSmi+TTuDsA9p2u09g
# 7YBlwAzdV5isZevTZQNbvTsJAQv0AU+bULxOlS+BP1UDDaVLlm5Bddm/EEJyXdAi
# vE995GzqqfmIbsLjRip0UJg4+7CP0hapq5iTk5xX8+itpeB7DxjkvEBXaEZvlIZF
# Obe1ft5W9K9Ot4txGUegS1iCypzPnfxfzoyKMvIM+afkUv7+XVBXKatMogDq+Vpk
# KuqWdqGjx54jIa8egbapKC5Wc+6aOzMAiyDPCk0tJ/+4HpAeQzGEB4WMrcumaoHp
# Pb6ohOmG76GOOOOoOVItIEeimdvg18EhZAhEMnxi7uzSmP4TqeslRW6BtxTGMpK2
# CXxhgQXpl+COrAfR2ErfKRwVgiEBh3WxL4W5Qzlu1GcYXQFgA+GHZ51NVMRwgITz
# OuT84WZB4o03zmeVxSww3gRxR4vIcxuIVOHOxEQ8/oAokKna4IWrJNhG6Wp5YmwV
# W2gH4cqYGPy8njbOxR0tNiWcWnSPxbuQaeTndh7m4p6hghSyMIIUrgYKKwYBBAGC
# NwMDATGCFJ4wghSaBgkqhkiG9w0BBwKgghSLMIIUhwIBAzEPMA0GCWCGSAFlAwQC
# AQUAMIIBagYLKoZIhvcNAQkQAQSgggFZBIIBVTCCAVECAQEGCisGAQQBhFkKAwEw
# MTANBglghkgBZQMEAgEFAAQg6/9152i+Okq5pJIdWF6NkPGN/5E+7iFCVDR6yX2P
# vrECBmflOkZu/BgTMjAyNTA0MDgxMzI3MTIuMjU4WjAEgAIB9KCB6aSB5jCB4zEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEtMCsGA1UECxMkTWlj
# cm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMScwJQYDVQQLEx5uU2hp
# ZWxkIFRTUyBFU046NDkxQS0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQ
# dWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5oIIPKTCCB4IwggVqoAMC
# AQICEzMAAAAF5c8P/2YuyYcAAAAAAAUwDQYJKoZIhvcNAQEMBQAwdzELMAkGA1UE
# BhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjFIMEYGA1UEAxM/
# TWljcm9zb2Z0IElkZW50aXR5IFZlcmlmaWNhdGlvbiBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDIwMB4XDTIwMTExOTIwMzIzMVoXDTM1MTExOTIwNDIzMVow
# YTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEy
# MDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENBIDIw
# MjAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCefOdSY/3gxZ8FfWO1
# BiKjHB7X55cz0RMFvWVGR3eRwV1wb3+yq0OXDEqhUhxqoNv6iYWKjkMcLhEFxvJA
# eNcLAyT+XdM5i2CgGPGcb95WJLiw7HzLiBKrxmDj1EQB/mG5eEiRBEp7dDGzxKCn
# TYocDOcRr9KxqHydajmEkzXHOeRGwU+7qt8Md5l4bVZrXAhK+WSk5CihNQsWbzT1
# nRliVDwunuLkX1hyIWXIArCfrKM3+RHh+Sq5RZ8aYyik2r8HxT+l2hmRllBvE2Wo
# k6IEaAJanHr24qoqFM9WLeBUSudz+qL51HwDYyIDPSQ3SeHtKog0ZubDk4hELQSx
# nfVYXdTGncaBnB60QrEuazvcob9n4yR65pUNBCF5qeA4QwYnilBkfnmeAjRN3LVu
# Lr0g0FXkqfYdUmj1fFFhH8k8YBozrEaXnsSL3kdTD01X+4LfIWOuFzTzuoslBrBI
# LfHNj8RfOxPgjuwNvE6YzauXi4orp4Sm6tF245DaFOSYbWFK5ZgG6cUY2/bUq3g3
# bQAqZt65KcaewEJ3ZyNEobv35Nf6xN6FrA6jF9447+NHvCjeWLCQZ3M8lgeCcnnh
# TFtyQX3XgCoc6IRXvFOcPVrr3D9RPHCMS6Ckg8wggTrtIVnY8yjbvGOUsAdZbeXU
# IQAWMs0d3cRDv09SvwVRd61evQIDAQABo4ICGzCCAhcwDgYDVR0PAQH/BAQDAgGG
# MBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRraSg6NS9IY0DPe9ivSek+2T3b
# ITBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQM
# MAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB
# /wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZmAQHJ89QEE9oqKIwgYQGA1Ud
# HwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENl
# cnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcmwwgZQGCCsGAQUFBwEBBIGH
# MIGEMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJv
# b3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjAuY3J0MA0GCSqGSIb3
# DQEBDAUAA4ICAQBfiHbHfm21WhV150x4aPpO4dhEmSUVpbixNDmv6TvuIHv1xIs1
# 74bNGO/ilWMm+Jx5boAXrJxagRhHQtiFprSjMktTliL4sKZyt2i+SXncM23gRezz
# soOiBhv14YSd1Klnlkzvgs29XNjT+c8hIfPRe9rvVCMPiH7zPZcw5nNjthDQ+zD5
# 63I1nUJ6y59TbXWsuyUsqw7wXZoGzZwijWT5oc6GvD3HDokJY401uhnj3ubBhbkR
# 83RbfMvmzdp3he2bvIUztSOuFzRqrLfEvsPkVHYnvH1wtYyrt5vShiKheGpXa2AW
# psod4OJyT4/y0dggWi8g/tgbhmQlZqDUf3UqUQsZaLdIu/XSjgoZqDjamzCPJtOL
# i2hBwL+KsCh0Nbwc21f5xvPSwym0Ukr4o5sCcMUcSy6TEP7uMV8RX0eH/4JLEpGy
# ae6Ki8JYg5v4fsNGif1OXHJ2IWG+7zyjTDfkmQ1snFOTgyEX8qBpefQbF0fx6URr
# YiarjmBprwP6ZObwtZXJ23jK3Fg/9uqM3j0P01nzVygTppBabzxPAh/hHhhls6kw
# o3QLJ6No803jUsZcd4JQxiYHHc+Q/wAMcPUnYKv/q2O444LO1+n6j01z5mggCSlR
# wD9faBIySAcA9S8h22hIAcRQqIGEjolCK9F6nK9ZyX4lhthsGHumaABdWzCCB58w
# ggWHoAMCAQICEzMAAABOo8YOPjHDdCcAAAAAAE4wDQYJKoZIhvcNAQEMBQAwYTEL
# MAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAG
# A1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENBIDIwMjAw
# HhcNMjUwMjI3MTk0MDE3WhcNMjYwMjI2MTk0MDE3WjCB4zELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxh
# bmQgT3BlcmF0aW9ucyBMaW1pdGVkMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046
# NDkxQS0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRp
# bWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAht+Ui7psCW2V3udFfRPpJsXhsQyOgSZTt0vtkcGw5C2DmGIazwZCWtlU
# TXIBbMYCt6GinjuubZDRaJ2167wzQf9ztxqh6FUPWyjwZjRWjXaR8iZCnWq3kDWR
# xNxhdabJBt4vH3DwocGcgel6w/6yTZJOCViwW7cK0e0gVeOssAXv42MDRSvCzefL
# ls9362PE7q8UhjdXrJdvcYhtwdt+aV41+trhkQAD+EXEMN2bZF4u3/qKPuJUztDo
# RsNCuC5ExDJ0XwcTIs/3yIYocQffqZzP54n1eX9u9r4+T/1iPVqJzYwGsDthNtj+
# F3DcdKyTG9RSA0hwoVBWzPfoVIxdA7NVdbVwVcvhSIarD7KUKUlxnSXcfQCLCyem
# +jS32/jMPmPAmuZ40iUoF4fkQZt9c96VtURnae0wEKA96AHmp6Wqj5sx9LP2VFM7
# ZzssHJh9CzpQ4kvYmGCtmhP6DtY1IRkpdD6joNe6OmJ/ldMx0zNYI46Imcxx6+ll
# 0PZpho4QYVdSbnVATYksqeL/vV5xmMjoN/gLq8FdFXtZPvoFhSBwRrTyRhtbmQ3S
# OOcE8YUBKv1JKdk0YUpDgnwzJHEQE9lM3fcxf0/P7dl9kXiZLyjJcwJw6YTjToz1
# FJA/1tNVZW45HQwejnoSlQArWFUsp+5IPR0TBsaIxrAet6U4o0ECAwEAAaOCAcsw
# ggHHMB0GA1UdDgQWBBTwx7qDdKpK0vS3J3mLDiu/DU1qYjAfBgNVHSMEGDAWgBRr
# aSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6BdhltodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQdWJsaWMlMjBS
# U0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsGAQUFBwEBBG0w
# azBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9j
# ZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBD
# QSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUH
# AwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGCN0yDfQEBMEEw
# PwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9j
# cy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEMBQADggIBABMm
# cyukIa5ar1k6AQpwrI9mPvWf8mlf1JhpMr+o6s+wjHN/+q+r/+6PR1MGd/HspbRo
# jVjPYLpDvyDVvzQBTwBE3KgiGZPZJY0jyTsUujup5ZLM3htyAOBNFJooY+JZZsm0
# SNsKBsiQ0ndlM/2IEkKzFnC/prjlqf0CkbU1X/A/yeJXREEIf1IgeYPqy/fiXGXM
# dOAYZ/Wfbz1+D8uhIywsU9nj4benQpi7sDl/PrXogGT1laldDEcU1xIyD+uXBs7r
# mTSTSxGtSUhaST7vWe3Y2CmwVpaLYlirSaxfS7NXctstpZ8rODUHe6ChJcvKlmDe
# k/KmR1eHXCtr2HbbZG7OPI6bDJaLuNNBQE49l6fJqlsmEBleULE4Fo3TRuzVX7NS
# DaaI2170TwJYdqCr5G2z/WJKI8LBaYwp+qKVJJ1Iy1hJczJyIIpZ7F5GMBfRCi9K
# wa/SkyqRh89rm5ucjTdpv8Doqh3ZMQXy59KFX2xBKpsOxwxbXZNA5ujJNSFzzA+n
# ynZZZ6O+sf70BQ7qFOhph4ziMyaY5wACWkebYBj4YCT5jnh3oNgDo0EQP4JIQVJq
# RRVGo1uQ3iY3VI6SWh1mG9GmGYX063QO7Mu78oHJYh8dtpj/BO6ysRUYfhbiff0W
# Zwwi9Vsyl44Q1nn37EaIXC3mLO5ptmIc38QVHiV5MYID1DCCA9ACAQEweDBhMQsw
# CQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYD
# VQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMAIT
# MwAAAE6jxg4+McN0JwAAAAAATjANBglghkgBZQMEAgEFAKCCAS0wGgYJKoZIhvcN
# AQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBeEiNAQYANrtlmQFF5
# 7dobRBCa210ttTwrFXcOXPC2njCB3QYLKoZIhvcNAQkQAi8xgc0wgcowgccwgaAE
# IG+yp9PvKAUdsN79OPdAKfbkkcO5SGDK009Fvrv/lkoXMHwwZaRjMGExCzAJBgNV
# BAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMT
# KU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwAhMzAAAA
# TqPGDj4xw3QnAAAAAABOMCIEIGKJulQ3wbFrR3QKn1eheFUrirLxsLoRGaG3CyGK
# YjriMA0GCSqGSIb3DQEBCwUABIICAIHDuKNV6jqNKtlcElew/SKqnogLTEdF5p7V
# 3jwY1rxi+zXJEbhsy1cHJF54Mn+HEzMXAP5Y1xfRUO+0mwDzA5uL6dIh6tar1vAP
# cTK1rljjyNqU9AP1GvSB/9yeuLTDN2hRGEOH1dKdbBznRwNFcWyfcJSqM2iA8m3K
# tjI3qh8EZBRRIN7491HdebYCkU08RQGavm1StIH2BKbcQoOD+djUPFSO2WOjP27C
# PQR+qw12MIDby57VaAqw3cVdybwR7/odItrO9YMEYQ7Q/C5oIYFBUGWDiiYvhxm5
# Vo/sdPstiW84Y8U4JpTzaMCmjCP4MXl9hVo9dSUt2Lz5+BHrAdrf74M9NrY8vSEu
# kA+jIyUdJE1vqTl7IsL9L0jtspStcBKUTPtLRUFTDnL5zvHOto/x//wt9fRzzG9+
# d0t0lD0gLi1hcZ11xC/mp50K3lf8X1jYoitsps77c58t68jHxzosVwlCEtODrO+/
# sKELhpmKgGIKSxNHgIq4m8CwiCyOEArvM0xWLM6EjBjkFyDgVieMaDPFYZ7CVW15
# nGF0ZaZvtK0NSI7W0W5VFgBa5xmg2e5qCNw/rEkc6ml0WBG8FUppoqQTS+MnUZVY
# uOgk2ODq7sMQY0Jwh9+k0HF6NhnSC9DVh48mT3sjk3Ei/EAgSvsGkylGlConYaVs
# mEMWn4EM
# SIG # End signature block

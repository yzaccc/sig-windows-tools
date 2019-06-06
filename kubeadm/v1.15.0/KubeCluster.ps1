#
# Copyright 2019 (c) Microsoft Corporation.
# Licensed under the MIT license.
#
Param(
    [parameter(Mandatory = $false,HelpMessage="Print the help")]
    [switch] $help,
    [parameter(Mandatory = $false,HelpMessage="Initialize Windows Control Plane node (unsupported)")]
    [switch] $init,
    [parameter(Mandatory = $false,HelpMessage="Install pre-requisites")]
    [switch] $InstallPrerequisites,
    [parameter(Mandatory = $false,HelpMessage="Join the windows node to the master")]
    [switch] $join,
    [parameter(Mandatory = $false,HelpMessage="Reset this windows node and cleanup everything")]
    [switch] $reset,
    [parameter(Mandatory = $false,HelpMessage="Path to input configuration json ")] 
    $ConfigFile
)

function Usage()
{
    $bin = $PSCommandPath 
    Get-Help $bin -Detailed

    $usage = "
    Usage: 
		$bin [-help] [-init] [-join] [-reset]

	Examples:
        $bin -help                                                           print this help
        $bin -InstallPrerequisites -ConfigFile kubecluster.json               Set up this Windows node to run containers
        $bin -init -ConfigFile kubecluster.json                              joins the windows node to existing cluster control-plane (unsupported)
        $bin -join -ConfigFile kubecluster.json                              joins the windows node to existing cluster
        $bin -reset -ConfigFile kubecluster.json                             reset the kubernetes cluster
    "

    Write-Host $usage
}

function ReadKubeclusterConfig($ConfigFile)
{
    # Read the configuration and initialize default values if not found
    $Global:ClusterConfiguration = ConvertFrom-Json ((GetFileContent $ConfigFile -ErrorAction Stop) | out-string)
    if (!$Global:ClusterConfiguration.Install)
    {
        $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Install -Value @{ 
            Destination = "$env:ALLUSERSPROFILE\Kubernetes";
        }
    }

    if (!$Global:ClusterConfiguration.Kubernetes)
    {
        throw "Kubernetes information missing in the configuration file"
    }
    if (!$Global:ClusterConfiguration.Kubernetes.Source)
    {
        $Global:ClusterConfiguration.Kubernetes | Add-Member -MemberType NoteProperty -Name Source -Value @{
            Release = "1.15.0";
        }
    }
    if (!$Global:ClusterConfiguration.Kubernetes.Master)
    {
        throw "Master information missing in the configuration file"
    }

    if (!$Global:ClusterConfiguration.Kubernetes.Network)
    {
        $Global:ClusterConfiguration.Kubernetes | Add-Member -MemberType NoteProperty -Name Network -Value @{
            ServiceCidr = "10.96.0.0/12";
            ClusterCidr = "10.244.0.0/16";
        }
    }

    if (!$Global:ClusterConfiguration.Cni)
    {
        $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Cni -Value @{
            Name = "flannel";
            Plugin = @{
                Name = "vxlan";
            };
            InterfaceName = "Ethernet";
        }
    }

    if ($Global:ClusterConfiguration.Cni.Plugin.Name -eq "vxlan")
    {
        if (!$Global:ClusterConfiguration.Kubernetes.KubeProxy)
        {
            $Global:ClusterConfiguration.Kubernetes | Add-Member -MemberType NoteProperty -Name KubeProxy -Value @{
                    Gates = "WinOverlay=true";
            }
        }
    }

    if (!$Global:ClusterConfiguration.Cri)
    {
        $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Cri -Value @{
            Name = "dockerd";
            Images = @{
                Pause = "mcr.microsoft.com/k8s/core/pause:1.0.0";
                Nanoserver = "mcr.microsoft.com/windows/nanoserver:1809";
                ServerCore = "mcr.microsoft.com/windows/servercore:ltsc2019";
            }
        }
    }
}
function LoadPsm1($Path)
{
    $tmpPath = [io.Path]::Combine([System.IO.Path]::GetTempPath(), [io.path]::GetFileName($Path))
    Invoke-WebRequest $Path -o $tmpPath
    Import-Module $tmpPath  -DisableNameChecking
    Remove-Item $tmpPath
}
###############################################################################################
# Download pre-req scripts

$helperPath = "https://raw.githubusercontent.com/kubernetes-sigs/sig-windows-tools/kubeadm/v1.15.0/KubeClusterHelper.psm1"
$helperDestination = "$PSScriptRoot\KubeClusterHelper.psm1" 
Invoke-WebRequest $helperPath -o $helperDestination
Import-Module $helperDestination

$hnsPath = "https://raw.githubusercontent.com/Microsoft/SDN/master/Kubernetes/windows/hns.psm1"
$hnsDestination = "$PSScriptRoot\hns.psm1" 
Invoke-WebRequest $hnsPath -o $hnsDestination
Import-Module $hnsDestination


ReadKubeclusterConfig -ConfigFile $ConfigFile
InitHelper
PrintConfig
WriteKubeClusterConfig


# Initialize internal network modes of windows corresponding to 
# the plugin used in the cluster
$Global:NetworkName = "cbr0"
$Global:NetworkMode = "l2bridge"
if ($Global:NetworkPlugin -eq "vxlan")
{
    $Global:NetworkMode = "overlay"
    $Global:NetworkName = "vxlan0"
}
######################################################################################################################

# Handle --help
if ($help.IsPresent)
{
    Usage
    exit
}

# Handle --init
if ($init.IsPresent)
{
    Write-Host "Initalizing a Windows Control Plane node is unsupported"
    exit
}

# Handle --InstallPrerequisites
if ($InstallPrerequisites.IsPresent)
{
    InstallContainersRole
    if (!(Test-Path $env:HOMEDRIVE/$env:HOMEPATH/.ssh/id_rsa.pub))
    {
        $res = Read-Host "Do you wish to generate a SSH Key & Add it to the Linux Master [Y/n] - Default [Y] : "
        if ($res -eq '' -or $res -eq 'Y'  -or $res -eq 'y')
        {
            ssh-keygen.exe
        }
    }

    $pubKey = Get-Content $env:HOMEDRIVE/$env:HOMEPATH/.ssh/id_rsa.pub
    Write-Host "Execute the below commands on the Linux Master($Global:MasterIp) to add this Windows Node's public key to its authorized keys"
    
    Write-Host "touch ~/.ssh/authorized_keys"
    Write-Host "echo $pubKey >> ~/.ssh/authorized_keys"

    $res = Read-Host "Continue to Reboot the host [Y/n] - Default [Y] : "
    if ($res -eq '' -or $res -eq 'Y'  -or $res -eq 'y')
    {
        Restart-Computer -Force
    }

    InstallCRI $Global:Cri
    InstallKubernetesBinaries -Destination  $Global:BaseDir -Source $Global:ClusterConfiguration.Kubernetes.Source

    exit
}

# Handle -Join
if ($Join.IsPresent)
{
    $kubeConfig = GetKubeConfig
    if (!(KubeConfigExists))
    {
        # Fetch KubeConfig from the master
        DownloadKubeConfig -Master $Global:MasterIp -User $Global:MasterUsername
        if (!(KubeConfigExists))
        {
            throw $kubeConfig + " does not exist. Cannot connect to the master cluster"
        }
    }

    # Validate connectivity with Master API Server

    Write-Host "Trying to connect to the Kubernetes master"
    try {
        ReadKubeClusterInfo 
    } catch {
        throw "Unable to connect to the master. Reason [$_]"
    }

    $KubeDnsServiceIP = GetKubeDnsServiceIp
    $ClusterCIDR = GetClusterCidr
    $ServiceCIDR = GetServiceCidr
    
    Write-Host "####################################"
    Write-Host "Able to connect to the Master"
    Write-Host "Discovered the following"
    Write-Host "Cluster CIDR    : $ClusterCIDR"
    Write-Host "Service CIDR    : $ServiceCIDR"
    Write-Host "DNS ServiceIp   : $KubeDnsServiceIP"
    Write-Host "####################################"

    #
    # Install Services & Start in the below order
    # 1. Install & Start Kubelet
    InstallKubelet  -CniDir $(GetCniPath) `
                -CniConf $(GetCniConfigPath) -KubeDnsServiceIp $KubeDnsServiceIp `
                -NodeIp $Global:ManagementIp -KubeletFeatureGates $KubeletFeatureGates
    #StartKubelet

    #WaitForNodeRegistration -TimeoutSeconds 10

    # 2. Install CNI & Start services
    InstallCNI -Cni $Global:Cni -NetworkMode $Global:NetworkMode `
                  -ManagementIP $Global:ManagementIp `
                  -InterfaceName $Global:InterfaceName `
                  -CniPath $(GetCniPath)

    if ($Global:Cni -eq "flannel")
    {
        CreateExternalNetwork -NetworkMode $Global:NetworkMode -InterfaceName $Global:InterfaceName
        StartFlanneld 
        WaitForNetwork $Global:NetworkName
    }

    # 3. Install & Start Kubeproxy
    if ($Global:NetworkMode -eq "overlay")
    {
        $sourceVip = GetSourceVip -NetworkName $Global:NetworkName
        InstallKubeProxy -KubeConfig $(GetKubeConfig) `
                -NetworkName $Global:NetworkName -ClusterCIDR  $ClusterCIDR `
                -SourceVip $sourceVip `
                -IsDsr:$Global:DsrEnabled `
                -ProxyFeatureGates $Global:KubeproxyGates
    }
    else 
    {
        $env:KUBE_NETWORK=$Global:NetworkName
        InstallKubeProxy -KubeConfig $(GetKubeConfig) `
                -IsDsr:$Global:DsrEnabled `
                -NetworkName $Global:NetworkName -ClusterCIDR  $ClusterCIDR
    }
    
    StartKubeproxy

    GetKubeNodes
    Write-Host "Node $(hostname) successfully joined the cluster"
}
# Handle -Reset
elseif ($Reset.IsPresent)
{
    ReadKubeClusterConfig -ConfigFile $ConfigFile
    RemoveKubeNode
    # Initiate cleanup
    CleanupContainers
    CleanupOldNetwork $Global:NetworkName
    CleanupPolicyList
    UninstallCNI $Global:Cni
    UninstallKubeProxy
    UninstallKubelet
    UninstallKubernetesBinaries -Destination  $Global:BaseDir

    Remove-Item $Global:BaseDir -ErrorAction SilentlyContinue
    Remove-Item $env:HOMEDRIVE\$env:HOMEPATH\.kube -ErrorAction SilentlyContinue
}

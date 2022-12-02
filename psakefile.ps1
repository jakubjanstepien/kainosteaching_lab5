Properties {
    $Solution = "zsp-lab5-ost"
    $OutputRoot = Join-Path $psake.context.originalDirectory "BuildOutput"
    $TestRoot = Join-Path $psake.context.originalDirectory "test"
    $BuiltPackages = Join-Path $OutputRoot "BuiltPackages"
    $TestOutputPath = Join-Path $OutputRoot "TestResults"
    $SourceRoot = Join-Path $psake.context.originalDirectory "src"
    $TemplateConfigRoot = Join-Path $psake.context.originalDirectory "config_templates"

    # TF Props
    $TFWorkingDirectory = Join-Path $psake.context.originalDirectory "instances" $Instance
    $TFInstances = Join-Path $psake.context.originalDirectory "instances"
    $TFPlanOutputPath = Join-Path $OutputRoot "plan_output.json"
    $TFOutputPath = Join-Path $OutputRoot "terraform_output.json"
    $TFInputVarTemplate = Join-Path $TemplateConfigRoot "inputs.auto.tfvars.tmpl"
    $TFInputVarFilePath = Join-Path $TFWorkingDirectory "inputs.auto.tfvars"]

    # Docker Props
    $DockerBuildRoot = Join-Path $psake.context.originalDirectory "container"
    $DockerComposePath = Join-Path $psake.context.originalDirectory "container/docker-compose.yml"
    $ContainerNameSpace = "web"
    $DockerComposeLogsPath = Join-Path $OutputRoot "containers.log"
}

Function Get-ContainerPipelineInfo {
    [cmdletbinding()]
    [OutputType([psobject])]
    param(
        [string]
        $RegistryName,
        
        [ValidateSet("AzureAcr", "AWSAcr", "DockerHub")]
        [string]
        $RegistryType,
        
        [string]
        $ContainerNameSpace,
        
        [string]
        $ContainerName,
        
        [string]
        $Version
    )

    if ($ContainerNameSpace) {
        $_ContainerNameSpace = $ContainerNameSpace + "/"
    }

    $ContainerRepositoryName = ("{0}{1}" -f $_ContainerNameSpace, $ContainerName).ToLower()
    switch ($RegistryType) {
        "AzureAcr" {
            $Registry = Get-AzContainerRegistry | Where-Object Name -EQ $RegistryName
            $RegistryUrl = $Registry.LoginServer
            $RegistryId = $Registry.Id
        }
        default {
            throw "Registry type not supported"
        }
    }
    
    if ($Registry) {
        $FullyQualifiedContainerRepositoryId = "{0}/{1}" -f $RegistryUrl, $ContainerRepositoryName

        $reference_info = [psobject]@{
            RegistryId     = $RegistryId
            RegistryName   = $Registry.Name
            RepositoryName = $ContainerRepositoryName
            RepositoryUri  = $FullyQualifiedContainerRepositoryId
            CurrentTag     = $FullyQualifiedContainerRepositoryId + ":$Version"
            LatestTag      = $FullyQualifiedContainerRepositoryId + ":latest"
        }

        $reference_info
    }
    else {
        Write-Error "Registry $RegistryName not found"
    }
}

Task compose_tf -depends build, tf_destroy
Task compose_docker -depends build_docker, run, stop
# Task build -depends clean, code_analysis, tf_init, tf_plan, tf_apply, tf_output
Task build -depends clean, tf_init, tf_plan, tf_apply, tf_output
Task code_analysis -depends run_tfsec
Task deploy -depends tf_apply
Task publish -depends login_container_registry, get_container_build_information, push_container_image

Task init {
    Assert { $null -ne (Get-Command docker -ErrorAction SilentlyContinue) } "Docker must be installed to build this repository"
    Assert ( $null -ne (Get-Command az -ErrorAction SilentlyContinue) ) "Azure CLI must be installed to build this repository"

    Remove-Item $OutputRoot -ErrorAction SilentlyContinue -Force -Recurse
    New-Item $OutputRoot, $TestOutputPath, $BuiltPackages -Type Directory -ErrorAction Stop | Out-Null
    $TF_Version = "1.1.6"
    if ($IsLinux) {
        $TF_Download_Path = Join-Path "/tmp" "terraform_$TF_Version"
        $TF_Package_ID = "linux_amd64"
        $TF_InstallPath = "/usr/local/bin"
        # Assume apt based linux...
        $insall_az_cli = {
            apt-get update
            apt-get install ca-certificates curl apt-transport-https lsb-release gnupg
            curl -sL https://packages.microsoft.com/keys/microsoft.asc |
            gpg --dearmor |
            tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null
            AZ_REPO=$(lsb_release -cs)
            echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" |
            tee /etc/apt/sources.list.d/azure-cli.list
            apt-get update
            apt-get install azure-cli
        }
    }
    elseif ($IsMacOS) {
        Assert { $null -ne (Get-Command brew) } "brew required for installation of az cli"
        $TF_Download_Path = Join-Path "/tmp" "terraform_$TF_Version"
        $TF_Package_ID = "darwin_amd64"
        $TF_InstallPath = "/usr/local/bin"
        $insall_az_cli = {
            brew update && brew install azure-cli
        }
    }
    elseif ($IsWindows) {
        $insall_az_cli = {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
            Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
            rm .\AzureCLI.msi
        }
        $TF_Download_Path = Join-Path $env:TEMP "terraform_$TF_Version"
        $TF_Package_ID = "windows_amd64"
        $TF_InstallPath = Join-Path "C:" "Tools"
        New-Item -Path $TF_InstallPath -ErrorAction SilentlyContinue
    }
    else {
        throw "Not supported"
    }

    # Install Terraform
    if ((Get-Command terraform -ErrorAction SilentlyContinue) -eq $null -or (terraform --version | Select-String "v$TF_Version" -SimpleMatch) -eq $null) {
        Write-Output "Installing terraform @ $TF_Version"
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest "https://releases.hashicorp.com/terraform/$TF_Version/terraform_$($TF_Version)_$TF_Package_ID.zip" -OutFile "$TF_Download_Path.zip"
        Expand-Archive "$TF_Download_Path.zip" -DestinationPath $TF_InstallPath -Force
        $ProgressPreference = "Continue"
        if ($IsLinux -or $IsMacOS) {
            chmod +x /usr/local/bin/terraform
        }
    }

    # Install dependent PS modules
    "Az.ContainerRegistry", "Az.Accounts" | ForEach-Object {
        $m = Get-Module $_ -ListAvailable
        if (!$m) {
            Find-Module $_ | Install-Module -Force -Scope CurrentUser
            Import-Module $_
        }
    }

    $pester = Get-Module pester -ListAvailable -ErrorAction SilentlyContinue
    if (-not $pester -or $pester.Version -ne "5.3.1") {
        Install-Module -Name pester -RequiredVersion 5.3.1 -Force
    }

    if ($Null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Verbose "Installing az cli"
        Exec $insall_az_cli
    }

    Remove-Item $OutputRoot -ErrorAction SilentlyContinue -Force -Recurse
    New-Item $OutputRoot -Type Directory -ErrorAction Stop | Out-Null
}

Task login_container_registry -depends login_az {
    Connect-AzContainerRegistry -Name (Get-AzContainerRegistry | Where-Object Name -EQ $env:AZURE_CONTAINER_REGISTRY_NAME).Name
}

Task get_container_build_information -depends login_container_registry {
    $script:container_info = Get-ContainerPipelineInfo `
        -RegistryName $env:AZURE_CONTAINER_REGISTRY_NAME `
        -RegistryType AzureAcr `
        -ContainerNameSpace $ContainerNameSpace `
        -ContainerName $Solution `
        -Version $Version
    $container_info
}

Task build_docker -depends get_container_build_information {
    Write-Output "Executing $("docker build --pull -t {0} -t {1} {2}" -f $container_info.CurrentTag, $container_info.LatestTag, $DockerBuildRoot)"
    Exec { docker build --pull -t $container_info.CurrentTag -t $container_info.LatestTag $DockerBuildRoot }
}

Task run {
    Exec {
        # docker-compose -f $DockerComposePath --env-file .env up -d
        docker-compose -f $DockerComposePath up -d
        docker-compose -f $DockerComposePath ps
    }
}

Task stop {
    try {
        Exec { docker-compose -f $DockerComposePath rm -fs}
    }
    catch {}
}

Task transform_configuration_templates -depends set_configuration_defaults {
    Write-Output "Setting $TFInputVarFilePath with runtime values..."
    Get-Content $TFInputVarTemplate | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) } | Set-Content $TFInputVarFilePath -Force
}

Task set_configuration_defaults {
    # This task configures useful defaults for local development only.
    # Configuration during automated workflows should be defined as env vars within the github workflow files for each env
    if (-not $env:ci_pipeline) {
        # generic config
        # INSTANCE set via tf_provider_setup
        $env:RELEASE_VERSION ??= "0.0.0-Undefined"
    }
}

Task clean {
    Get-ChildItem $OutputRoot | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Exec { terraform fmt -recursive }
}

Task run_tfsec {
    # Run the tfsec with docker only for local development.
    # CI builds use a dedicated workflow that runs in parallel to save time
    if(!$env:ci_pipeline){
        Exec { docker run --rm -it -v "$(Get-Location):/src" aquasec/tfsec /src }
    }
}

Task tf_provider_setup {
    if ($env:ci_pipeline) {
        # CI Pipeline mode
        $env:ARM_CLIENT_ID = $env:GIT_ARM_CLIENT_ID
        $env:ARM_CLIENT_SECRET = $env:GIT_ARM_CLIENT_SECRET
        $env:ARM_SUBSCRIPTION_ID = $env:GIT_ARM_SUBSCRIPTION_ID
        $env:ARM_TENANT_ID = $env:GIT_ARM_TENANT_ID
    }
    else {
        # Local user mode
        if (-not $env:INSTANCE) {
            $env:INSTANCE = (Read-Host "Enter instance ID (Recommend first letter of firstname and lastname, i.e. John Smith = js)").ToLower()
        }
        else {
            Write-Output "Instance value set to $env:INSTANCE"
        }

        # Test if connected, if not then try to sign in
        try {
            $context = Exec { az account show 2> $null } | ConvertFrom-Json
        }
        catch {}

        if ($null -eq $context) {
            Exec { az login --tenant $env:GIT_ARM_TENANT_ID--allow-no-subscriptions } | Out-Null
            Exec { az account set --subscription $env:GIT_ARM_SUBSCRIPTION_ID }
        }
    }
}

Task login_az {
    if ($env:ci_pipeline) {
        if (!(Get-AzContext)) {
            $connect_as_sp = @{
                Credential       = New-Object pscredential `
                    -ArgumentList @($env:ARM_CLIENT_ID, (ConvertTo-SecureString $env:ARM_CLIENT_SECRET -AsPlainText -Force))
                Subscription     = $env:ARM_SUBSCRIPTION_ID
                Tenant           = $env:ARM_TENANT_ID
                ServicePrincipal = $true
            }
            Connect-AzAccount @connect_as_sp
        }
    }
    else {
        # if (!(Get-AzContext)) {
        if (!(Get-AzContext | Where-Object Tenant -match $env:ARM_TENANT_ID)) {
            Connect-AzAccount -Subscription $env:ARM_SUBSCRIPTION_ID
        }
    }
}

Task tf_init -depends tf_provider_setup, transform_configuration_templates {
    $CustomBackendConfig = ""
    if (
        ($Instance -eq "ci" -and $env:INSTANCE -ne "ci") -or
        ($Instance -eq "dev" -and $env:INSTANCE -ne "dev")
    ) {
        Write-Output "Updating backend-config key value to $Solution.$Instance.$env:INSTANCE.tfstate"
        $CustomBackendConfig = "-backend-config=`"key=$Solution.$Instance.$env:INSTANCE.tfstate`""
    }

    exec { terraform init $CustomBackendConfig -reconfigure } -workingDirectory $TFWorkingDirectory
}

Task tf_plan -depends tf_init {
    exec { terraform plan -out $TFPlanOutputPath } -workingDirectory $TFWorkingDirectory
}

Task tf_apply -depends tf_init, tf_plan {
    exec { terraform apply --auto-approve $TFPlanOutputPath } -workingDirectory $TFWorkingDirectory
}

Task tf_output -depends tf_init {
    exec { terraform output --json | Set-Content $TFOutputPath } -workingDirectory $TFWorkingDirectory
}

Task tf_destroy -depends tf_init {
    exec { terraform destroy --auto-approve } -workingDirectory $TFWorkingDirectory
}

Task push_container_image {
    Exec { docker push $container_info.LatestTag }
    Exec { docker push $container_info.CurrentTag }
}


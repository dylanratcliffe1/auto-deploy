[CmdletBinding()]
Param(
  [Parameter(Mandatory=$True)]
   [string[]]$Products,
	
   [Parameter(Mandatory=$True)]
   [string]$ConfigFile
)

# Set the error actions so that exceptions behave as expected (stupid powershell)
$defaultErrorActionPreference = "Stop"
$ErrorActionPreference = "Stop"

# UNCOMMENT THIS BEFORE USING THE CODE
#Import-Module WebAdministration

# Text formatting functions

function H1($s) {
	write-host ("--- {0} ---" -f $s) -f yellow
}

function H2($s) {
	write-host ("- {0} -" -f $s) -f yellow
}

function Log($s) {
	write-host $s -f cyan
}

function Error($s) {
    Write-Host $s -ForegroundColor Red -BackgroundColor Black
}

function Warn($s) {
    Write-Host $s -ForegroundColor Magenta -BackgroundColor Yellow
}

function XML-Read($inputFile) {
    # This function reads the input XML file and return a populated $config variable
    
    # Purge $config for running in Powershell ISE
    $config = $null
    $config = @{}

    # load it into an XML object:
    [XML]$xml = Get-Content $inputFile
	
	# Get the global downloadlocation
	$config.Add("downloadlocation",$xml.config.downloadlocation.toString())
	
    foreach ($Product in $xml.config.product) {
        $config.Add($Product.name, @{	bamboo = @{
											projectkey = $Product.bamboo.projectkey.toString()
											plankey = $Product.bamboo.plankey.toString()
											buildnumber = $Product.bamboo.buildnumber.toString()};
										files = @{
											uselocalartifacts = [System.Convert]::ToBoolean($Product.files.uselocalartifacts.toString())
                                        	artifacts = $Product.files.artifacts.ToString()
											databaseName = $Product.files.databaseName.toString()
                                        	databaseBackup = $Product.files.databaseBackup.toString()
                                        	moddedBuildTools = $Product.files.moddedBuildTools.toString()};
                                    	dependencies = @($Product.depencencies.dependency)} )
    }
    return $config    
}

function Item-Getter($location) {
    # The idea of this function is that you can give it any location for a file to be in Windows, Git or HTTP formats and it will download them and return a System.IO.Fileinfo
    if ($location -ne "") {
        try {
            
            if ($location.Substring($location.LastIndexOf(".")+1) -eq "git") {
                H2 "Git"

                Push-Location ($config.downloadlocation + "git")

                # Delete the folder if it exists
                $newFolderName = ($location.Substring($location.LastIndexOf("/") + 1,($location.LastIndexOf(".") - $location.LastIndexOf("/") -1)))
                if (Test-Path $newFolderName) {
                    Log "Removing old files..."
                    $fullFolderName = (Get-Location).Path + "\$newfoldername"
                    start-process powershell -ArgumentList " -command Remove-Item $fullFolderName -Recurse -Force" -verb RunAs -WindowStyle Hidden -Wait
                }

                # Get the contents of the folder before the clone
                $before = Get-Item *

                Log "Cloning repo..."
                # Clone the repo
                $ErrorActionPreference = "SilentlyContinue"
                git clone $location | Out-Default
                $ErrorActionPreference = $defaultErrorActionPreference

                # Get the contents of the folder after the clone
                $after = Get-Item *

                # Compare them to see if there was anything cloned
                $item = (Compare-Object -ReferenceObject $before -DifferenceObject $after).InputObject
             
                # This will throw an exception if nothing was cloned
                $item | Get-Member -ErrorAction Stop | Out-Null

                return $item

            } elseif ($location.Substring(0,4) -eq "http") {
                H2 "HTTP"
                # Scrape the filename from the URL
                $filename = $location.Substring($location.LastIndexOf("/")+1)
            
                # If the file already exists, delete it
                if (Test-Path ($config.downloadlocation + $filename)) {
                    Log "Deleting old files..."
                    Remove-Item ($config.downloadlocation + $filename)
                }

                Log "Downloading files..."
                # Download the file
                $path = (Download-File $location ($config.downloadlocation + $filename))

                return (Get-Item -Path $path)
            } else {
                H2 "Local Files"
                Log "Passing links to the local files..."
                return Get-Item $location
            }
        } catch {
            Error "Could not get the file, please check that $location is correct"
            Throw $Error[0]
        } finally {
            Pop-Location
        }
    } else {
        return ""
    }
}
                
function Download-File($source, $Destination) {
        # Destination must include filename, not just path
        # This function returns the destination as a string tso you can use it inside another command\
    
        try {
            Log "Creating downloader"
            $wc = New-Object System.Net.WebClient
            Log "Downloading file..."
            $wc.DownloadFile($source,$Destination)
            Log "Done."
        } catch {
            Error "DOWNLOAD FILE FAILED" $source
            Throw $Error[0]
        }
        return $Destination
    }

function Clone-Repo($repositoryUrl) {
    git clone $repositoryUrl
    return Get-Location | Get-Item
}

function Restore-Database($dBName, $backupFile) {
    H1 "Restoring ${dBName} Database"
	
	# Check that we were arctually passed a backup file to restore
	if ($backupFile -eq "") {
		Error "There was no backup file found, skipping."
		Throw "No backup file found"
	}
	
    # Check that the file exists
    Log "Checking that backup restore directory exists"
    if (Test-Path C:\MySQLServer) {
        Log "Folder Found"
    } else {
        Log "Directory not found, creating"
        New-Item C:\MySQLServer -ItemType Directory 
        Log "Directory created"
        Restore-Database $dBName $backupFile.FullName
    }
        
    
    
    # Set up the SQL command to run to restore the database
    $dBCommand = "RESTORE DATABASE [" + $dBName + "] " +
    "FROM DISK = N'" + $backupFile.FullName + "' " +
    "WITH FILE = 1, NOUNLOAD,STATS=10," +
    "MOVE '" + $dBName + "' TO 'C:\MySQLServer\" + $dBName + ".mdf', " +
    "MOVE '" + $dBName + "_Log' TO 'C:\MySQLServer\" + $dBName + "_Log.ldf', REPLACE"
   
    # Restore the database
    Log "Restoring" $dBName "database"
    $parameters = @("-S", "localhost\MSSQL", "-E", "-Q", $dBCommand)
    #Write-Host "OSQL.exe" $parameters
    
    & 'OSQL.exe' $parameters
    if ($LASTEXITCODE -ne 0) {
        throw "OSQL exited with a non-zero error code. It probabaly failed, check the console"
    }
}

function Build-Database($dBName, $artifacts) {
    # $dBName - The name of the database e.g. "psi"
    # $artifacts - The object that reoresents the directory of the artifacts on the pc
    H1 "Building ${dBName} Database"
	
	try {
		# CD to the location
		Push-Location $artifacts
	
    	$parameters = @($artifacts.EnumerateFiles("*Database.sqlproj", "AllDirectories").FullName, `
    	"/p:Configuration=Release", `
    	"/t:Build", `
    	"/p:PublishToDatabase=True", `
    	("/p:SqlPublishProfilePath=" + $artifacts.EnumerateFiles("Release.publish.xml", "AllDirectories").FullName.ToString()), `
    	"/p:VisualStudioVersion=11.0", `
    	"/p:TargetDatabaseName=$dBName")

    	# Make sure msbuild is on the path
    	Add-ToPath "C:\Windows\Microsoft.NET\Framework\v4.0.30319\"

    	# Run it
    	& 'msbuild' $parameters
    	if ($LASTEXITCODE -ne 0) {
        	throw "MSBuild exited with a non-zero error code. It probabaly failed, check the console"
    	}
	} catch {
		Throw $Error[0]
	} finally {
		Pop-Location
	}
}

function Add-ToPath($string) {
    # This function adds a string to the end of the PATH variable
    # Useful because .NET needs to be on the PATH for msbuild to work
    $oldPath=(Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).Path
    if ($oldPath.Contains($string)) {
        Log "PATH is already set"
    } else {
        Log "Adding $string to PATH"
        $newPath=$oldPath+";$string"
        Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH –Value $newPath
        Log "Done."
    }
    $env:Path = $env:Path + ";$string"
}

function Deploy-Site($package, $artifacts) {
    # $package - the name of the package to be deployed (core, psi, etc.)
    # $artifactsLocation - The directory of the artifacts on the pc, should contain
    # The below command must be run from inside the directory of the package you want to install
	if ($package -eq "core") {
    	$deploymentCommand =  ($artifacts.FullName + "\build-tools\scripts\deploy-website.ps1 -siteName 'Default Web Site/services/core' -deployCmdPath " + $artifacts.FullName + "\web-service\core.services.deploy.cmd -deployToServers localhost")
    } else {
		$deploymentCommand =  $artifacts.FullName + "\build-tools\scripts\deploy-application.ps1 -ConfigFilePath build-tools\config\${package}.yaml -Environment local -DeployWebsitesTo PRIMARY -DeployWebServicesTo PRIMARY"
    }
    H1 "Deploying ${package} Site"
    #Check to see if the correct directory has been provided
    try {
        # CD to the correct directory
        Log "Moving to $package directory"
        Push-Location $artifacts
        Get-Location | Write-Host

        # Check that the correct folders exist
        if (!(Verify-Artifacts $artifacts)) {
            throw "Folder is not could not be verified, make sure it is an artifacts folder"
        }
		
		# Modify Database loaction in environments.yaml
		$envYaml = Get-Childitem -Path ($artifacts.FullName + "\build-tools") -Filter "environments.yaml" -Recurse
		Replace-InFile -File $envYaml -SearchRegex "db_server: localhost " -ReplaceString "db_server: localhost\MSSQL "

        # Clear any errors that might have occured so that the script doesn't fail for no reason
        Log "Clearing errors"
        $error.Clear()

        # Deploy the site
        Log "Deploying site"
        Log "Running Invoke-Expression $deploymentCommand"
        Invoke-Expression $deploymentCommand
        if ($LASTEXITCODE -ne 0) {
            throw "Deployment exited with code $LASTEXITCODE. It probably failed, check the console"
        }
    } catch [System.Management.Automation.ItemNotFoundException] {
        Error "Could not CD into Artifacts folder for " $package
        Error "The directory was: " $artifacts.FullName
        throw $error[0]
    } catch {
        Error "There was an error deploying the site"
        throw $Error[0]
    } finally {
        Pop-Location
    }
}

function Replace-Localhost($file) {
    # Changing localhost to localhost\MSSQL in config file
    (Get-Content $file.FullName) | 
    Foreach-Object {$_ -replace "Data Source=.*?(?=;)", "Data Source=localhost\MSSQL"} | 
    Set-Content $file.FullName
    Log "Modified file for local deployment"
}

function Replace-InFile($File, $SearchRegex, $ReplaceString) {
    # Changing localhost to localhost\MSSQL in config file
    (Get-Content $File.FullName) | 
    Foreach-Object {$_ -replace $SearchRegex, $ReplaceString} | 
    Set-Content $File.FullName
    Log ("Replaced $SearchRegex with $ReplaceString in " + $File.FullName)
}

# Local LDAP needs to be setup for GCIS
function Ensure-Ldap-Setup() {
	if (-not [adsi]::Exists("LDAP://localhost/CN=Users,CN=debug,DC=app,DC=anzgcis,DC=local")) {
		throw "Cannot connect to Gcis LDAP directory. Please ensure you have setup LDAP correctly."
	}
}

# Decide on the correct order to install things
function Get-InstallOrder($products) {
    $installOrder = @()

    # Find things with no dependecies
    foreach ($product in $products) {
        if ($config.$product.dependencies.Count -eq 0) {
            $installOrder += $product
        }
    }

    # this is for catching infinite loops (messy i know)
    $x = 0

    while ($installOrder.Count -ne $products.Count) {
        $x++
        # While not all things have been added
        foreach ($product in $products) {
            if ($installOrder -notcontains $product) {
                # Compare and see if the dependencies are missing
                $missing = $config.$product.dependencies | Where-Object { $installOrder -notcontains $_ }
				if ($missing -eq $null -or $missing.count -eq 0) {
					# all dependencies are in already. Add it.
					$installOrder += $product
				}
            }
        }
        if ($x -gt 50) {
            Error "Some dependencies were not listed!! trying to deploy anyway..."
            return $products
        }
    }
    return $installOrder
}

function Verify-Artifacts($artifacts) {
    if (($artifacts.GetDirectories().Name -contains "build-tools") -and ($artifacts.GetDirectories().Name -contains "web-service")) {
        return $true
    } else { 
            throw "Artifacts directory " + $artifacts.FullName + " could not be verified"
    }
}

function Download-Files($product) {
    # Downloads the files and replaces their string values in the config with their actual objects
	if ($config.Get_Item($product).files.uselocalartifacts) {
    	$config.Get_Item($product).files.artifacts = Item-Getter $config.Get_Item($product).files.artifacts
	} else {
		# Connect to the build server and download all the stuff
		# PROBABLY NEED TO ADD VERIFICATION FOR THE API CALLS AND USEFUL ERRORS
		try {
    		$artifactLinks = Get-ArtifactsArray -projectKey $config.Get_Item($product).bamboo.projectkey -planKey $config.Get_Item($product).bamboo.plankey -buildNumber $config.Get_Item($product).bamboo.buildnumber -bambooSession $bambooSession
    		$config.Get_Item($product).files.artifacts = Download-Artifacts -destination ($config.downloadlocation + $config.Get_Item($product).bamboo.projectkey + "-" + $config.Get_Item($product).bamboo.plankey + "-" + $config.Get_Item($product).bamboo.buildnumber) -artifactLinks $artifactLinks -bambooSession $bambooSession
		} catch {
			Error "There was an issue getting the artifacts from bamboo"
			Error ("Project Key: " + $config.Get_Item($product).bamboo.projectkey)
			Error ("Plan Key: " + $config.Get_Item($product).bamboo.plankey)
			Error ("Build Number: " + $config.Get_Item($product).bamboo.buildnumber)
    		throw
		}
	}
    $config.Get_Item($product).files.databaseBackup = Item-Getter $config.Get_Item($product).files.databaseBackup 
    $config.Get_Item($product).files.moddedBuildTools = Item-Getter $config.Get_Item($product).files.moddedBuildTools
    
}

function ApplicationPoolExists($name = "GCIS-AppPool") {
    return Test-Path "IIS:\AppPools\${name}"
}

function Create-ApplicationPool($name = "GCIS-AppPool") {
    # This creates an app pool and return the object that represents the pool
    Log "Checking IIS application pool status..."
    try {
        if ((Get-WebAppPoolState -Name $name).Value -eq "Started") {
            Log "Application pool already exists"
            return Get-Item "IIS:\AppPools\${name}"
        } elseif ((Get-WebAppPoolState -Name $name).Value -eq "Stopped") {
			Log "Starting App Pool ${name}"
			Start-WebAppPool -Name $name
			return Get-Item "IIS:\AppPools\${name}"
		}
    } catch {
        Log "Creating application pool"
        return New-WebAppPool -Name $name 
    }
}

# Set up the app pool as a local user
function Configure-ApplicationPool($pool) {
    Log "Setting upp local user for application pool..."
    # Set up the app pool as deafult
    $pool.processModel.identityType = 4
    $pool | Set-Item
}

#move the sites and services across
function Set-ApplicationPools($pool, $site = "Default Web Site") {
    foreach ($item in Get-ChildItem "IIS:\\Sites\$site") {
        if ($item.NodeType -eq "application") {
            Log ("Moving application: " + $item.Name + " to: " + $pool.Name)
            $appName = $item.Name
            Set-ItemProperty -Path "IIS:\Sites\${site}\${appName}" -Name "applicationPool" -Value $pool.Name
        }
    }
}

function Escape-String($name) { 
    [System.Uri]::EscapeDataString($name) 
} 

function Bamboo-Login($username, $password) {
    # Escape the inputs so as that they are okay for HTML
    $escapedUsername = Escape-String $username
    $escapedPassword = Escape-String $password

    # this is a pretty dirty way of doing it but it works!
    # The key things here is the session variable, using it you can do any other requests to the site
    try {
        Log "Logging in to Bamboo..." 
        $response = Invoke-WebRequest -Uri https://build.anzgcis.com/userlogin.action -SessionVariable bambooSession -Method Post -Body ("os_destination=%2Fstart.action&os_username=" + $escapedUsername + "&os_password=" + $escapedPassword + "&checkBoxFields=os_cookie&save=Log+in&atl_token=&atl_token_source=js")
		if ($response.Forms.Count -ne 0) {
			Throw "Login Failed, check your username and password"
		}
        return $bambooSession
    } catch {
        throw $Error[0]
    }
}

function Bamboo-Logout($bambooSession) {
    Log "Logging out..."
    Invoke-WebRequest  https://build.anzgcis.com/userLogout.action -WebSession $bambooSession | Out-Null
    Log "Logged out."
}

function Get-ArtifactsArray($projectKey, $planKey, $buildNumber, $bambooSession) {
    # Returns an array of hashtables with the artifact name and url

    # Get the latest build
    Log ("Finding artifacts for build " + $buildNumber + " in " + $projectKey + "-" + $planKey)
    $request = Invoke-RestMethod ("https://build.anzgcis.com/rest/api/latest/result/" + $projectKey + "-" + $planKey + "/" + $buildNumber + "/?expand=artifacts") -WebSession $bambooSession
    
    # Get the artifacts from the build
    $webArtifacts = $request.result.artifacts.artifact

    $artifactLinks = @()
    foreach ($artifact in $webArtifacts) {
        # for each artifact add it's name and download link to the array
        $artifactLinks += @{$artifact.name = $artifact.link.href}
    }
    return $artifactLinks
}

function Download-Recursive($destination, $url, $bambooSession) {
    # Recieves a web folder and downloads it's contents to
    # the destination directory, they will need to be renamed after
    
	# Make the request
	$response = Invoke-WebRequest $url -WebSession $bambooSession
	
	# Check to see if it is a file or HTML page
	if (!(($response.BaseResponse.ContentType -eq "text/html") -and ($response.Content.Contains("images/icons/")))) {
		# the link is a file
        # Get the filename
        $sourceFilename = $url.Substring(($url.LastIndexOf("/")) + 1)
        $destinationFilename = Escape-String $destination.Substring(($destination.LastIndexOf("\")) + 1)
        # Check that the destination filename is the same as the actual filname
        # we do this becuase sometimes it is not, usually in the case of core-dacpac
        if ($sourceFilename -ne $destinationFilename) {
            # Create a folder for this file to live in
            Log "Creating folder $destination"
            New-Item $destination -type directory -Force
            $destination = "$destination\$sourceFilename"
        }

        Log "Downloading $destination"
		
		# Use different methods of saving the file depending on what
		if ($response.Content.getType().Name -eq "String") {
			$response.Content -replace "ï»¿" | Out-File $Destination -Force -Encoding "UTF8"
		} else {
			$fileStream = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]'Create', [System.IO.FileAccess]'Write')
			$fileStream.Write($response.Content,0,$response.Content.Count)
			$fileStream.Close()
		}

	} else {
		if (!$(Test-Path($destination))) {
            # Create the destination folder if it does not exist
            Log "Creating folder $destination"
            New-Item $destination -type directory -Force | Out-Null
        }
        # Get the List of links
        $links = $response.Links
		
        foreach ($link in $links) {
            # check that it is not a parent directory link
            if ($link.innerText -ne "Parent Directory") {
                # The link is a folder
                Download-Recursive -destination ($destination + "\" + $link.innerText) -url ("https://build.anzgcis.com" + $link.href) -bambooSession $bambooSession
            }
        }  
	}
}

function Download-Artifacts($destination, $artifactLinks, $bambooSession) {
    # Purge the directory before downloading
    if (Test-Path $destination) {
        Remove-Item ($destination + "\*") -Recurse -Force | Out-Null
    }

    # Download each artifact
    H1 "Downloading Artifacts from Bamboo"
    foreach ($artifact in $artifactLinks) {
        H2 ([System.String]$artifact.Keys)
        Download-Recursive -destination ($destination + "\" + $artifact.Keys) -url ($artifact.Values[0] | %{return $_}) -bambooSession $bambooSession | Out-Null
    }
    return (Get-Item $destination)
}

function Transform-Artifacts($artifacts) {
    Push-Location $artifacts.FullName
    try {
        # Check to see if the folders need to be renamed
        if (Test-Path Website) {
            Log "Renaming Website to web-site"
            Rename-Item Website web-site
        }
        if (Test-Path Webservice) {
            Log "Renaming Webservice to web-service"
            Rename-Item Webservice web-service
        }
		if (Test-Path "Front Office Website") {
            Log "Front Office Website to front-office-web-site"
            Rename-Item "Front Office Website" "front-office-web-site"
        }
		if (Test-Path "Back Office Website") {
            Log "Back Office Website to back-office-web-site"
            Rename-Item "Back Office Website" "back-office-web-site"
        }

        # Check what folder the web-service stuff is in and change it 
		try {
        	if ($artifacts.EnumerateFiles("*.Services.zip", "AllDirectories").Directory.Name -ne "web-service") {
            	Log "Renaming Web Service folder to web-service"
            	Move-Item -Path $artifacts.EnumerateFiles("*.Services.zip", "AllDirectories").Directory.FullName -Destination ($artifacts.EnumerateFiles("*.Services.zip", "AllDirectories").Directory.Parent.FullName + "\web-service").toString() -Force
        	}
		} catch {
			Log "*.Services.zip not found, skipping."
		}

        # Replace spaces with dashes in directory names
        foreach ($directory in $artifacts.EnumerateDirectories("* *")) {
            Move-Item $directory -Destination ($directory.Parent.FullName + "\" + $directory.Name.Replace(" ", "-")).toString() -Force
        }

        # Check to see if core.database.dacpac needs to be moved
		try {
        	if ($artifacts.EnumerateFiles("Core.Database.dacpac", "AllDirectories").Directory.Name -ne "gcis") {
            	Log "Moving Core.Database.dacpac to \lib\gcis"
            	New-Item -ItemType Directory -Path ($artifacts.FullName + "\lib\gcis") -Force | Out-Null
            	Move-Item -Path $artifacts.EnumerateFiles("Core.Database.dacpac", "AllDirectories").FullName -Destination ($artifacts.FullName + "\lib\gcis\Core.Database.dacpac") -Force | Out-Null
        	}
		} catch {
			Log "Core.Database.dacpac not found, skipping"
		}
		
		# Check to see where it is looking for the dacpac file and correct it if it is wrong
		try {
			$sqlproj_file = Get-item -Path $artifacts.EnumerateFiles("*Database.sqlproj", "AllDirectories").FullName
			Replace-InFile -File $sqlproj_file -SearchRegex "..\\..\\lib\\gcis\\Core.Database.dacpac" -ReplaceString "..\lib\gcis\Core.Database.dacpac"
		} catch {
			Log "*Database.sqlproj not found, skipping"
		}
		
    
        # Edit the config files to point to the right database
		try {
        	Replace-Localhost $artifacts.EnumerateFiles("Release.publish.xml", "AllDirectories")
		} catch {
			Log "Release.publish.xml not found, skipping"
		}
    } catch {
        throw
    } finally {
        Pop-Location
    }
}

function Move-Certs($source, $destination) {
	$certs = Get-ChildItem $source
	foreach ($cert in $certs) {
		Log ("Moving certificate: " + $cert.GetName() + " to " + ${destination})
    	$store = Get-Item $destination
    	$store.Open("ReadWrite")
    	$store.Add($cert)
    	$store.Close()
	}
}

function Give-Permissions($Table, $User) {
	try {
		Log "Assigning permissions for user: $user on table: $table"
		try {
			Invoke-Sqlcmd -Query "USE [$table] CREATE USER [$user] FOR LOGIN [$user] EXEC sp_addrolemember N'db_owner', N`'$user`'" -ServerInstance "localhost\MSSQL"
		} catch {
			Log "User already exists"
		}
	} catch {
		Error "There was an error assigning permissions to the table"
		Error "User: $user"
		Error "Table: $table"
		Throw $Error[0]
	}
}

# ACTUAL CODE

try {
	try {
		Log "Trying to add snapins, some need this and some don't, not sure why."
		Add-PSSnapin SqlServerCmdletSnapin100
		Add-PSSnapin SqlServerProviderSnapin100
	} catch {
		Log "Snapins failed, it's probably fine"
	}

	# Check for admin
	if (!(([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
	        [Security.Principal.WindowsBuiltInRole] "Administrator"))) {
	    Error "You must run this script as administrator"
	    exit 1
	}

	try {
	    $config = XML-Read $ConfigFile
	} catch {
	    Error "Config File could not be loaded because of an error. Please check that the XML file exists and is well formed"
	    Throw $Error[0]
	}

	# format the parameters so that they play nice
	$Products = $Products.Trim() 

	# Check to see if we are going to need a bamboo session
	foreach ($product in $Products) {
		# Compare input product name with actual products in config file to ensure input exists
		if ($config.keys -notcontains $Product){
			Warn "Product $product does not exist"
			Warn "Continuing with valid product input"
			$Products = $Products -ne $Product
			#ADD "DID YOU MEAN ???" OPTIONS 
		}
		else
		{
			if ($config.Get_Item($product).files.uselocalartifacts -eq $false) {
				$needBamboo = $true
			}
		}
	}
	
	if ($needBamboo) {
		# Connect to Bamboo 
		$credential = Get-Credential -Message "Username and password for https://build.anzgcis.com"
	    $bambooSession = Bamboo-Login -username $credential.GetNetworkCredential().username -password $credential.GetNetworkCredential().password
	}
		
	#download the files and move the modded scripts
	foreach ($Product in $Products) {  
		H1 "Downloading ${Product} Files"

	    # Download the files
	    Download-Files $Product

	    # Verify them right away
		try {
	    	Log "Transforming artifacts..." 
	    	Transform-Artifacts -artifacts $config.Get_Item($Product).files.artifacts
	    	Log "Verifying Artifacts..."
	    	Verify-Artifacts $config.Get_Item($Product).files.artifacts
		} catch {
	    	throw
		}

	    # Move modded build tools accross
	    if ($config.Get_Item($Product).files.moddedBuildTools -ne "") {
	        Log "Moving modded build tools..."
	        Copy-Item $config.Get_Item($Product).files.moddedBuildTools -Destination ($config.Get_Item($Product).files.artifacts.FullName) -Force -Recurse
	    }
	}



	# set the install order
	$ProductsArray = $Products -split ", "
	$installOrder = Get-InstallOrder $ProductsArray

	# Deploy the sites
	foreach ($Product in $installOrder) {
		try {
	    	Restore-Database $config.Get_Item($Product).files.databaseName $config.Get_Item($product).files.databaseBackup
		} catch {
			# Do nothing for the time being	
		}
	    Build-Database $config.Get_Item($Product).files.databaseName $config.Get_Item($product).files.artifacts
	    Deploy-Site $Product $config.Get_Item($Product).files.artifacts
	}

	# Set up the application pools in IIS correctly
	# The logic here is a bit weird but this will not create the pool if it already exists, it will just return the existing pool for use by Set-ApplicationPools
	$pool = Create-ApplicationPool
	
	# Snsure that it is running as the right user
	Configure-ApplicationPool $pool

	# Set pools for all the newly created sites and services
	Set-ApplicationPools $pool

	# Move self signed certs so that they are trusted
	Move-Certs "Cert:\LocalMachine\My" "Cert:\LocalMachine\Root"

	# Run string replacements on all web.config files
	$wwwroot = Get-Item "C:\inetpub\wwwroot\"
	$configFiles = Get-Childitem -Path $wwwroot.FullName -Filter "Web.config" -Recurse
	$i = 0
	h1 "Modifying site config files"
	while ($i -lt $configFiles.Length - 1) {
		# Replace CI Database connection with localhost
		Replace-InFile -File $configFiles[$i] -SearchRegex "Data Source=melci21.dev.anzgcis.local" -ReplaceString "Data Source=localhost\MSSQL"
		# Replaces database server names with the locl database server
		Replace-InFile -File $configFiles[$i] -SearchRegex "[a-z]+dbs\d+.dev.anzgcis.local" -ReplaceString "localhost\MSSQL"
		# Replaces app and web server names with the computer names
		Replace-InFile -File $configFiles[$i] -SearchRegex "[a-z]+[app|web]\d+.dev.anzgcis.local" -ReplaceString $Env:COMPUTERNAME
		# Replaces CI server name with the computer names
		Replace-InFile -File $configFiles[$i] -SearchRegex "melci21.dev.anzgcis.local" -ReplaceString $Env:COMPUTERNAME
		# Remove failover stuff because the local databse is not part of a cluster
		Replace-InFile -File $configFiles[$i] -SearchRegex ";failover partner=" -ReplaceString ""
		# Remove database encryption because we dont need it
		Replace-InFile -File $configFiles[$i] -SearchRegex ";encrypt=true" -ReplaceString ""
		# Replace LDAP location (soon we won't need this)
		Replace-InFile -File $configFiles[$i] -SearchRegex "LDAP://dev.anzgcis.local/OU=Users,OU=Applications,DC=dev,DC=anzgcis,DC=local" -ReplaceString "LDAP://localhost/CN=Users,CN=debug,DC=app,DC=anzgcis,DC=local"
		# Change contextType setting
		Replace-InFile -File $configFiles[$i] -SearchRegex 'key="ContextType" value="Domain"' -ReplaceString 'key="ContextType" value="ApplicationDirectory"'
		# Change to windows authentication
		Replace-InFile -File $configFiles[$i] -SearchRegex 'mode="Forms"' -ReplaceString 'mode="Windows"'
		$i++
	}

	# Enable Windows and Anon auth for IIS
	Log "Setting IIS authenication..."
	Set-WebConfigurationProperty -filter /system.webServer/security/authentication/windowsAuthentication -name enabled -value true -PSPath IIS:\
	Set-WebConfigurationProperty -filter /system.WebServer/security/authentication/AnonymousAuthentication -name enabled -value true -PSPath IIS:\

	# Add binding HTTPS
	h1 "Configuring deployed sites"
	Log "Removing existing bindings"
	Get-WebBinding -Protocol https | Remove-WebBinding
	Log "Creating HTTPS binding"
	New-WebBinding -name "Default Web Site" -port 443 -Protocol "https" -HostHeader $Env:COMPUTERNAME -IPAddress "*" -Force
	try {
		Push-Location "IIS:\SslBindings"
		(Get-Item Cert:\LocalMachine\Root\*) | Where-Object {$_.Subject -eq ("CN=" + $Env:COMPUTERNAME)} | new-item 0.0.0.0!443
	} catch {
		if ((ls)[0] -ne $null) {
			Log "There were multiple self-signed certs for this computer which caused an error, it can be ignored:"
			Error $Error[0]
		} else {
			Throw $Error[0]
		}
	} finally {
		Pop-Location
	}

	# Update core config in database
	h1 "Updating Database"
	h2 "Updating core settings"
	Log "Updating URLs in Core config table"
	try {
		Invoke-Sqlcmd -Query "UPDATE [core].[dbo].[Config] set Value = REPLACE(Value, 'melci21.dev.anzgcis.local', CONVERT(varchar(max),SERVERPROPERTY('MachineName')));" -ServerInstance "localhost\MSSQL"
	} catch {
		Error "There was an error doing updating the Core.dbo.Config table. Did the core database restore successfully?"
		Throw $Error[0]
	}

	# Give the local user permissions to the tables that we just added
	h2 "Setting user permissions"
	foreach ($Product in $Products) {
		Give-Permissions -Table $Product -User "BUILTIN\IIS_IUSRS"
	}
} catch {
	Throw $Error[0]
} finally {
	# If we logged in previously, log out
	if ($needBamboo) {
		Bamboo-Logout $bambooSession
	}
}

Log "Install Finished!"
# Script name: BackupAndUpdate
#
# SCRIPT INFORMATION
#
# Script:  Mikrotik RouterOS automatic backup & update
# Version: 26.02.22
# Created: 07/08/2018
# Updated: 22/02/2026
# Author:  Alexander Tebiev
# Website: https://github.com/beeyev
# You can contact me by e-mail at tebiev@mail.com
#
# IMPORTANT!
# Minimum supported RouterOS version is v6.43.7
#
# --- MODIFY THIS SECTION AS NEEDED ---
# Script mode, possible values: backup, osupdate, osnotify.
# backup    -   Only backup will be performed. (default value, if none provided)
#
# osupdate  -   Installs new RouterOS if available and creates backups before/after update (ignores `forceBackup`)
#               Set `forceBackup` to true to always create backups, even without updates
#
# osnotify  -   Checks for a new RouterOS update and reports only to logs (no backups)
#               Set `forceBackup` to always create backups on every run
:local scriptMode "osupdate"

# Additional parameter if you set `scriptMode` to `osupdate` or `osnotify`
# Set `true` if you want the script to perform backup every time its fired, whatever script mode is set.
:local forceBackup true

# Backup encryption password, no encryption if no password.
:local backupPassword ""

# If true, passwords will be included in exported config.
:local sensitiveDataInConfig false

## Update channel. Possible values: stable, long-term, testing, development
:local updateChannel "stable"

# Installs patch updates only (scriptMode = "osupdate").
# Works for `stable` and `long-term` channels.
# Updates only if MAJOR.MINOR match (e.g. 6.43.2 → 6.43.6 allowed, 6.44.1 skipped).
# Sends info if a newer (non-patch) version is found.
:local installOnlyPatchUpdates false

# Include public IP info in logs if set to true
:local detectPublicIpAddress false

# Backup destination directories.
# Primary is preferred. Fallback is used only if primary is unavailable.
:local backupDirPrimary "usb1-part1/backup"
:local backupDirFallback "backup"

# Usb stick directory to store downloaded firmware files.
:local usbstickdir "usb1-part1/firmware";

#  !!! DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU’RE DOING !!!

:local scriptVersion "26.02.22"

# default and fallback public IP detection services
:local ipAddressDetectServiceDefault "https://ipv4.mikrotik.ovh/"
:local ipAddressDetectServiceFallback "https://api.ipify.org/"

#Script messages prefix
:local SMP "Bkp&Upd:"

:local exitErrorMessage "$SMP script stopped due to an error. Please check logs for more details."
:log info "\n\n$SMP Script \"Mikrotik RouterOS automatic backup & update\" v.$scriptVersion started."
:log info "$SMP Script Mode: `$scriptMode`, Update channel: `$updateChannel`, Force backup: `$forceBackup`, Install only patch updates: `$installOnlyPatchUpdates`"

## vv FUNCTIONS vv ##

# Returns currently running RouterOS version
# :put [$FuncGetRunningOsVersion]  # Output: 6.48.1
:local FuncGetRunningOsVersion do={
  :local runningOsAndChannel [/system resource get version]

  :local spacePos [:find $runningOsAndChannel " "]
  :if ([:len $spacePos] = 0) do={
    :log error "Bkp&Upd: Could not extract installed OS version string: `$runningOsAndChannel`."
    :error "Bkp&Upd: error, check logs"
  }

  :local versionOnly [:pick $runningOsAndChannel 0 $spacePos]

  :return $versionOnly
}

# Returns currently running RouterOS channel
# :put [$FuncGetRunningOsChannel]  # Output: stable
:local FuncGetRunningOsChannel do={
  :local runningOsAndChannel [/system resource get version]

  :local open [:find $runningOsAndChannel "("]
  :if ([:len $open] = 0) do={
    :log error "Bkp&Upd: Could not extract installed OS channel from version string: `$runningOsAndChannel`."
    :error "Bkp&Upd: error, check logs"
  }

  :local rest [:pick $runningOsAndChannel ($open+1) [:len $runningOsAndChannel]]
  :local close [:find $rest ")"]
  :local channel [:pick $rest 0 $close]

  :return $channel
}

# Checks if two RouterOS version strings differ only by the patch version
# :put [$FuncIsPatchUpdateOnly "6.2.1" "6.2.4"]  # Output: true
# :put [$FuncIsPatchUpdateOnly "6.2.1" "6.3.1"]  # Output: false
:local FuncIsPatchUpdateOnly do={
  :local ver1 $1
  :local ver2 $2

  # Extract "major.minor" prefix from each version by finding the second dot
  :local dot1 [:find $ver1 "."]
  :if ([:len $dot1] = 0) do={ :return ($ver1 = $ver2) }
  :local end1 [:find $ver1 "." ($dot1 + 1)]
  :if ([:len $end1] = 0) do={ :set end1 [:len $ver1] }

  :local dot2 [:find $ver2 "."]
  :if ([:len $dot2] = 0) do={ :return ($ver1 = $ver2) }
  :local end2 [:find $ver2 "." ($dot2 + 1)]
  :if ([:len $end2] = 0) do={ :set end2 [:len $ver2] }

  :return ([:pick $ver1 0 $end1] = [:pick $ver2 0 $end2])
}

# Creates backups and returns array of names
# Possible arguments:
#  $1 - file name, without extension
#  $2 - password (optional)
#  $3 - sensitive data in config (optional, default: false)
#  $4 - primary backup directory (optional)
#  $5 - fallback backup directory (optional)
# Example:
# :put [$FuncCreateBackups "daily-backup"]
:local FuncCreateBackups do={
  :local backupName $1
  :local backupPassword $2
  :local sensitiveDataInConfig $3
  :local backupDirPrimary $4
  :local backupDirFallback $5
  :local backupDir ""

  :if ([:len $backupDirPrimary] = 0) do={
    :set backupDirPrimary "usb1-part1/backup"
  }
  :if ([:len $backupDirFallback] = 0) do={
    :set backupDirFallback "backup"
  }

  #Script messages prefix
  :local SMP "Bkp&Upd:"
  :local exitErrorMessage "$SMP script stopped due to an error. Please check logs for more details."
  :log info ("$SMP global function `FuncCreateBackups` started, input: `$backupName`")

  # validate required parameter: backupName
  :if ([:typeof $backupName] != "str" or [:len $backupName] = 0) do={
    :log error "$SMP parameter 'backupName' is required and must be a non-empty string"
    :error $exitErrorMessage
  }

  # Choose resilient destination directory.
  # Prefer USB storage, but fall back to local storage if USB is unavailable.
  :local backupDirCandidates {$backupDirPrimary;$backupDirFallback}
  :foreach candidateDir in=$backupDirCandidates do={
    :if ([:len $backupDir] = 0) do={
      :if ([:len [/file find name=$candidateDir]] = 0) do={
        :log warning "$SMP Backup directory does not exist, creating it: `$candidateDir`"
        :do {
          /file make-dir $candidateDir
        } on-error={
          :log warning "$SMP Failed to create backup directory: `$candidateDir`"
        }
      }

      :if ([:len [/file find name=$candidateDir]] > 0) do={
        :set backupDir $candidateDir
      }
    }
  }

  :if ([:len $backupDir] = 0) do={
    :log error "$SMP Failed to prepare backup directory on both primary and fallback storage"
    :error $exitErrorMessage
  }

  :log info "$SMP Backup destination selected: `$backupDir`"

  :local backupFileBase "$backupDir/$backupName"
  :local backupFileSys "$backupFileBase.backup"
  :local backupFileConfig "$backupDir/$backupName.rsc"
  :local backupNames {$backupFileSys;$backupFileConfig}

  ## Perform system backup with retry (transient storage errors can happen).
  :local backupSaveOk false
  :for attempt from=1 to=3 do={
    :if ($backupSaveOk = false) do={
      :do {
        :if ([:len $backupPassword] = 0) do={
          :log info ("$SMP starting backup without password, backup name: `$backupFileBase`, attempt: $attempt/3")
          /system backup save dont-encrypt=yes name=$backupFileBase
        } else={
          :log info ("$SMP starting backup with password, backup name: `$backupFileBase`, attempt: $attempt/3")
          /system backup save password=$backupPassword name=$backupFileBase
        }

        :set backupSaveOk true
      } on-error={
        :log warning "$SMP backup save command failed on attempt $attempt/3"
        :delay 2s
      }
    }
  }

  :if ($backupSaveOk = false) do={
    :log error "$SMP backup save failed after multiple attempts"
    :error $exitErrorMessage
  }

  :log info ("$SMP system backup command completed: `$backupFileSys`")

  ## Export config file with retry.
  :local exportConfigOk false
  :for attempt from=1 to=3 do={
    :if ($exportConfigOk = false) do={
      :do {
        :if ($sensitiveDataInConfig = true) do={
          :log info ("$SMP starting export config with sensitive data, backup name: `$backupFileBase`, attempt: $attempt/3")
          # Since RouterOS v7 it needs to be explicitly set that we want to export sensitive data
          :if ([:pick [/system resource get version] 0 1] < 7) do={
            :execute "/export compact terse file=$backupFileBase"
          } else={
            :execute "/export compact show-sensitive terse file=$backupFileBase"
          }
        } else={
          :log info ("$SMP starting export config without sensitive data, backup name: `$backupFileBase`, attempt: $attempt/3")
          /export compact hide-sensitive terse file=$backupFileBase
        }

        :set exportConfigOk true
      } on-error={
        :log warning "$SMP config export command failed on attempt $attempt/3"
        :delay 2s
      }
    }
  }

  :if ($exportConfigOk = false) do={
    :log error "$SMP config export failed after multiple attempts"
    :error $exitErrorMessage
  }

  :log info ("$SMP Config export complete: `$backupFileConfig`")
  :log info ("$SMP Waiting for backup files to appear on storage")

  # Wait until both backup files exist (storage/USB writes can be delayed).
  :local waitTimeout 180
  :local waitCounter 0
  :local backupSysExists false
  :local backupConfigExists false

  :while ($waitCounter < $waitTimeout and ($backupSysExists = false or $backupConfigExists = false)) do={
    :set backupSysExists ([:len [/file find name=$backupFileSys]] > 0)
    :set backupConfigExists ([:len [/file find name=$backupFileConfig]] > 0)

    :if ($backupSysExists = false or $backupConfigExists = false) do={
      :delay 1s
      :set waitCounter ($waitCounter + 1)
    }
  }

  :if ($backupSysExists = true) do={
    :log info ("$SMP system backup file successfully saved to the file system: `$backupFileSys`")
  } else={
    :log error ("$SMP system backup was not created, file does not exist: `$backupFileSys`")
    :log error ("$SMP All files in system: `[/file find]`")
    :error $exitErrorMessage
  }

  :if ($backupConfigExists = true) do={
    :log info ("$SMP config backup file successfully saved to the file system: `$backupFileConfig`")
  } else={
    :log error ("$SMP config backup was not created, file does not exist: `$backupFileConfig`")
    :log error ("$SMP All files in system: `[/file find]`")
    :error $exitErrorMessage
  }

  :log info ("$SMP global function `FuncCreateBackups` finished. Created backups, system: `$backupFileSys`, config: `$backupFileConfig`")

  :return $backupNames
}

# Global variable to track current update step
# They need to be initialized here first to be available in the script
:global buGlobalVarScriptStep
:local scriptStep $buGlobalVarScriptStep
:do {/system script environment remove buGlobalVarScriptStep} on-error={}
:if ([:len $scriptStep] = 0) do={
  :set scriptStep 1
}
## ^^ FUNCTIONS ^^ ##


#
# Initial validation
#

# Script mode validation
:if ($scriptMode != "backup" and $scriptMode != "osupdate" and $scriptMode != "osnotify") do={
  :log error ("$SMP Script parameter `\$scriptMode` is not set, or contains invalid value: `$scriptMode`. Script stopped.")
  :error $exitErrorMessage
}

# Update channel validation
:if ($updateChannel != "stable" and $updateChannel != "long-term" and $updateChannel != "testing" and $updateChannel != "development") do={
  :log error ("$SMP Script parameter `\$updateChannel` is not set, or contains invalid value: `$updateChannel`. Script stopped.")
  :error $exitErrorMessage
}

# Verify if script is set to install patch updates and if the update channel is valid
:if ($scriptMode = "osupdate" and $installOnlyPatchUpdates = true) do={
  :if ($updateChannel != "stable" and $updateChannel != "long-term") do={
    :log error ("$SMP Patch-only updates enabled, but update channel `$updateChannel` is invalid. Only `stable` and `long-term` are supported. Script stopped")
    :error $exitErrorMessage
  }

  :local susRunningOsChannel [$FuncGetRunningOsChannel]

  :if ($susRunningOsChannel != "stable" and $susRunningOsChannel != "long-term") do={
    :log error ("$SMP Script is set to install only patch updates, but the installed RouterOS version is not from `stable` or `long-term` channel: `$susRunningOsChannel`. Script stopped")
    :error $exitErrorMessage
  }
}

#
# Get current date and time
#
:local rawTime [/system clock get time]
:local rawDate [/system clock get date]

# Current time in specific format `hh-mm-ss`
:local currentTime ([:pick $rawTime 0 2] . "-" . [:pick $rawTime 3 5] . "-" . [:pick $rawTime 6 8])

# Current date `YYYY-MM-DD` or `YYYY-Mon-DD`
:local currentDate "undefined"

# Check if the date is in the old format
:if ([:len [:tonum [:pick $rawDate 0 1]]] = 0) do={
  # Convert old format `nov/11/2023` → `2023-nov-11`
  :set currentDate ([:pick $rawDate 7 11] . "-" . [:pick $rawDate 0 3] . "-" . [:pick $rawDate 4 6])
} else={
  # Use new format as is `YYYY-MM-DD`
  :set currentDate $rawDate
}

:local currentDateTime ($currentDate . "-" . $currentTime)

:local deviceBoardName [/system resource get board-name]

## Check if it's a cloud hosted router
:local isCloudHostedRouter false
:if ([:pick $deviceBoardName 0 3] = "CHR" or [:pick $deviceBoardName 0 3] = "x86") do={
  :set isCloudHostedRouter true
}

:local deviceIdentityName     [/system identity get name]
:local deviceIdentityNameShort  [:pick $deviceIdentityName 0 18]

:local deviceRbModel        "CloudHostedRouter"
:local deviceRbSerialNumber "--"
:local deviceRbCurrentFw    "--"
:local deviceRbUpgradeFw    "--"

:if ($isCloudHostedRouter = false) do={
  :set deviceRbModel        [/system routerboard get model]
  :set deviceRbSerialNumber [/system routerboard get serial-number]
  :set deviceRbCurrentFw    [/system routerboard get current-firmware]
  :set deviceRbUpgradeFw    [/system routerboard get upgrade-firmware]
}

:local runningOsChannel [$FuncGetRunningOsChannel]
:local runningOsVersion [$FuncGetRunningOsVersion]
:local deviceOsVerAndChannelRunning [/system resource get version]

:local backupNameTemplate     "v$runningOsVersion_$runningOsChannel_$currentDateTime"
:local backupNameBeforeUpdate "backup_before_update_$backupNameTemplate"
:local changelogUrl     "Check RouterOS changelog: https://mikrotik.com/download/changelogs/"
:local backupAttachments  [:toarray ""]

## IP address detection
:if ($scriptStep = 1) do={
  # default values
  :local publicIpAddress "not-detected"

  :if ($detectPublicIpAddress = true) do={
    :do {:set publicIpAddress ([/tool fetch http-method="get" url=$ipAddressDetectServiceDefault output=user as-value]->"data")} on-error={
      :log warning "$SMP Failed to detect public IP using default service: `$ipAddressDetectServiceDefault`"
      :log warning "$SMP Trying fallback service: `$ipAddressDetectServiceFallback`"

      :do {:set publicIpAddress ([/tool fetch http-method="get" url=$ipAddressDetectServiceFallback output=user as-value]->"data")} on-error={
        :log warning "$SMP Could not detect public IP address using fallback detection service: `$ipAddressDetectServiceFallback`"
      }
    }

    # basic safety
    :set publicIpAddress ([:pick $publicIpAddress 0 15])
    :log info "$SMP Public IP address detected: `$publicIpAddress`"
  }
}

## STEP 1: Create backups and check for new RouterOS
## Steps 2–3 run only if auto-update is enabled and a new version is available
:if ($scriptStep = 1) do={
  :local routerOsVersionAvailable "0.0.0"
  :local isNewOsUpdateAvailable false
  :local isLatestOsAlreadyInstalled true
  :local isOsNeedsToBeUpdated false
  :local isUpdateCheckSucceeded false

  # Checking for new version
  :if ($scriptMode = "osupdate" or $scriptMode = "osnotify") do={
    :log info ("$SMP Setting update channel to `$updateChannel`")
    /system package update set channel=$updateChannel
    :log info ("$SMP Checking for new RouterOS version. Current installed version is: `$runningOsVersion`")
    /system package update check-for-updates

    # Wait to allow the system to check for updates
    :delay 5s

    :local packageUpdateStatus "undefined"

    :set routerOsVersionAvailable [/system package update get latest-version]
    :set packageUpdateStatus [/system package update get status]

    :if ($packageUpdateStatus = "New version is available") do={
      :log info ("$SMP New RouterOS version is available: `$routerOsVersionAvailable`")
      :set isNewOsUpdateAvailable true
      :set isLatestOsAlreadyInstalled false
      :set isUpdateCheckSucceeded true
      :log info ("$SMP New RouterOS version details: current version: v$runningOsVersion, new version: v$routerOsVersionAvailable. $changelogUrl")
    } else={
      :if ($packageUpdateStatus = "System is already up to date") do={
        :log info ("$SMP No new RouterOS version is available, the latest version is already installed: `v$runningOsVersion`")
        :set isUpdateCheckSucceeded true
      } else={
        :log error ("$SMP Failed to check for new RouterOS version. Package check status: `$packageUpdateStatus`")
      }
    }

    :local archs {"mipsbe"; "mmips"; "arm"};
    :local pkgs {"routeros"; "wireless"; "wifi-qcom-ac"};

    :foreach deviceOs in=$pkgs do={
        :foreach deviceOsArch in=$archs do={
            :local deviceOsName "$deviceOs-$runningOsVersion-$deviceOsArch.npk"
            :local exists [:len [/file find name="$usbstickdir/$deviceOsName"]]

            :if ($exists = 0) do={
                :local path  [ :put "/routeros/$runningOsVersion/$deviceOsName" ];
                :local url "https://download.mikrotik.com$path"
                :log info ("$SMP downloading $deviceOsArch firmware v$runningOsVersion from $url to $usbstickdir.");
                :do { /tool fetch url="$url" dst-path="$usbstickdir" http-header-field="User-Agent: Mozilla/5.0"; } on-error={}
            } else {
                :log info ("$SMP $deviceOsArch firmware v$runningOsVersion already stored at $usbstickdir.");
            }
        }
    }
  }

  # Checking if the script needs to install new os version
  :if ($scriptMode = "osupdate" and $isNewOsUpdateAvailable = true) do={
    :if ($installOnlyPatchUpdates = true) do={
      :if ([$FuncIsPatchUpdateOnly $runningOsVersion $routerOsVersionAvailable] = true) do={
        :log info "$SMP New RouterOS version is available, and it is a patch update. Current version: v$runningOsVersion, new version: v$routerOsVersionAvailable"
        :set isOsNeedsToBeUpdated true
      } else={
        :log info "$SMP The script will not install this update, because it is not a patch update. Current version: v$runningOsVersion, new version: v$routerOsVersionAvailable"
        :log info "$SMP This update will not be installed, because the script is set to install only patch updates."
      }
    } else={
      :set isOsNeedsToBeUpdated true
    }
  }


  # Checking If the script needs to create a backup
  :if ($forceBackup = true or $scriptMode = "backup" or $isOsNeedsToBeUpdated = true) do={
    :log info ("$SMP Starting backup process.")

    :local backupName $backupNameTemplate

    # This means it's the first step where we create a backup before the update process
    :if ($isOsNeedsToBeUpdated = true) do={
      :set backupName $backupNameBeforeUpdate
    }

    :do {
      :set backupAttachments [$FuncCreateBackups $backupName $backupPassword $sensitiveDataInConfig $backupDirPrimary $backupDirFallback]
    } on-error={
      #failed to create backup
      :set isOsNeedsToBeUpdated false

      :log warning "$SMP Backup creation failed. Update process will be canceled if automatic update is enabled"
    }
  }

  :if ($isOsNeedsToBeUpdated = true) do={
    :log info "$SMP everything is ready to install new RouterOS, going to start the update process and reboot the device."
    :do {
      :if ($isCloudHostedRouter = true) do={
        :log info "$SMP The device is a cloud hosted router, the second step updating the Routerboard firmware will be skipped."
      } else={
        :local scheduledCommand (":delay 5s; /system scheduler remove BKPUPD-NEXT-BOOT-TASK; :global buGlobalVarScriptStep 2; :delay 10s; /system script run BackupAndUpdate;")
        /system scheduler add name=BKPUPD-NEXT-BOOT-TASK on-event=$scheduledCommand start-time=startup interval=0
      }

      /system package update install
    } on-error={
      # Failed to install new os version, remove the task
      :do {/system scheduler remove BKPUPD-NEXT-BOOT-TASK} on-error={}

      :log error "$SMP Failed to install new RouterOS version. Please check device logs for more details."

      :error $exitErrorMessage
    }
  }
}

## STEP 2: Routerboard firmware update.
:if ($scriptStep = 2) do={
  :log info "$SMP The script is in the second step, updating Routerboard firmware."

  :log info "$SMP Upgrading routerboard firmware from v.$deviceRbCurrentFw to v.$deviceRbUpgradeFw"

  /system routerboard upgrade
  :delay 2s

  :log info "$SMP routerboard upgrade process was completed, going to reboot in a moment!"

  /system reboot
}
:log info "$SMP the script has finished, script step: `$scriptStep` \n\n"

; NSIS Modern Installer Script for Dev-C++ 7.0 Modern
; Generates: 64-bit Windows installer with portable mode support

; ---- Basic Setup ----
Title "Dev-C++ 7.0 Modern"
Version 7.0
 ; Recommended to use Unicode encoding for international support
 Unicode true
InstallDir "$PROGRAMFILES64\Dev-C++"
InstallDirRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Dev-C++"
 ; Use our custom languages
 ; Request execution level for file operations
 RequestExecutionLevel admin

; ---- Output Options ----
 ; Installer download progress
 ProgressPrint /2
 ; Show/mask the instFiles progress
 DetailPrint

; ---- Page Setup ----
Page welcome WelcomePage
Page directory DirectoryPage
Page components ComponentsPage
Page finish FinishPage

; ---- Installer Menu ----
 ; Show the installer menu (Back, Next, Cancel)
 ; Set multicenter to show component selection
 ; Set brand bitmap (optional)
 ; Set add logo (optional)

; ---- Installer Information ----
 ; Set the installer output base filename
 ; SetOutputDir (not needed - we use default)
 ; SetCaption (optional)
 ; SetDetailsInfo (optional)

; ---- Default Language ----
 !include Languages.nsh
 !include FileFunc.nsh
 !include StringUtils.nsh
 !include Sections.nsh
 !include Font.nsh

; ---- Define installer configuration ----
 Define MENU_NAME
 Define MENU_HEIGHT
 Define PAGE_NAME
 Define WELCOME_TEXT
 Define Directory_Name
 Define Components_Name
 Define FINISH_TEXT

; Set the default installer text
 ; Welcome page text
 !define WELCOME_TEXT "Welcome to the Dev-C++ 7.0 Modern installer."
 !define Directory_Name "Select Destination Location"
 !define Components_Name "Select Components"
 !define FINISH_TEXT "The installation was completed successfully."

; ---- Set default installer pages ----
; Welcome page settings
 !define WELCOME_FORCE show
 !define WELCOME_TEXT_WORD_WRAP show

; ---- installerUI ----
 ; Show the "Details" section on the welcome page
 !define INSTUI_STYLE modern

; ---- String definitions ----
 ; Installer prompt text
 !define PROMPT_QUESTION "Please answer the question below."
 !define PROMPT_OK "OK"
 !define PROMPT_CANCEL "Cancel"

; ---- Sections ----
Section /e "Installation"
  ; Set the installation directory
  SetOutDir "$INSTDIR"
  ; Set the menu name
  SetMName "Dev-C++"
  SetMDesc "Modern C++ IDE"
  
  ; ---- Default compiler toolchain binding ----
  ; Bind GCC 14.2 (UCRT) by default
  ; This creates a devcpp.ini setting for portable mode or registry key for installed mode
  WriteRegStr HKLM "Software\Dev-C++\Toolchain" "DefaultProfile" "tcpGCC14UCRT"
  WriteRegStr HKLM "Software\Dev-C++\Toolchain" "GCCVersion" "14.2.0"
  WriteRegStr HKLM "Software\Dev-C++\Toolchain" "UCRT" "1"
  
  ; ---- File associations ----
  ; Associate .c, .cpp, .h, .hpp, .dev file types with Dev-C++
  WriteRegStr HKCR ".c" "Dev-C++ Source File" "Dev-C++ IDE"
  WriteRegStr HKCR ".cpp" "Dev-C++ Source File" "Dev-C++ IDE"
  WriteRegStr HKCR ".h" "Dev-C++ Header File" "Dev-C++ IDE"
  WriteRegStr HKCR ".hpp" "Dev-C++ Header File" "Dev-C++ IDE"
  WriteRegStr HKCR ".dev" "Dev-C++ Project File" "Dev-C++ IDE"
  
  ; Set default file type icon and open command
  WriteRegStr HKCR "Dev-C++ Source File" "" "Dev-C++ IDE Source File"
  WriteRegStr HKCR "Dev-C++ Source File\Shell\Open\Command" "" '"$INSTDIR\devcpp.exe" "%1"'
  WriteRegStr HKCR "Dev-C++ Header File" "" "Dev-C++ IDE Header File"
  WriteRegStr HKCR "Dev-C++ Header File\Shell\Open\Command" "" '"$INSTDIR\devcpp.exe" "%1"'
  WriteRegStr HKCR "Dev-C++ Project File" "" "Dev-C++ IDE Project File"
  WriteRegStr HKCR "Dev-C++ Project File\Shell\Open\Command" "" '"$INSTDIR\devcpp.exe" "%1"'
  
  ; ---- Create Start Menu shortcuts ----
  ; Create folder in Start Menu
  SetShellDir create
  SetShellFolder "StartMenu" "$SMPROGRAMS\Dev-C++"
  ; Create shortcut for the IDE
  CreateDirectory "$SMPROGRAMS\Dev-C++"
  ; Main IDE shortcut
  $MyDocs = $SPECIALDESKTOP
  ; Create Desktop shortcut (optional)
  ; SendTo /all /N "$SSENDTO\Dev-C++.lnk"
  
  ; Create Start Menu entry
  WriteLnk "$SMPROGRAMS\Dev-C++\Dev-C++.lnk" "$INSTDIR\devcpp.exe" ""
  ; WriteLnk creates a link with the target, parameters, and description
  
  ; Add uninstall information to the registry for Add/Remove Programs
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Dev-C++" "DisplayName" "Dev-C++ 7.0 Modern"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Dev-C++" "DisplayIcon" "$INSTDIR\devcpp.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Dev-C++" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Dev-C++" "Publisher" "Dev-C++ Team"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Dev-C++" "InstallDate" "%YYYYMMDD%"
  
  ; ---- Portable mode support ----
  ; Check if portable mode is requested (via /PORTABLE switch)
  ; If portable mode, don't write to registry (except for uninstall info)
  ; and redirect user data to the installation directory
  SectionEnd

Section "PortableMode"
  ; Portable mode: install to UBS drive or specified dir
  ; No registry writes except uninstall info
  ; User configs go to .ini alongside executable
  
  ; Set installation directory (same as above, but skip registry writes for config)
  SetOutDir "$INSTDIR"
  
  ; Skip default compiler toolchain registry writes
  ; User will provide their own toolchain or use default from .ini
  
  ; File associations still apply for portable mode
  WriteRegStr HKCR ".c" "Dev-C++ Source File" "Dev-C++ IDE"
  WriteRegStr HKCR ".cpp" "Dev-C++ Source File" "Dev-C++ IDE"
  WriteRegStr HKCR ".h" "Dev-C++ Header File" "Dev-C++ IDE"
  WriteRegStr HKCR ".hpp" "Dev-C++ Header File" "Dev-C++ IDE"
  WriteRegStr HKCR ".dev" "Dev-C++ Project File" "Dev-C++ IDE"
  
  ; Create portable.ini with default settings
  File ..\..\devcpp.ini "$INSTDIR\devcpp.ini"
  
  ; Create portable mode uninstall info
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Dev-C++" "DisplayName" "Dev-C++ 7.0 Modern (Portable)"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Dev-C++" "DisplayIcon" "$INSTDIR\devcpp.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Dev-C++" "UninstallString" '"$INSTDIR\uninstall.exe" /PORTABLE'
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Dev-C++" "Publisher" "Dev-C++ Team"
  
SectionEnd

; ---- Request execution level ----
; Already set to admin at the top

; ---- Post-installation tasks ----
; Ensure the executable has necessary permissions
; Register the file type associations
; etc.

; ---- Function to handle portable vs installed mode -Function .onInit
  ; Check for /PORTABLE switch
  PushParameters
  FindSwitches /PORTABLE
  PopParameters
  Pop $0
  ; If /PORTABLE was used, set a flag or adjust behavior
  ; We'll handle this in the section logic above
FunctionEnd

; ---- Finalization ----
; Post-install message
MessageBox MB_OK "Dev-C++ 7.0 Modern has been installed successfully." IDOK

; vim: set ts=2 sw=2 :
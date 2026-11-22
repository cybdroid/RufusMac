import Foundation

public struct AutoUnattendPlan: Sendable, Equatable {
    /// Relative path on the Windows USB volume:
    /// - `"autounattend.xml"` when `windowsPE` hardware bypasses (TPM/SecureBoot/RAM) are enabled
    /// - `"sources/$OEM$/$$/Panther/unattend.xml"` when only `specialize`/`oobeSystem` tweaks are enabled
    ///   (keeps WinPE 100% untouched so Windows Setup never triggers ProductKey errors on multi-edition ISOs!)
    public let relativePath: String
    public let xmlContent: String
    public let shouldPatchAppraiserRes: Bool

    public init(relativePath: String, xmlContent: String, shouldPatchAppraiserRes: Bool) {
        self.relativePath = relativePath
        self.xmlContent = xmlContent
        self.shouldPatchAppraiserRes = shouldPatchAppraiserRes
    }
}

public enum AutoUnattendGenerator {

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func sanitizeWindowsUsername(_ raw: String) -> String {
        let disallowedNames: Set<String> = [
            "administrator", "admin", "guest", "defaultaccount", "wdagutilityaccount",
            "system", "localservice", "networkservice", "con", "prn", "aux", "nul"
        ]
        let invalidChars = CharacterSet(charactersIn: "\"/\\[]:;|=,+*?<>@")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedScalars = trimmed.unicodeScalars.map { invalidChars.contains($0) ? "_" : String($0) }
        var cleaned = cleanedScalars.joined().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if cleaned.count > 20 {
            cleaned = String(cleaned.prefix(20))
        }
        if cleaned.isEmpty || disallowedNames.contains(cleaned.lowercased()) {
            cleaned = "User"
        }
        return cleaned
    }

    /// Generates the Rufus-compatible unattend plan (matching Rufus `src/wue.c` rules for WinPE ProductKey,
    /// `$OEM$/$$/Panther/unattend.xml` placement, and official Base64 blank password encoding).
    public static func generatePlan(options: WindowsCustomizationOptions, architecture: String = "amd64") -> AutoUnattendPlan? {
        guard options.isAnyEnabled else { return nil }

        let arch = architecture.lowercased() == "arm64" ? "arm64" : (architecture.lowercased() == "x86" ? "x86" : "amd64")

        var xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">

        """

        // 1. windowsPE pass: ONLY emitted when TPM/SecureBoot/RAM bypass is enabled.
        //    CRITICAL: Must include <UserData><AcceptEula>true</AcceptEula><ProductKey><Key></Key><WillShowUI>OnError</WillShowUI></ProductKey></UserData>
        //    otherwise Windows 10/11 WinPE crashes with "Windows cannot read the <ProductKey> setting from the unattend answer file" and reboots!
        if options.bypassHardwareChecks {
            xml += """
                <settings pass="windowsPE">
                    <component name="Microsoft-Windows-Setup" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                        <UserData>
                            <AcceptEula>true</AcceptEula>
                            <ProductKey>
                                <Key></Key>
                                <WillShowUI>OnError</WillShowUI>
                            </ProductKey>
                        </UserData>
                        <RunSynchronous>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>1</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>2</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>3</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>4</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>5</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                        </RunSynchronous>
                    </component>
                </settings>

            """
        }

        // 2. specialize pass: BypassNRO for offline/local account setup
        if options.bypassMicrosoftAccount {
            xml += """
                <settings pass="specialize">
                    <component name="Microsoft-Windows-Deployment" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                        <RunSynchronous>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>1</Order>
                                <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                        </RunSynchronous>
                    </component>
                </settings>

            """
        }

        // 3. oobeSystem pass: Local account and/or privacy & telemetry skip
        if options.bypassMicrosoftAccount || options.disablePrivacyQuestions {
            xml += """
                <settings pass="oobeSystem">
                    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

            """

            if options.disablePrivacyQuestions || options.bypassMicrosoftAccount {
                xml += """
                        <OOBE>

                """
                if options.disablePrivacyQuestions {
                    xml += """
                                <HideEULAPage>true</HideEULAPage>
                                <ProtectYourPC>3</ProtectYourPC>

                    """
                }
                if options.bypassMicrosoftAccount {
                    xml += """
                                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>

                    """
                }
                xml += """
                        </OOBE>

                """
            }

            if options.bypassMicrosoftAccount {
                let cleanName = xmlEscape(sanitizeWindowsUsername(options.localAccountUsername))
                // Official Microsoft Base64 UTF-16LE encoding for a blank password ("Password" -> UABhAHMAcwB3AG8AcgBkAA==), matching Rufus src/wue.c
                xml += """
                        <UserAccounts>
                            <LocalAccounts>
                                <LocalAccount wcm:action="add">
                                    <Name>\(cleanName)</Name>
                                    <DisplayName>\(cleanName)</DisplayName>
                                    <Group>Administrators;Power Users</Group>
                                    <Password>
                                        <Value>UABhAHMAcwB3AG8AcgBkAA==</Value>
                                        <PlainText>false</PlainText>
                                    </Password>
                                </LocalAccount>
                            </LocalAccounts>
                        </UserAccounts>

                """
            }

            xml += """
                    </component>
                </settings>

            """
        }

        xml += "</unattend>\n"

        // Follow Rufus's exact placement strategy (src/wue.c):
        // - If `windowsPE` pass is present -> write root `autounattend.xml` (WinPE reads it at boot & carries it into Panther).
        // - If NO `windowsPE` pass -> write `sources/$OEM$/$$/Panther/unattend.xml` so WinPE stays 100% stock & Windows copies it to %WINDIR%\Panther\unattend.xml!
        let targetRelPath = options.bypassHardwareChecks
            ? "autounattend.xml"
            : "sources/$OEM$/$$/Panther/unattend.xml"

        return AutoUnattendPlan(
            relativePath: targetRelPath,
            xmlContent: xml,
            shouldPatchAppraiserRes: options.bypassHardwareChecks
        )
    }

    /// Convenience wrapper returning only the XML content.
    public static func generate(options: WindowsCustomizationOptions, architecture: String = "amd64") -> String? {
        generatePlan(options: options, architecture: architecture)?.xmlContent
    }
}

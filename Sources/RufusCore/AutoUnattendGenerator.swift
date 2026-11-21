import Foundation

public enum AutoUnattendGenerator {

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Generates a valid Microsoft `autounattend.xml` for Windows 10/11 Setup based on selected options.
    /// Returns nil if no customization option is enabled.
    public static func generate(options: WindowsCustomizationOptions, architecture: String = "amd64") -> String? {
        guard options.isAnyEnabled else { return nil }

        let arch = architecture.lowercased() == "arm64" ? "arm64" : (architecture.lowercased() == "x86" ? "x86" : "amd64")

        var xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">

        """

        // 1. windowsPE pass: Bypass TPM 2.0, Secure Boot, RAM, CPU checks via LabConfig registry keys
        if options.bypassHardwareChecks {
            xml += """
                <settings pass="windowsPE">
                    <component name="Microsoft-Windows-Setup" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
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

        // 2. specialize pass: Set BypassNRO for Windows 11 OOBE offline local account support
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

        // 3. oobeSystem pass: Local account and/or privacy & telemetry bypass
        if options.bypassMicrosoftAccount || options.disablePrivacyQuestions {
            xml += """
                <settings pass="oobeSystem">
                    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
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

            if options.bypassMicrosoftAccount {
                let rawName = options.localAccountUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanName = xmlEscape(rawName.isEmpty ? "User" : String(rawName.prefix(20)))
                xml += """
                        <UserAccounts>
                            <LocalAccounts>
                                <LocalAccount wcm:action="add">
                                    <Name>\(cleanName)</Name>
                                    <DisplayName>\(cleanName)</DisplayName>
                                    <Group>Administrators</Group>
                                    <Password>
                                        <Value></Value>
                                        <PlainText>true</PlainText>
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
        return xml
    }
}

import Foundation
import RufusCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func assertTrue(_ condition: Bool, _ msg: String) throws {
    if !condition { throw TestFailure(description: "Assertion failed: \(msg)") }
}

private func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "") throws {
    if a != b { throw TestFailure(description: "Expected '\(b)', got '\(a)' \(msg)") }
}

private func repoHelpersDir() -> String {
    let fileURL = URL(fileURLWithPath: #filePath)
    let repoRoot = fileURL
        .deletingLastPathComponent() // SelfTest
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // RufusMac
    return repoRoot.appendingPathComponent("build/helpers").path
}

private var passed = 0
private var failed = 0

private func runTest(_ name: String, _ block: () throws -> Void) {
    do {
        try block()
        print("  [PASS] \(name)")
        passed += 1
    } catch {
        print("  [FAIL] \(name) -> \(error)")
        failed += 1
    }
}

print("=== RufusMac End-to-End Verification Suite ===")
let helpersDir = repoHelpersDir()

// 1. Disk Protection & Safety
runTest("Protected disks exclude macOS boot disk (disk0/disk1) and internal drives") {
    let protected = DiskDiscovery.protectedWholeDisks()
    try assertTrue(!protected.isEmpty, "protectedWholeDisks must not be empty")
    print("         Protected system disks: \(protected.sorted().joined(separator: ", "))")

    let drives = try DiskDiscovery.discoverDrives(includeFixedExternalUSB: true)
    print("         Discovered safe USB drives: \(drives.map { "\($0.deviceIdentifier) (\($0.mediaName), \($0.formattedSize))" }.joined(separator: "; "))")
    for drive in drives {
        try assertTrue(!protected.contains(drive.deviceIdentifier), "Protected disk \(drive.deviceIdentifier) leaked!")
        try assertTrue(drive.isExternal, "Internal disk leaked!")
    }

    for p in protected {
        var threw = false
        do {
            try DiskDiscovery.validateSafeTarget(deviceIdentifier: p, allowDiskImage: false)
        } catch {
            threw = true
        }
        try assertTrue(threw, "validateSafeTarget MUST reject protected disk \(p)!")
    }
}

// 2. Whole disk identifier parsing
runTest("Whole disk identifier parsing") {
    try assertEqual(DiskDiscovery.wholeDiskIdentifier(from: "disk0s3"), "disk0")
    try assertEqual(DiskDiscovery.wholeDiskIdentifier(from: "/dev/disk1s4s1"), "disk1")
    try assertEqual(DiskDiscovery.wholeDiskIdentifier(from: "/dev/rdisk12s2"), "disk12")
    try assertEqual(DiskDiscovery.wholeDiskIdentifier(from: "disk9"), "disk9")
}

// 3. Volume label sanitizer
runTest("Volume label sanitizer (FAT32 / ExFAT / APFS)") {
    try assertEqual(VolumeLabelSanitizer.sanitize("Windows 11 x64 DE!", for: .fat32), "WINDOWS 11")
    try assertEqual(VolumeLabelSanitizer.sanitize("Win10_22H2_German_x64v1", for: .fat32), "WIN10_22H2")
    try assertEqual(VolumeLabelSanitizer.sanitize("cccoma_x64fre_de-de", for: .fat32), "CCCOMA_X64F")
    try assertEqual(VolumeLabelSanitizer.sanitize("   ", for: .fat32), "RUFUSMAC")
    try assertEqual(VolumeLabelSanitizer.sanitize("Win11:Pro/Test", for: .exfat), "Win11ProTest")
    try assertEqual(VolumeLabelSanitizer.sanitize("My Mac Drive", for: .apfs), "My Mac Drive")
}

// 4. AutoUnattend XML generator
runTest("AutoUnattend XML generation (ProductKey-safe WinPE + Panther/unattend.xml + BypassNRO + Privacy)") {
    try assertTrue(AutoUnattendGenerator.generatePlan(options: WindowsCustomizationOptions()) == nil, "Empty options should return nil")

    // Case A: Hardware bypass enabled -> root autounattend.xml WITH mandatory ProductKey block + AcceptEula!
    let optsWithBypass = WindowsCustomizationOptions(
        bypassHardwareChecks: true,
        bypassMicrosoftAccount: true,
        localAccountUsername: "Jonas & User",
        disablePrivacyQuestions: true
    )
    guard let planA = AutoUnattendGenerator.generatePlan(options: optsWithBypass) else {
        throw TestFailure(description: "Expected non-nil planA")
    }
    try assertEqual(planA.relativePath, "autounattend.xml")
    try assertTrue(planA.shouldPatchAppraiserRes, "Should patch appraiserres.dll when bypassHardwareChecks is enabled")
    let xml = planA.xmlContent
    try assertTrue(xml.contains("<AcceptEula>true</AcceptEula>"), "Missing AcceptEula in windowsPE UserData")
    try assertTrue(xml.contains("<ProductKey>"), "Missing mandatory ProductKey block in windowsPE (causes Setup reboot error!)")
    try assertTrue(xml.contains("<Key></Key>"), "Missing empty <Key></Key> element inside ProductKey")
    try assertTrue(xml.contains("<WillShowUI>OnError</WillShowUI>"), "Missing WillShowUI OnError inside ProductKey")
    try assertTrue(xml.contains("BypassTPMCheck"), "Missing BypassTPMCheck")
    try assertTrue(xml.contains("BypassSecureBootCheck"), "Missing BypassSecureBootCheck")
    try assertTrue(xml.contains("BypassRAMCheck"), "Missing BypassRAMCheck")
    try assertTrue(xml.contains("BypassNRO"), "Missing BypassNRO")
    try assertTrue(xml.contains("<Name>Jonas &amp; User</Name>"), "XML escaping failed")
    try assertTrue(xml.contains("UABhAHMAcwB3AG8AcgBkAA=="), "Missing official Microsoft Base64 blank password")
    try assertTrue(xml.contains("<ProtectYourPC>3</ProtectYourPC>"), "Missing ProtectYourPC")

    let docA = try XMLDocument(xmlString: xml, options: [])
    try assertEqual(docA.rootElement()?.name ?? "", "unattend")

    // Case B: OOBE/Privacy only (no WinPE hardware bypass) -> sources/$OEM$/$$/Panther/unattend.xml with NO windowsPE pass!
    let optsOobeOnly = WindowsCustomizationOptions(
        bypassHardwareChecks: false,
        bypassMicrosoftAccount: true,
        localAccountUsername: "Jonas",
        disablePrivacyQuestions: true
    )
    guard let planB = AutoUnattendGenerator.generatePlan(options: optsOobeOnly) else {
        throw TestFailure(description: "Expected non-nil planB")
    }
    try assertEqual(planB.relativePath, "sources/$OEM$/$$/Panther/unattend.xml")
    try assertTrue(!planB.shouldPatchAppraiserRes, "Should NOT patch appraiserres.dll when bypassHardwareChecks is false")
    try assertTrue(!planB.xmlContent.contains("pass=\"windowsPE\""), "Must NOT include windowsPE pass when bypassHardwareChecks is false")
    let docB = try XMLDocument(xmlString: planB.xmlContent, options: [])
    try assertEqual(docB.rootElement()?.name ?? "", "unattend")
}

// 5. ISO Inspector & Streaming Checksums
runTest("ISO inspection (Windows 11) and MD5/SHA-1/SHA-256 checksums") {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rufusmac-test-iso-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    try FileManager.default.createDirectory(at: tmp.appendingPathComponent("sources"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tmp.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)

    try Data("bootmgr".utf8).write(to: tmp.appendingPathComponent("bootmgr"))
    try Data("setup".utf8).write(to: tmp.appendingPathComponent("setup.exe"))
    try Data("bootwim".utf8).write(to: tmp.appendingPathComponent("sources/boot.wim"))
    try Data("installwim".utf8).write(to: tmp.appendingPathComponent("sources/install.wim"))
    try Data("appraiser".utf8).write(to: tmp.appendingPathComponent("sources/appraiserres.dll"))
    try Data("efi".utf8).write(to: tmp.appendingPathComponent("efi/boot/bootx64.efi"))

    let analysis = ISOInspector.inspectMountedDirectory(
        mountPoint: tmp.path,
        filePath: "/fake/Win11_24H2_German_x64.iso",
        fileName: "Win11_24H2_German_x64.iso",
        fileSize: 6_000_000_000,
        hasHybridMBR: false
    )
    try assertEqual(analysis.kind, .windowsISO)
    try assertTrue(analysis.isWindows11Likely, "Should detect Win11")
    try assertEqual(analysis.windowsArchitecture ?? "", "x64")
    try assertTrue(analysis.hasUEFIBootloader, "Missing UEFI flag")
    try assertTrue(analysis.hasLegacyBIOSBootloader, "Missing BIOS flag")

    let hashFile = tmp.appendingPathComponent("sample.bin")
    try Data("hello world\n".utf8).write(to: hashFile)
    let sums = try ISOInspector.computeChecksums(filePath: hashFile.path) { _ in }
    try assertEqual(sums.sha256, "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447")
    try assertEqual(sums.md5, "6f5902ac237024bdd0c176cb93063dc4")
    try assertEqual(sums.sha1, "22596363b3de40b06f981fb85d82312e8c0ed511")
}

// 6. Bundled wimlib-imagex real WIM capture & split
runTest("Bundled wimlib-imagex captures and splits a real WIM into .swm parts") {
    let wimlib = "\(helpersDir)/wimlib-imagex"
    try assertTrue(FileManager.default.isExecutableFile(atPath: wimlib), "wimlib-imagex missing at \(wimlib)")

    let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("rufusmac-wim-\(UUID().uuidString)")
    let srcDir = workDir.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    var rng = SystemRandomNumberGenerator()
    for i in 1...2 {
        var bytes = [UInt8](repeating: 0, count: 2 * 1024 * 1024)
        for j in stride(from: 0, to: bytes.count, by: 8) {
            let v = rng.next()
            withUnsafeBytes(of: v) { ptr in
                for k in 0..<8 { bytes[j + k] = ptr[k] }
            }
        }
        try Data(bytes).write(to: srcDir.appendingPathComponent("payload_\(i).bin"))
    }

    let wimFile = workDir.appendingPathComponent("install.wim").path
    let swmFile = workDir.appendingPathComponent("install.swm").path

    _ = try DiskDiscovery.runProcess(wimlib, arguments: ["capture", srcDir.path, wimFile, "TestWin", "--compress=none"])
    try assertTrue(FileManager.default.fileExists(atPath: wimFile), "install.wim not created")

    _ = try DiskDiscovery.runProcess(wimlib, arguments: ["split", wimFile, swmFile, "2"])
    try assertTrue(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("install.swm").path), "install.swm missing")
    try assertTrue(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("install2.swm").path), "install2.swm missing")
}

// 7. Full End-to-End Virtual Disk Flashing (GPT FAT32, GPT Dual-Partition, MBR+ms-sys NT6, DD Raw)
runTest("End-to-End Virtual Disk Flashing: GPT FAT32, GPT Dual-Partition, MBR NT6+Active, DD Raw") {
    let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("rufusmac-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    // Create real synthetic Windows UDF ISO
    let isoSrcDir = workDir.appendingPathComponent("win_iso_root")
    try FileManager.default.createDirectory(at: isoSrcDir.appendingPathComponent("sources"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: isoSrcDir.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: isoSrcDir.appendingPathComponent("boot"), withIntermediateDirectories: true)

    try Data("BOOTMGR_BIN".utf8).write(to: isoSrcDir.appendingPathComponent("bootmgr"))
    try Data("SETUP_EXE".utf8).write(to: isoSrcDir.appendingPathComponent("setup.exe"))
    try Data("EFI_BOOTX64".utf8).write(to: isoSrcDir.appendingPathComponent("efi/boot/bootx64.efi"))
    try Data("BCD_DATA".utf8).write(to: isoSrcDir.appendingPathComponent("boot/bcd"))
    try Data(repeating: 0xAB, count: 128 * 1024).write(to: isoSrcDir.appendingPathComponent("sources/boot.wim"))
    try Data(repeating: 0xCD, count: 256 * 1024).write(to: isoSrcDir.appendingPathComponent("sources/install.wim"))

    let isoURL = workDir.appendingPathComponent("TestWin11.iso")
    _ = try DiskDiscovery.runProcess("/usr/bin/hdiutil", arguments: [
        "makehybrid", "-udf", "-udf-volume-name", "WIN11_TEST",
        "-o", isoURL.path, isoSrcDir.path
    ])
    let inspected = try ISOInspector.inspect(filePath: isoURL.path)
    try assertEqual(inspected.kind, .windowsISO)

    // Create 2 GB sparse virtual disk pre-filled with raw UDF Windows ISO at sector 0 (simulating Balena Etcher on a real >1 GB USB stick where macOS GPT creates s1=EFI + s2=Data!)
    let vdiskURL = workDir.appendingPathComponent("virtual_usb.img")
    try FileManager.default.copyItem(at: isoURL, to: vdiskURL)
    let vfh = try FileHandle(forWritingTo: vdiskURL)
    try vfh.truncate(atOffset: 2 * 1024 * 1024 * 1024)
    try vfh.close()

    // Verify GPT FAT32 and Dual-Partition require ZERO root privileges!
    let sampleGPTConfig = FlashJobConfig(
        targetDeviceIdentifier: "disk99",
        bootMode: .isoOrImage,
        writeMode: .isoFileCopy,
        isoPath: isoURL.path,
        isoKind: .windowsISO,
        partitionScheme: .gpt,
        fileSystem: .fat32,
        volumeLabel: "WIN10_22H2",
        clusterSize: .automatic,
        quickFormat: true,
        wipePartitionTable: true,
        autoEjectAfterFlash: false,
        windowsOptions: WindowsCustomizationOptions()
    )
    try assertTrue(!FlashEngine.requiresRootForWholeJob(sampleGPTConfig), "GPT FAT32 must NOT require root!")
    try assertTrue(!FlashEngine.needsMBRBootSectorPhase2(sampleGPTConfig), "GPT FAT32 must NOT require MBR phase 2!")

    let attachOut = try DiskDiscovery.runProcess("/usr/bin/hdiutil", arguments: [
        "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", vdiskURL.path
    ])
    let devNode = String(data: attachOut, encoding: .utf8)!
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .whitespaces)
        .first!
    let diskId = DiskDiscovery.wholeDiskIdentifier(from: devNode)
    defer { ISOInspector.detach(deviceNode: devNode) }

    // A) GPT + FAT32 + autounattend.xml (using TCC-safe preMountedISOPath flow!)
    let preMounted = try ISOInspector.attachReadOnly(isoPath: isoURL.path)
    defer { ISOInspector.detach(preMounted) }
    try assertEqual(preMounted.volumeName, "WIN11_TEST", "Real UDF VolumeName must be extracted, not temp dir name!")

    var eventsA: [FlashProgressEvent] = []
    let engineA = FlashEngine(emit: { eventsA.append($0) }, isCancelled: { false })
    try engineA.execute(config: FlashJobConfig(
        targetDeviceIdentifier: diskId,
        bootMode: .isoOrImage,
        writeMode: .isoFileCopy,
        isoPath: isoURL.path,
        preMountedISOPath: preMounted.mountPoint,
        isoKind: .windowsISO,
        partitionScheme: .gpt,
        fileSystem: .fat32,
        volumeLabel: "WIN11GPT",
        clusterSize: .automatic,
        quickFormat: true,
        wipePartitionTable: true,
        autoEjectAfterFlash: false,
        windowsOptions: WindowsCustomizationOptions(bypassHardwareChecks: true, bypassMicrosoftAccount: true, localAccountUsername: "Jonas"),
        helpersDirectory: helpersDir,
        allowDiskImageTarget: true
    ))
    try assertTrue(eventsA.contains { $0.kind == .completed }, "GPT FAT32 did not complete")
    let slicesA = try engineA.discoverDataPartitionSlices(for: devNode, expectedMinimum: 1)
    try assertEqual(slicesA.count, 1, "Expected 1 data partition on single-partition GPT")
    let infoA = try DiskDiscovery.runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", slicesA[0]])
    let dictA = (try PropertyListSerialization.propertyList(from: infoA, format: nil) as? [String: Any]) ?? [:]
    try assertTrue((dictA["Content"] as? String) != "EFI", "Data slice must NEVER be EFI!")
    let mountA = (dictA["MountPoint"] as? String) ?? ""
    try assertTrue(FileManager.default.fileExists(atPath: "\(mountA)/efi/boot/bootx64.efi"), "Missing bootx64.efi on GPT FAT32")
    try assertTrue(FileManager.default.fileExists(atPath: "\(mountA)/sources/install.wim"), "Missing install.wim on GPT FAT32")
    try assertTrue(FileManager.default.fileExists(atPath: "\(mountA)/autounattend.xml"), "Missing autounattend.xml on GPT FAT32")
    print("         [sub-check] 2GB GPT (\(slicesA[0])=FAT32) + preMountedISOPath + autounattend.xml OK")

    // Also verify read-only EFI-skipping on real physical GPT disk if disk6 currently has EFI+Data
    if let realSlices = try? engineA.discoverDataPartitionSlices(for: "/dev/disk6", expectedMinimum: 1),
       realSlices.contains("/dev/disk6s2") {
        try assertTrue(!realSlices.contains("/dev/disk6s1"), "EFI partition disk6s1 must be skipped!")
        print("         [sub-check] Real physical GPT /dev/disk6 EFI-skip verified -> \(realSlices)")
    }

    // B) GPT Dual-Partition (FAT32 Boot + ExFAT Data)
    var eventsB: [FlashProgressEvent] = []
    let engineB = FlashEngine(emit: { eventsB.append($0) }, isCancelled: { false })
    try engineB.execute(config: FlashJobConfig(
        targetDeviceIdentifier: diskId,
        bootMode: .isoOrImage,
        writeMode: .isoFileCopy,
        isoPath: isoURL.path,
        isoKind: .windowsISO,
        partitionScheme: .gpt,
        fileSystem: .dualFat32ExFAT,
        volumeLabel: "WIN11DATA",
        clusterSize: .automatic,
        quickFormat: true,
        wipePartitionTable: true,
        autoEjectAfterFlash: false,
        windowsOptions: WindowsCustomizationOptions(bypassHardwareChecks: true),
        helpersDirectory: helpersDir,
        allowDiskImageTarget: true
    ))
    try assertTrue(eventsB.contains { $0.kind == .completed }, "Dual-Partition did not complete")
    let slicesB = try engineB.discoverDataPartitionSlices(for: devNode, expectedMinimum: 2)
    try assertEqual(slicesB.count, 2, "Expected 2 data partitions on Dual-Partition GPT")
    let infoB1 = try DiskDiscovery.runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", slicesB[0]])
    let infoB2 = try DiskDiscovery.runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", slicesB[1]])
    let mountB1 = ((try PropertyListSerialization.propertyList(from: infoB1, format: nil) as? [String: Any])?["MountPoint"] as? String) ?? ""
    let mountB2 = ((try PropertyListSerialization.propertyList(from: infoB2, format: nil) as? [String: Any])?["MountPoint"] as? String) ?? ""
    try assertTrue(FileManager.default.fileExists(atPath: "\(mountB1)/efi/boot/bootx64.efi"), "Missing bootx64.efi on Boot FAT32")
    try assertTrue(FileManager.default.fileExists(atPath: "\(mountB1)/sources/boot.wim"), "Missing boot.wim on Boot FAT32")
    try assertTrue(!FileManager.default.fileExists(atPath: "\(mountB1)/sources/install.wim"), "install.wim should be excluded from FAT32 boot partition")
    try assertTrue(FileManager.default.fileExists(atPath: "\(mountB2)/sources/install.wim"), "Missing install.wim on ExFAT data partition")
    try assertTrue(FileManager.default.fileExists(atPath: "\(mountB2)/autounattend.xml"), "Missing autounattend.xml on ExFAT data partition")
    print("         [sub-check] 2GB GPT Dual-Partition (\(slicesB[0])=FAT32 Boot, \(slicesB[1])=ExFAT Data) OK")

    // C) MBR + FAT32 + Windows NT6 MBR/VBR + Active Flag 0x80
    var eventsC: [FlashProgressEvent] = []
    try FlashEngine(emit: { eventsC.append($0) }, isCancelled: { false }).execute(config: FlashJobConfig(
        targetDeviceIdentifier: diskId,
        bootMode: .isoOrImage,
        writeMode: .isoFileCopy,
        isoPath: isoURL.path,
        isoKind: .windowsISO,
        partitionScheme: .mbr,
        fileSystem: .fat32,
        volumeLabel: "WIN11MBR",
        clusterSize: .automatic,
        quickFormat: true,
        wipePartitionTable: true,
        autoEjectAfterFlash: false,
        windowsOptions: WindowsCustomizationOptions(),
        helpersDirectory: helpersDir,
        allowDiskImageTarget: true
    ))
    try assertTrue(eventsC.contains { $0.kind == .completed }, "MBR FAT32 did not complete")

    _ = try DiskDiscovery.runProcess("/usr/sbin/diskutil", arguments: ["unmountDisk", "force", devNode])
    let msSys = "\(helpersDir)/ms-sys"
    let mbrInspect = String(data: try DiskDiscovery.runProcess(msSys, arguments: [devNode]), encoding: .utf8) ?? ""
    let vbrInspect = String(data: try DiskDiscovery.runProcess(msSys, arguments: ["\(devNode)s1"]), encoding: .utf8) ?? ""
    try assertTrue(mbrInspect.contains("Microsoft 7 master boot record"), "Expected Win7/10/11 MBR: \(mbrInspect)")
    try assertTrue(!mbrInspect.contains("0x00000000"), "Expected non-zero disk signature")
    try assertTrue(vbrInspect.contains("FAT32 NT6.0 boot record"), "Expected FAT32 NT6 BOOTMGR VBR: \(vbrInspect)")

    let mbrFH = try FileHandle(forReadingFrom: URL(fileURLWithPath: devNode))
    let sector0 = mbrFH.readData(ofLength: 512)
    try mbrFH.close()
    try assertEqual(sector0[446], 0x80, "MBR Partition 1 active flag must be 0x80")
    print("         [sub-check] MBR + Windows NT6 MBR/VBR + Active Flag 0x80 OK")

    // D) DD Raw Image Mode via TCC-safe FIFO pipe
    let rawPayload = workDir.appendingPathComponent("raw_test.img")
    let pattern = Data((0..<1_048_576).map { UInt8($0 % 251) })
    try pattern.write(to: rawPayload)

    let fifoPath = workDir.appendingPathComponent("raw_test.fifo").path
    try assertEqual(mkfifo(fifoPath, 0o666), 0, "mkfifo failed")
    DispatchQueue.global(qos: .userInitiated).async {
        let fd = open(fifoPath, O_WRONLY)
        if fd >= 0 {
            pattern.withUnsafeBytes { rawBuf in
                var off = 0
                while off < pattern.count {
                    let n = write(fd, rawBuf.baseAddress!.advanced(by: off), pattern.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(fd)
        }
    }

    try FlashEngine(emit: { _ in }, isCancelled: { false }).execute(config: FlashJobConfig(
        targetDeviceIdentifier: diskId,
        bootMode: .isoOrImage,
        writeMode: .ddRawImage,
        isoPath: rawPayload.path,
        rawFifoPath: fifoPath,
        rawInputSizeBytes: Int64(pattern.count),
        isoKind: .rawDiskImage,
        partitionScheme: .gpt,
        fileSystem: .fat32,
        volumeLabel: "RAW",
        clusterSize: .automatic,
        quickFormat: true,
        wipePartitionTable: true,
        autoEjectAfterFlash: false,
        windowsOptions: WindowsCustomizationOptions(),
        helpersDirectory: helpersDir,
        allowDiskImageTarget: true
    ))

    let verifyFH = try FileHandle(forReadingFrom: URL(fileURLWithPath: devNode))
    let readBack = verifyFH.readData(ofLength: pattern.count)
    try verifyFH.close()
    try assertEqual(readBack, pattern, "DD raw write via FIFO mismatch")
    print("         [sub-check] DD Raw Image via TCC-safe FIFO pipe byte-for-byte OK")
}

print("=== Results: \(passed) passed, \(failed) failed ===")
exit(failed == 0 ? 0 : 1)

/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Foundation
import TSCBasic

/// The Project Interchange Format (PIF) is a structured representation of the
/// project model created by clients (Xcode/SwiftPM) to send to XCBuild.
///
/// The PIF is a representation of the project model describing the static
/// objects which contribute to building products from the project, independent
/// of "how" the user has chosen to build those products in any particular
/// build. This information can be cached by XCBuild between builds (even
/// between builds which use different schemes or configurations), and can be
/// incrementally updated by clients when something changes.
public enum PIF {
    /// This is used as part of the signature for the high-level PIF objects, to ensure that changes to the PIF schema
    /// are represented by the objects which do not use a content-based signature scheme (workspaces and projects,
    /// currently).
    static let schemaVersion = 11

    /// The type used for identifying PIF objects.
    public typealias GUID = String

    /// The top-level PIF object.
    public struct TopLevelObject: Encodable {
        public let workspace: PIF.Workspace

        public init(workspace: PIF.Workspace) {
            self.workspace = workspace
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()

            // Encode the workspace.
            try container.encode(workspace)

            // Encode the projects and their targets.
            for project in workspace.projects {
                try container.encode(project)

                for target in project.targets {
                    try container.encode(target)
                }
            }
        }
    }

    public class TypedObject: Encodable {
        class var type: String {
            fatalError("\(self) missing implementation")
        }

        fileprivate init() {
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringKey.self)
            try container.encode(Swift.type(of: self).type, forKey: "type")
        }
    }

    public class SignedObject: TypedObject {
        @DelayedImmutable
        public var signature: String

        fileprivate override init() {
            super.init()

            let encoder = JSONEncoder()
          #if os(macOS)
            if #available(OSX 10.13, *) {
                encoder.outputFormatting.insert(.sortedKeys)
            }
          #endif
            encoder.userInfo[.encodingPIFSignature] = true
            let signatureContent = try! encoder.encode(self)
            let bytes = ByteString(signatureContent)
            signature = SHA256().hash(bytes).hexadecimalRepresentation
        }

        public override func encode(to encoder: Encoder) throws {
            try super.encode(to: encoder)

            if encoder.userInfo[.encodingPIFSignature] == nil {
                var container = encoder.container(keyedBy: StringKey.self)
                try container.encode(signature, forKey: "signature")
            }
        }
    }

    public final class Workspace: SignedObject {
        override class var type: String { "workspace" }

        public let guid: GUID
        public let name: String
        public let path: AbsolutePath
        public let projects: [Project]

        public init(guid: GUID,  name: String, path: AbsolutePath, projects: [Project]) {
            precondition(!guid.isEmpty)
            precondition(!name.isEmpty)
            precondition(Set(projects.map({ $0.guid })).count == projects.count)
            precondition(Set(projects.map({ $0.signature })).count == projects.count)

            self.guid = guid
            self.name = name
            self.path = path
            self.projects = projects
            super.init()
        }

        public override func encode(to encoder: Encoder) throws {
            try super.encode(to: encoder)
            var container = encoder.container(keyedBy: StringKey.self)
            var contents = container.nestedContainer(keyedBy: StringKey.self, forKey: "contents")
            try contents.encode("\(guid)@\(schemaVersion)", forKey: "guid")
            try contents.encode(name, forKey: "name")
            try contents.encode(path, forKey: "path")

            if encoder.userInfo[.encodingPIFSignature] == nil {
                try contents.encode(projects.map({ $0.signature }), forKey: "projects")
            }
        }
    }

    /// A PIF project, consisting of a tree of groups and file references, a list of targets, and some additional
    /// information.
    public final class Project: SignedObject {
        override class var type: String { "project" }

        public let guid: GUID
        public let name: String
        public let path: AbsolutePath
        public let projectDirectory: AbsolutePath
        public let developmentRegion: String
        public let buildConfigurations: [BuildConfiguration]
        public let targets: [BaseTarget]
        public let groupTree: Group

        public init(
            guid: GUID,
            name: String,
            path: AbsolutePath,
            projectDirectory: AbsolutePath,
            developmentRegion: String,
            buildConfigurations: [BuildConfiguration],
            targets: [BaseTarget],
            groupTree: Group
        ) {
            precondition(!guid.isEmpty)
            precondition(!name.isEmpty)
            precondition(!developmentRegion.isEmpty)
            precondition(Set(targets.map({ $0.guid })).count == targets.count)
            precondition(Set(targets.map({ $0.signature })).count == targets.count)
            precondition(Set(buildConfigurations.map({ $0.guid })).count == buildConfigurations.count)

            self.guid = guid
            self.name = name
            self.path = path
            self.projectDirectory = projectDirectory
            self.developmentRegion = developmentRegion
            self.buildConfigurations = buildConfigurations
            self.targets = targets
            self.groupTree = groupTree
            super.init()
        }

        public override func encode(to encoder: Encoder) throws {
            try super.encode(to: encoder)
            var container = encoder.container(keyedBy: StringKey.self)
            var contents = container.nestedContainer(keyedBy: StringKey.self, forKey: "contents")
            try contents.encode("\(guid)@\(schemaVersion)", forKey: "guid")
            try contents.encode(name, forKey: "projectName")
            try contents.encode("true", forKey: "projectIsPackage")
            try contents.encode(path, forKey: "path")
            try contents.encode(projectDirectory, forKey: "projectDirectory")
            try contents.encode(developmentRegion, forKey: "developmentRegion")
            try contents.encode("Release", forKey: "defaultConfigurationName")
            try contents.encode(buildConfigurations, forKey: "buildConfigurations")
            try contents.encode(targets.map({ $0.signature }), forKey: "targets")
            try contents.encode(groupTree, forKey: "groupTree")
        }
    }

    /// Abstract base class for all items in the group hierarhcy.
    public class Reference: TypedObject {

        /// Determines the base path for a reference's relative path.
        public enum SourceTree: String, Encodable {

            /// Indicates that the path is relative to the source root (i.e. the "project directory").
            case sourceRoot = "SOURCE_ROOT"

            /// Indicates that the path is relative to the path of the parent group.
            case group = "<group>"

            /// Indicates that the path is relative to the effective build directory (which varies depending on active
            /// scheme, active run destination, or even an overridden build setting.
            case builtProductsDir = "BUILT_PRODUCTS_DIR"

            /// Indicates that the path is an absolute path.
            case absolute = "<absolute>"
        }

        public let guid: GUID

        /// Relative path of the reference.  It is usually a literal, but may in fact contain build settings.
        public let path: String

        /// Determines the base path for the reference's relative path.
        public let sourceTree: SourceTree

        /// Name of the reference, if different from the last path component (if not set, the last path component will
        /// be used as the name).
        public let name: String?

        fileprivate init(
            guid: GUID,
            path: String,
            sourceTree: SourceTree,
            name: String?
        ) {
            precondition(!guid.isEmpty)
            precondition(!(name?.isEmpty ?? false))

            self.guid = guid
            self.path = path
            self.sourceTree = sourceTree
            self.name = name
        }

        public override func encode(to encoder: Encoder) throws {
            try super.encode(to: encoder)
            var container = encoder.container(keyedBy: StringKey.self)
            try container.encode(guid, forKey: "guid")
            try container.encode(sourceTree, forKey: "sourceTree")
            try container.encode(path, forKey: "path")
            try container.encode(name ?? path, forKey: "name")
        }
    }

    /// A reference to a file system entity (a file, folder, etc).
    public final class FileReference: Reference {
        override class var type: String { "file" }

        public let fileType: String

        public init(
            guid: GUID,
            path: String,
            sourceTree: SourceTree = .group,
            name: String? = nil,
            fileType: String? = nil
        ) {
            self.fileType = fileType ?? FileReference.fileTypeIdentifier(forPath: path)
            super.init(guid: guid, path: path, sourceTree: sourceTree, name: name)
        }

        public override func encode(to encoder: Encoder) throws {
            try super.encode(to: encoder)
            var container = encoder.container(keyedBy: StringKey.self)
            try container.encode(fileType, forKey: "fileType")
        }
    }

    /// A group that can contain References (FileReferences and other Groups). The resolved path of a group is used as
    /// the base path for any child references whose source tree type is GroupRelative.
    public final class Group: Reference {
        override class var type: String { "group" }

        public let children: [Reference]

        public init(
            guid: GUID,
            path: String,
            sourceTree: SourceTree = .group,
            name: String? = nil,
            children: [Reference]
        ) {
            precondition(
                Set(children.map({ $0.guid })).count == children.count,
                "multiple group children with the same guid: \(children.map({ $0.guid }))"
            )

            self.children = children
            
            super.init(guid: guid, path: path, sourceTree: sourceTree, name: name)
        }

        public override func encode(to encoder: Encoder) throws {
            try super.encode(to: encoder)
            var container = encoder.container(keyedBy: StringKey.self)
            try container.encode(children, forKey: "children")
        }
    }

    /// Represents a dependency on another target (identified by its PIF GUID).
    public struct TargetDependency: Encodable {
        /// Identifier of depended-upon target.
        public var targetGUID: String

        /// The platform filters for this target dependency.
        public var platformFilters: [PlatformFilter]

        public init(targetGUID: String, platformFilters: [PlatformFilter] = [])  {
            self.targetGUID = targetGUID
            self.platformFilters = platformFilters
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringKey.self)
            try container.encode("\(targetGUID)@\(schemaVersion)", forKey: "guid")

            if !platformFilters.isEmpty {
                try container.encode(platformFilters, forKey: "platformFilters")
            }
        }
    }

    public class BaseTarget: SignedObject {
        class override var type: String { "target" }

        public let guid: GUID
        public let name: String
        public let buildConfigurations: [BuildConfiguration]
        public let buildPhases: [BuildPhase]
        public let dependencies: [TargetDependency]
        public let impartedBuildProperties: ImpartedBuildProperties

        fileprivate init(
            guid: GUID,
            name: String,
            buildConfigurations: [BuildConfiguration],
            buildPhases: [BuildPhase],
            dependencies: [TargetDependency],
            impartedBuildSettings: PIF.BuildSettings
        ) {
            self.guid = guid
            self.name = name
            self.buildConfigurations = buildConfigurations
            self.buildPhases = buildPhases
            self.dependencies = dependencies
            impartedBuildProperties = ImpartedBuildProperties(settings: impartedBuildSettings)
        }
    }

    public final class AggregateTarget: BaseTarget {
        public override init(
            guid: GUID,
            name: String,
            buildConfigurations: [BuildConfiguration],
            buildPhases: [BuildPhase],
            dependencies: [TargetDependency],
            impartedBuildSettings: PIF.BuildSettings
        ) {
            super.init(
                guid: guid,
                name: name,
                buildConfigurations: buildConfigurations,
                buildPhases: buildPhases,
                dependencies: dependencies,
                impartedBuildSettings: impartedBuildSettings
            )
        }

        public override func encode(to encoder: Encoder) throws {
            try super.encode(to: encoder)
            var container = encoder.container(keyedBy: StringKey.self)
            var contents = container.nestedContainer(keyedBy: StringKey.self, forKey: "contents")
            try contents.encode("aggregate", forKey: "type")
            try contents.encode("\(guid)@\(schemaVersion)", forKey: "guid")
            try contents.encode(name, forKey: "name")
            try contents.encode(buildConfigurations, forKey: "buildConfigurations")
            try contents.encode(buildPhases, forKey: "buildPhases")
            try contents.encode(dependencies, forKey: "dependencies")
            try contents.encode(impartedBuildProperties, forKey: "impartedBuildProperties")
        }
    }

    /// An Xcode target, representing a single entity to build.
    public final class Target: BaseTarget {
        public enum ProductType: String, Encodable {
            case application = "com.apple.product-type.application"
            case staticArchive = "com.apple.product-type.library.static"
            case objectFile = "com.apple.product-type.objfile"
            case dynamicLibrary = "com.apple.product-type.library.dynamic"
            case framework = "com.apple.product-type.framework"
            case executable = "com.apple.product-type.tool"
            case unitTest = "com.apple.product-type.bundle.unit-test"
            case bundle = "com.apple.product-type.bundle"
            case packageProduct = "packageProduct"
        }

        public let productName: String
        public let productType: ProductType
        public let productReference: FileReference?

        public init(
            guid: GUID,
            name: String,
            productType: ProductType,
            productName: String,
            buildConfigurations: [BuildConfiguration],
            buildPhases: [BuildPhase],
            dependencies: [TargetDependency],
            impartedBuildSettings: PIF.BuildSettings
        ) {
            self.productType = productType
            self.productName = productName
            self.productReference = nil

            super.init(
                guid: guid,
                name: name,
                buildConfigurations: buildConfigurations,
                buildPhases: buildPhases,
                dependencies: dependencies,
                impartedBuildSettings: impartedBuildSettings
            )
        }

        override public func encode(to encoder: Encoder) throws {
            try super.encode(to: encoder)
            var container = encoder.container(keyedBy: StringKey.self)
            var contents = container.nestedContainer(keyedBy: StringKey.self, forKey: "contents")
            try contents.encode("\(guid)@\(schemaVersion)", forKey: "guid")
            try contents.encode(name, forKey: "name")
            try contents.encode(dependencies, forKey: "dependencies")
            try contents.encode(buildConfigurations, forKey: "buildConfigurations")

            if productType == .packageProduct {
                try contents.encode("packageProduct", forKey: "type")

                // Add the framework build phase, if present.
                if let phase = buildPhases.first as? PIF.FrameworksBuildPhase {
                    try contents.encode(phase, forKey: "frameworksBuildPhase")
                }
            } else {
                try contents.encode("standard", forKey: "type")
                try contents.encode(productType, forKey: "productTypeIdentifier")

                let productReference = [
                    "type": "file",
                    "guid": "PRODUCTREF-\(guid)",
                    "name": productName,
                ]
                try contents.encode(productReference, forKey: "productReference")

                try contents.encode([String](), forKey: "buildRules")
                try contents.encode(buildPhases, forKey: "buildPhases")
                try contents.encode(impartedBuildProperties, forKey: "impartedBuildProperties")
            }
        }
    }

    /// Abstract base class for all build phases in a target.
    public class BuildPhase: TypedObject {
        public let guid: GUID
        public let buildFiles: [BuildFile]

        internal init(guid: GUID, buildFiles: [BuildFile]) {
            precondition(!guid.isEmpty)

            self.guid = guid
            self.buildFiles = buildFiles
        }

        public override func encode(to encoder: Encoder) throws {
            try super.encode(to: encoder)
            var container = encoder.container(keyedBy: StringKey.self)
            try container.encode(guid, forKey: "guid")
            try container.encode(buildFiles, forKey: "buildFiles")
        }
    }

    /// A "headers" build phase, i.e. one that copies headers into a directory of the product, after suitable
    /// processing.
    public final class HeadersBuildPhase: BuildPhase {
        override class var type: String { "com.apple.buildphase.headers" }

        public override init(guid: GUID, buildFiles: [BuildFile]) {
            super.init(guid: guid, buildFiles: buildFiles)
        }
    }

    /// A "sources" build phase, i.e. one that compiles sources and provides them to be linked into the executable code
    /// of the product.
    public final class SourcesBuildPhase: BuildPhase {
        override class var type: String { "com.apple.buildphase.sources" }

        public override init(guid: GUID, buildFiles: [BuildFile]) {
            super.init(guid: guid, buildFiles: buildFiles)
        }
    }

    /// A "frameworks" build phase, i.e. one that links compiled code and libraries into the executable of the product.
    public final class FrameworksBuildPhase: BuildPhase {
        override class var type: String { "com.apple.buildphase.frameworks" }

        public override init(guid: String, buildFiles: [BuildFile]) {
            super.init(guid: guid, buildFiles: buildFiles)
        }
    }

    public final class ResourcesBuildPhase: BuildPhase {
        override class var type: String { "com.apple.buildphase.resources" }

        public override init(guid: GUID, buildFiles: [BuildFile]) {
            super.init(guid: guid, buildFiles: buildFiles)
        }
    }

    /// A build file, representing the membership of either a file or target product reference in a build phase.
    public struct BuildFile: Encodable {
        public enum Reference {
            case file(guid: PIF.GUID)
            case target(guid: PIF.GUID)
        }

        public enum HeaderVisibility: String {
            case `public` = "public"
            case `private` = "private"
        }

        public let guid: GUID
        public let reference: Reference
        public let headerVisibility: HeaderVisibility? = nil
        public let platformFilters: [PlatformFilter]

        public init(guid: GUID, file: FileReference, platformFilters: [PlatformFilter]) {
            self.guid = guid
            self.reference = .file(guid: file.guid)
            self.platformFilters = platformFilters
        }

        public init(guid: GUID, fileGUID: PIF.GUID, platformFilters: [PlatformFilter]) {
            self.guid = guid
            self.reference = .file(guid: fileGUID)
            self.platformFilters = platformFilters
        }

        public init(guid: GUID, target: PIF.BaseTarget, platformFilters: [PlatformFilter]) {
            self.guid = guid
            self.reference = .target(guid: target.guid)
            self.platformFilters = platformFilters
        }

        public init(guid: GUID, targetGUID: PIF.GUID, platformFilters: [PlatformFilter]) {
            self.guid = guid
            self.reference = .target(guid: targetGUID)
            self.platformFilters = platformFilters
        }

        public init(guid: GUID, reference: Reference, platformFilters: [PlatformFilter]) {
            self.guid = guid
            self.reference = reference
            self.platformFilters = platformFilters
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringKey.self)
            try container.encode(guid, forKey: "guid")

            switch self.reference {
            case .file(let fileGUID):
                try container.encode(fileGUID, forKey: "fileReference")
            case .target(let targetGUID):
                try container.encode("\(targetGUID)@\(schemaVersion)", forKey: "targetReference")
            }
        }
    }

    /// Represents a generic platform filter.
    public struct PlatformFilter: Encodable {
        /// The name of the platform (`LC_BUILD_VERSION`).
        ///
        /// Example: macos, ios, watchos, tvos.
        public var platform: String

        /// The name of the environment (`LC_BUILD_VERSION`)
        ///
        /// Example: simulator, maccatalyst.
        public var environment: String

        public init(platform: String, environment: String = "") {
            self.platform = platform
            self.environment = environment
        }
    }

    /// A build configuration, which is a named collection of build settings.
    public struct BuildConfiguration: Encodable {
        public let guid: GUID
        public let name: String
        public let buildSettings: BuildSettings

        public init(guid: GUID, name: String, buildSettings: BuildSettings) {
            precondition(!guid.isEmpty)
            precondition(!name.isEmpty)

            self.guid = guid
            self.name = name
            self.buildSettings = buildSettings
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringKey.self)
            try container.encode(guid, forKey: "guid")
            try container.encode(name, forKey: "name")
            try container.encode(buildSettings, forKey: "buildSettings")
        }
    }

    public struct ImpartedBuildProperties: Encodable {
        public let settings: BuildSettings

        public init(settings: BuildSettings) {
            self.settings = settings
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringKey.self)
            try container.encode(settings, forKey: "buildSettings")
        }
    }

    /// A set of build settings, which is represented as a struct of optional build settings. This is not optimally
    /// efficient, but it is great for code completion and type-checking.
    public struct BuildSettings: Encodable {
        public enum SingleValueSetting: String {
            case APPLICATION_EXTENSION_API_ONLY
            case BUILT_PRODUCTS_DIR
            case CLANG_CXX_LANGUAGE_STANDARD
            case CLANG_ENABLE_MODULES
            case CLANG_ENABLE_OBJC_ARC
            case CODE_SIGNING_REQUIRED
            case CODE_SIGN_IDENTITY
            case COMBINE_HIDPI_IMAGES
            case COPY_PHASE_STRIP
            case DEBUG_INFORMATION_FORMAT
            case DEFINES_MODULE
            case DYLIB_INSTALL_NAME_BASE
            case EMBEDDED_CONTENT_CONTAINS_SWIFT
            case ENABLE_NS_ASSERTIONS
            case ENABLE_TESTABILITY
            case ENABLE_TESTING_SEARCH_PATHS
            case ENTITLEMENTS_REQUIRED
            case EXECUTABLE_NAME
            case GENERATE_INFOPLIST_FILE
            case GCC_C_LANGUAGE_STANDARD
            case GCC_OPTIMIZATION_LEVEL
            case GENERATE_MASTER_OBJECT_FILE
            case INFOPLIST_FILE
            case IPHONEOS_DEPLOYMENT_TARGET
            case KEEP_PRIVATE_EXTERNS
            case CLANG_COVERAGE_MAPPING_LINKER_ARGS
            case MACH_O_TYPE
            case MACOSX_DEPLOYMENT_TARGET
            case MODULEMAP_FILE_CONTENTS
            case MODULEMAP_PATH
            case MODULEMAP_FILE
            case ONLY_ACTIVE_ARCH
            case PACKAGE_RESOURCE_BUNDLE_NAME
            case PACKAGE_RESOURCE_TARGET_KIND
            case PRODUCT_BUNDLE_IDENTIFIER
            case PRODUCT_MODULE_NAME
            case PRODUCT_NAME
            case PROJECT_NAME
            case SDKROOT
            case SDK_VARIANT
            case SKIP_INSTALL
            case INSTALL_PATH
            case SUPPORTS_MACCATALYST
            case SWIFT_FORCE_STATIC_LINK_STDLIB
            case SWIFT_FORCE_DYNAMIC_LINK_STDLIB
            case SWIFT_INSTALL_OBJC_HEADER
            case SWIFT_OBJC_INTERFACE_HEADER_NAME
            case SWIFT_OBJC_INTERFACE_HEADER_DIR
            case SWIFT_OPTIMIZATION_LEVEL
            case SWIFT_VERSION
            case TARGET_NAME
            case TARGET_BUILD_DIR
            case TVOS_DEPLOYMENT_TARGET
            case USE_HEADERMAP
            case USES_SWIFTPM_UNSAFE_FLAGS
            case WATCHOS_DEPLOYMENT_TARGET
            case MARKETING_VERSION
            case CURRENT_PROJECT_VERSION
        }

        public enum MultipleValueSetting: String {
            case EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES
            case FRAMEWORK_SEARCH_PATHS
            case GCC_PREPROCESSOR_DEFINITIONS
            case HEADER_SEARCH_PATHS
            case LD_RUNPATH_SEARCH_PATHS
            case LIBRARY_SEARCH_PATHS
            case OTHER_CFLAGS
            case OTHER_CPLUSPLUSFLAGS
            case OTHER_LDFLAGS
            case OTHER_LDRFLAGS
            case OTHER_SWIFT_FLAGS
            case PRELINK_FLAGS
            case SUPPORTED_PLATFORMS
            case SWIFT_ACTIVE_COMPILATION_CONDITIONS
        }

        public enum Platform: String, CaseIterable {
            case macOS = "macos"
            case iOS = "ios"
            case tvOS = "tvos"
            case watchOS = "watchos"
            case linux

            public var conditions: [String] {
                switch self {
                case .macOS: return ["sdk=macosx*"]
                case .iOS: return ["sdk=iphonesimulator*", "sdk=iphoneos*"]
                case .tvOS: return ["sdk=appletvsimulator*", "sdk=appletvos*"]
                case .watchOS: return ["sdk=watchsimulator*", "sdk=watchos*"]
                case .linux: return ["sdk=linux*"]
                }
            }
        }

        public private(set) var platformSpecificSettings = [Platform: [MultipleValueSetting: [String]]]()
        public private(set) var singleValueSettings: [SingleValueSetting: String] = [:]
        public private(set) var multipleValueSettings: [MultipleValueSetting: [String]] = [:]

        public subscript(_ setting: SingleValueSetting) -> String? {
            get { singleValueSettings[setting] }
            set { singleValueSettings[setting] = newValue }
        }

        public subscript(_ setting: SingleValueSetting, default defaultValue: @autoclosure () -> String) -> String {
            get { singleValueSettings[setting, default: defaultValue()] }
            set { singleValueSettings[setting] = newValue }
        }

        public subscript(_ setting: MultipleValueSetting) -> [String]? {
            get { multipleValueSettings[setting] }
            set { multipleValueSettings[setting] = newValue }
        }

        public subscript(_ setting: MultipleValueSetting, for platform: Platform) -> [String]? {
            get { platformSpecificSettings[platform]?[setting] }
            set { platformSpecificSettings[platform, default: [:]][setting] = newValue }
        }

        public subscript(
            _ setting: MultipleValueSetting,
            default defaultValue: @autoclosure () -> [String]
        ) -> [String] {
            get { multipleValueSettings[setting, default: defaultValue()] }
            set { multipleValueSettings[setting] = newValue }
        }

        public subscript(
            _ setting: MultipleValueSetting,
            for platform: Platform,
            default defaultValue: @autoclosure () -> [String]
        ) -> [String] {
            get { platformSpecificSettings[platform, default: [:]][setting, default: defaultValue()] }
            set { platformSpecificSettings[platform, default: [:]][setting] = newValue }
        }

        public init() {
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: StringKey.self)

            for (key, value) in singleValueSettings {
                try container.encode(value, forKey: StringKey(key.rawValue))
            }

            for (key, value) in multipleValueSettings {
                try container.encode(value, forKey: StringKey(key.rawValue))
            }

            for (platform, values) in platformSpecificSettings {
                for condition in platform.conditions {
                    for (key, value) in values {
                        try container.encode(value, forKey: "\(key.rawValue)[\(condition)]")
                    }
                }
            }
        }
    }
}

/// Repesents a filetype recognized by the Xcode build system. 
public struct XCBuildFileType: CaseIterable {
    public static let xcdatamodeld: XCBuildFileType = XCBuildFileType(
        fileType: "xcdatamodeld",
        fileTypeIdentifier: "wrapper.xcdatamodeld"
    )

    public static let xcdatamodel: XCBuildFileType = XCBuildFileType(
        fileType: "xcdatamodel",
        fileTypeIdentifier: "wrapper.xcdatamodel"
    )

    public static let xcmappingmodel: XCBuildFileType = XCBuildFileType(
        fileType: "xcmappingmodel",
        fileTypeIdentifier: "wrapper.xcmappingmodel"
    )

    public static let allCases: [XCBuildFileType] = [
        .xcdatamodeld,
        .xcdatamodel,
        .xcmappingmodel,
    ]

    public let fileTypes: Set<String>
    public let fileTypeIdentifier: String

    private init(fileTypes: Set<String>, fileTypeIdentifier: String) {
        self.fileTypes = fileTypes
        self.fileTypeIdentifier = fileTypeIdentifier
    }

    private init(fileType: String, fileTypeIdentifier: String) {
        self.init(fileTypes: [fileType], fileTypeIdentifier: fileTypeIdentifier)
    }
}

struct StringKey: CodingKey, ExpressibleByStringInterpolation {
    var stringValue: String
    var intValue: Int?

    init(stringLiteral stringValue: String) {
        self.stringValue = stringValue
    }

    init(stringValue value: String) {
        self.stringValue = value
    }

    init(_ value: String) {
        self.stringValue = value
    }

    init?(intValue: Int) {
        fatalError("does not support integer keys")
    }
}

extension PIF.FileReference {
    fileprivate static func fileTypeIdentifier(forPath path: String) -> String {
        let pathExtension: String?
        if let path = try? AbsolutePath(validating: path) {
            pathExtension = path.extension
        } else if let path = try? RelativePath(validating: path) {
            pathExtension = path.extension
        } else {
            pathExtension = nil
        }

        switch pathExtension {
        case "a":
            return "archive.ar"
        case "s", "S":
            return "sourcecode.asm"
        case "c":
            return "sourcecode.c.c"
        case "cl":
            return "sourcecode.opencl"
        case "cpp", "cp", "cxx", "cc", "c++", "C", "tcc":
            return "sourcecode.cpp.cpp"
        case "d":
            return "sourcecode.dtrace"
        case "defs", "mig":
            return "sourcecode.mig"
        case "m":
            return "sourcecode.c.objc"
        case "mm", "M":
            return "sourcecode.cpp.objcpp"
        case "metal":
            return "sourcecode.metal"
        case "l", "lm", "lmm", "lpp", "lp", "lxx":
            return "sourcecode.lex"
        case "swift":
            return "sourcecode.swift"
        case "y", "ym", "ymm", "ypp", "yp", "yxx":
            return "sourcecode.yacc"

        case "xcassets":
            return "folder.assetcatalog"
        case "storyboard":
            return "file.storyboard"
        case "xib":
            return "file.xib"

        case "xcframework":
            return "wrapper.xcframework"

        default:
            return pathExtension.flatMap({ pathExtension in
                XCBuildFileType.allCases.first(where:{ $0.fileTypes.contains(pathExtension) })
            })?.fileTypeIdentifier ?? "file"
        }
    }
}

extension CodingUserInfoKey {
    public static let encodingPIFSignature: CodingUserInfoKey = CodingUserInfoKey(rawValue: "encodingPIFSignature")!
}

import Foundation

final class SourceKitObfuscator: ObfuscatorProtocol {
    let sourceKit: SourceKit
    let logger: LoggerProtocol
    let dataStore: SourceKitObfuscatorDataStore
    let ignorePublic: Bool
    let namesToIgnore: Set<String>
    /// 白名单：仅混淆此集合中的名称。若为 nil，则按黑名单模式工作（namesToIgnore 之外的都混淆）。
    let obfuscateOnlyNames: Set<String>?
    weak var delegate: ObfuscatorDelegate?

    init(sourceKit: SourceKit, logger: LoggerProtocol, dataStore: SourceKitObfuscatorDataStore,
         namesToIgnore: Set<String>, ignorePublic: Bool, obfuscateOnlyNames: Set<String>?) {
        self.sourceKit = sourceKit
        self.logger = logger
        self.dataStore = dataStore
        self.ignorePublic = ignorePublic
        self.namesToIgnore = namesToIgnore
        self.obfuscateOnlyNames = obfuscateOnlyNames
    }

    var requests: sourcekitd_requests! {
        sourceKit.requests
    }

    var keys: sourcekitd_keys! {
        sourceKit.keys
    }
}

// MARK: Indexing

extension SourceKitObfuscator {
    func registerModuleForObfuscation(_ module: Module) throws {
        let compilerArguments = SKRequestArray(sourcekitd: sourceKit)
        module.compilerArguments.forEach(compilerArguments.append(_:))
        try module.sourceFiles.sorted { $0.path < $1.path }.forEach { file in
            logger.log("--- Indexing: \(file.name)")
            let req = SKRequestDictionary(sourcekitd: sourceKit)
            req[keys.request] = requests.indexsource
            req[keys.sourcefile] = file.path
            req[keys.compilerargs] = compilerArguments
            let response = try sourceKit.sendSync(req)
            logger.log("--- Preprocessing indexing result of: \(file.name)")
            response.recurseEntities { [unowned self] dict in
                self.preprocess(declarationEntity: dict, ofFile: file, fromModule: module)
            }
            dataStore.moduleForFile[file.path] = module
////BASE:
//            logger.log("--- Preprocessing indexing result of: \(file.name)")
//            response.recurseEntities { [unowned self] dict in
//                self.preprocess(declarationEntity: dict, ofFile: file, fromModule: module)
//            }
////AGGRESSIVE:
//            var visited1 = Set<String>()
//            response.recurseEntities(visited: &visited1) { [unowned self] dict in
//                self.preprocess(declarationEntity: dict, ofFile: file, fromModule: module)
//            }

            logger.log("--- Processing indexing result of: \(file.name)")
            try response.recurseEntities { [unowned self] dict in
                if self.ignorePublic, dict.isPublic { return }
                try self.process(declarationEntity: dict, ofFile: file, fromModule: module)
            }
//// BASE:
//            logger.log("--- Processing indexing result of: \(file.name)")
//            try response.recurseEntities { [unowned self] dict in
//                if self.ignorePublic, dict.isPublic {
//                    return
//                }
//                try self.process(declarationEntity: dict, ofFile: file, fromModule: module)
//            }
////AGGRESSIVE:
//            var visited2 = Set<String>()
//            try response.recurseEntities(visited: &visited2) { [unowned self] dict in
//                if self.ignorePublic, dict.isPublic {
//                    return
//                }
//                try self.process(declarationEntity: dict, ofFile: file, fromModule: module)
//            }
            let indexedFile = IndexedFile(file: file, response: response)
            self.dataStore.indexedFiles.append(indexedFile)
        }
        dataStore.plists = dataStore.plists.union(module.plists)
    }

    func preprocess(
        declarationEntity dict: SKResponseDictionary,
        ofFile file: File,
        fromModule module: Module
    ) {
        guard let usr: String = dict[keys.usr] else {
            return
        }
        dataStore.fileForUSR[usr] = file
    }

    func process(
        declarationEntity dict: SKResponseDictionary,
        ofFile file: File,
        fromModule module: Module
    ) throws {
        // 过滤：跳过非 .swift 源文件的声明（如 DerivedData 中的 GeneratedAssetSymbols.swift
        // 产生的 ColorResource/ImageResource 等自动生成的符号）
        let filePath = file.path
        let fileExt = (filePath as NSString).pathExtension.lowercased()
        let isSwiftSource = fileExt == "swift"
        // 进一步过滤：排除路径中包含 DerivedData/build 等构建产物目录的文件
        let isInBuildProduct = filePath.contains("DerivedData") ||
                               filePath.contains("/.build/") ||
                               filePath.contains("generated_files") ||
                               filePath.contains("GeneratedAssetSymbols")
        if !isSwiftSource || isInBuildProduct {
            logger.log("* Skipping: \(file.name) (isSwiftSource=\(isSwiftSource), isBuildProduct=\(isInBuildProduct))", verbose: true)
            return
        }
        let entityKind: SKUID = dict[keys.kind]!
        logger.log("DEBUG process: kind=\(entityKind.description) name=\(dict[keys.name] ?? "nil") usr=\(dict[keys.usr] ?? "nil")")
        guard let kind = entityKind.declarationType() else {
            logger.log("DEBUG SKIPPED (declarationType=nil)")
            return
        }
        guard let rawName: String = dict[keys.name],
              let usr: String = dict[keys.usr] else
        {
            return
        }

        let name = rawName.removingParameterInformation

        let isExtension = entityKind.description.contains(".decl.extension.")
        if isExtension {
            guard dataStore.declaredTypeNames.contains(name) else {
                logger.log("* Skipping extension on external type: \(name)", verbose: true)
                return
            }
        }
        if kind == .object, !isExtension {
            dataStore.declaredTypeNames.insert(name)
        }
        
        if namesToIgnore.contains(name) {
            logger.log("* Ignoring \(name) (USR: \(usr)) because its included in ignore-names", verbose: true)
            return
        }

        // ── 白名单模式：若设置了 obfuscateOnlyNames，则只混淆白名单中的名称 ──
        if let whitelist = obfuscateOnlyNames {
            if !whitelist.contains(name) {
                logger.log(
                    "* Ignoring \(name) (USR: \(usr)) because it's not in the obfuscate-only whitelist",
                    verbose: true)
                return
            }
        }

        if kind == .enumelement, let parentUSR: String = dict.parent[keys.usr] {
            let codingKeysUSR: Set<String> = ["s:s9CodingKeyP"]
            if try inheritsFromAnyUSR(
                parentUSR,
                anyOf: codingKeysUSR,
                inModule: module
            ) {
                logger.log("* Ignoring \(name) (USR: \(usr)) because its parent enum inherits from CodingKey.", verbose: true)
                return
            } else {
                logger.log("Info: Proceeding with \(name) (USR: \(usr)) because its parent enum does not appear to inherit from CodingKey.)", verbose: true)
            }
        }

        if kind == .property,
           dict.parent != nil,
           let parentKind: SKUID = dict.parent[keys.kind],
           parentKind.declarationType() == .object
        {
            guard let parentUSR: String = dict.parent[keys.usr] else {
                throw logger.fatalError(forMessage: "Parent of \(usr) is has no USR!")
            }
            let codableUSRs: Set<String> = ["s:s7Codablea", "s:SE", "s:Se"]
            if try inheritsFromAnyUSR(
                parentUSR,
                anyOf: codableUSRs,
                inModule: module
            ) {
                logger.log("* Ignoring \(name) (USR: \(usr)) because its parent inherits from Codable.", verbose: true)
                return
            } else {
                logger.log("Info: Proceeding with \(name) (USR: \(usr)) because its parent does not appear to inherit from Codable.)", verbose: true)
            }
        }

        logger.log("* Found declaration of \(name) (USR: \(usr))")
        dataStore.processedUsrs.insert(usr)

        let receiver: String? = dict[keys.receiver]
        if receiver == nil {
            dataStore.usrRelationDictionary[usr] = dict
        }
    }
}

// MARK: Obfuscating

extension SourceKitObfuscator {
    @discardableResult
    func obfuscate() throws -> ConversionMap {
        try dataStore.indexedFiles.forEach { index in
            try obfuscate(index: index)
        }
        try dataStore.plists.forEach { plist in
            try obfuscate(plist: plist)
        }
        try obfuscateAllStoryboards()
        return ConversionMap(obfuscationDictionary: dataStore.obfuscationDictionary)
    }

    /// 扫描所有已索引源文件目录，收集 .storyboard 文件并混淆其中的 customClass
    private func obfuscateAllStoryboards() throws {
        let storyboardPaths = dataStore.indexedFiles.map { $0.file.path }
        var processedDirs = Set<String>()
        for sourcePath in storyboardPaths {
            let dir = (sourcePath as NSString).deletingLastPathComponent
            if processedDirs.contains(dir) { continue }
            processedDirs.insert(dir)
            // 在源文件同级目录及 Base.lproj 子目录中查找 storyboard
            let searchDirs = [dir, dir + "/Base.lproj"]
            for searchDir in searchDirs {
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: searchDir) else { continue }
                for name in contents where name.hasSuffix(".storyboard") {
                    let fullPath = (searchDir as NSString).appendingPathComponent(name)
                    let file = File(path: fullPath)
                    try obfuscate(storyboard: file)
                }
            }
        }
    }

    /// 混淆 storyboard XML 中的 customClass 属性
    /// 替换 customClass="OriginalName" → customClass="混淆后的名称"
    func obfuscate(storyboard: File) throws {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storyboard.path)),
              var content = String(data: data, encoding: .utf8) else {
            return
        }

        logger.log("--- Checking storyboard: \(storyboard.name)")
        var updated = false

        // 遍历混淆字典，替换所有被混淆的 customClass
        for (originalName, obfuscatedName) in dataStore.obfuscationDictionary {
            let oldAttr = "customClass=\"\(originalName)\""
            let newAttr = "customClass=\"\(obfuscatedName)\""
            if content.contains(oldAttr) {
                content = content.replacingOccurrences(of: oldAttr, with: newAttr)
                updated = true
                logger.log("* Updated storyboard customClass: \(originalName) → \(obfuscatedName)")
            }
        }

        if updated, let error = delegate?.obfuscator(self, didObfuscateFile: storyboard, newContents: content) {
            throw error
        }
    }

    func obfuscate(index: IndexedFile) throws {
        logger.log("--- Obfuscating \(index.file.name)")
        var referenceArray = [Reference]()
        index.response.recurseEntities { [unowned self] dict in
            guard let kindId: SKUID = dict[self.keys.kind],
                kindId.referenceType() != nil || kindId.declarationType() != nil,
                let rawName: String = dict[self.keys.name],
                let usr: String = dict[self.keys.usr],
                self.dataStore.processedUsrs.contains(usr),
                let line: Int = dict[self.keys.line],
                let column: Int = dict[self.keys.column],
                dict.isReferencingInternalFramework(dataStore: self.dataStore) == false else {
                return
            }
            let name = rawName.removingParameterInformation
            let obfuscatedName = self.obfuscate(name: name)
            self.logger.log("* Found reference of \(name) (USR: \(usr) at \(index.file.name) (\(line):\(column)) -> now \(obfuscatedName)")
            let reference = Reference(name: name, line: line, column: column)
            referenceArray.append(reference)
        }
        let originalContents = try index.file.read()
        // ВРЕМЕННО
        if index.file.name == "UserService.swift" {
            logger.log("=== referenceArray for UserService.swift ===")
            for ref in referenceArray.sorted(by: <) {
                logger.log("  name=\(ref.name) line=\(ref.line) col=\(ref.column)")
            }
            logger.log("=== total: \(referenceArray.count) references ===")
        }
        let obfuscatedContents = obfuscate(fileContents: originalContents, fromReferences: referenceArray)

//        let originalContents = try index.file.read()
//        let obfuscatedContents = obfuscate(fileContents: originalContents, fromReferences: referenceArray)
        if let error = delegate?.obfuscator(self, didObfuscateFile: index.file, newContents: obfuscatedContents) {
            throw error
        }
    }

    func obfuscate(plist: File) throws {
        var data = try plist.read()
        let regex = "\\$\\(PRODUCT_MODULE_NAME\\)\\.[^ \n]*<"
        let results = data.match(regex: regex)
        guard results.isEmpty == false else {
            return
        }
        logger.log("--- Obfuscating \(plist.name)")
        for result in results.reversed() {
            let value = String(result.captureGroup(0, originalString: data).dropLast())
            let range = result.captureGroupRange(0, originalString: data)
            let productModuleName = "$(PRODUCT_MODULE_NAME)"
            let currentName = value.components(separatedBy: "\(productModuleName).").last ?? ""
            let protectedName = dataStore.obfuscationDictionary[currentName] ?? currentName
            let newPlistValue = productModuleName + "." + protectedName + "<"
            data = data.replacingCharacters(in: range, with: newPlistValue)
        }
        let newPlist = data
        if let error = delegate?.obfuscator(self, didObfuscateFile: plist, newContents: newPlist) {
            throw error
        }
    }

    func obfuscate(name: String) -> String {
        let cachedResult = dataStore.obfuscationDictionary[name]
        guard cachedResult == nil else {
            return cachedResult!
        }
        let size = 32
        let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let numbers: [Character] = Array("0123456789")
        let lettersAndNumbers = letters + numbers
        var randomString = ""
        for i in 0 ..< size {
            let characters: [Character] = i == 0 ? letters : lettersAndNumbers
            let rand = Int.random(in: 0 ..< characters.count)
            let nextChar = characters[rand]
            randomString.append(nextChar)
        }
        guard dataStore.obfuscatedNames.contains(randomString) == false else {
            return obfuscate(name: name)
        }
        dataStore.obfuscatedNames.insert(randomString)
        dataStore.obfuscationDictionary[name] = randomString
        return randomString
    }

    func obfuscate(fileContents: String, fromReferences references: [Reference]) -> String {
        let sortedReferences = references.sorted(by: <)

        var previousReference: Reference!
        var currentReferenceIndex = 0
        var line = 1
        var column = 1
        var currentCharIndex = 0

        var charArray: [String] = Array(fileContents).map(String.init)

        while currentCharIndex < charArray.count, currentReferenceIndex < sortedReferences.count {
            let reference = sortedReferences[currentReferenceIndex]
            if previousReference != nil,
                reference.line == previousReference.line,
                reference.column == previousReference.column {
                // Avoid duplicates.
                currentReferenceIndex += 1
            }
            let currentCharacter = charArray[currentCharIndex]
            if line == reference.line, column == reference.column {
                previousReference = reference
                let originalName = reference.name
                let obfuscatedName = obfuscate(name: originalName)
                let wasInternalKeyword = currentCharacter == "`"
                let startIndex = currentCharIndex + (wasInternalKeyword ? 1 : 0)

                // Считаем реальную длину идентификатора в файле
                var actualLength = 0
                while startIndex + actualLength < charArray.count {
                    let ch = charArray[startIndex + actualLength]
                    guard ch.count == 1,
                          let scalar = ch.unicodeScalars.first,
                          CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(scalar) else { break }
                    actualLength += 1
                }
                let totalLength = actualLength + (wasInternalKeyword ? 2 : 0)

                for i in 1 ..< max(1, totalLength) {
                    charArray[currentCharIndex + i] = ""
                }
                charArray[currentCharIndex] = obfuscatedName
                currentReferenceIndex += 1
                currentCharIndex += max(1, totalLength - (wasInternalKeyword ? 1 : 0))
                column += totalLength
                if wasInternalKeyword {
                    charArray[currentCharIndex] = ""
                }
            } else if currentCharacter == "\n" {
                line += 1
                column = 1
                currentCharIndex += 1
            } else {
                column += currentCharacter.utf8Count
                currentCharIndex += 1
            }
        }
        return charArray.joined()
    }
}

extension SourceKitObfuscator {
    func inheritsFromAnyUSR(_ usr: String, anyOf usrs: Set<String>, inModule module: Module) throws -> Bool {
        let usrsKey = usrs.joined(separator: " ")
        if let cache = dataStore.inheritsFromX[usr, default: [:]][usrsKey] {
            return cache
        }

        func result(_ val: Bool) -> Bool {
            dataStore.inheritsFromX[usr, default: [:]][usrsKey] = val
            return val
        }

        // cycles flag = false while counting
        dataStore.inheritsFromX[usr, default: [:]][usrsKey] = false

        let req = SKRequestDictionary(sourcekitd: sourceKit)
        req[keys.request] = requests.cursorinfo
        req[keys.usr] = usr
        let file: File = dataStore.fileForUSR[usr] ?? module.sourceFiles.first!
        let correctModule = dataStore.moduleForFile[file.path] ?? module
        req[keys.sourcefile] = file.path
        req[keys.compilerargs] = correctModule.compilerArguments
        let cursorInfo = try sourceKit.sendSync(req)
        guard let annotation: String = cursorInfo[keys.annotated_decl] else {
            logger.log("Pretending \(usr) inherits from Codable because SourceKit failed to look it up. This can happen if this USR belongs to an @objc class.", verbose: true)
            return result(true)
        }
        let regex = "usr=\\\"(.\\S*)\\\""
        let regexResult = annotation.match(regex: regex)
        for res in regexResult {
            let inheritedUSR = res.captureGroup(1, originalString: annotation)
            if usrs.contains(inheritedUSR) {
                return result(true)
            } else if try inheritsFromAnyUSR(inheritedUSR, anyOf: usrs, inModule: module) {
                return result(true)
            }
        }
        return result(false)
    }
//    func inheritsFromAnyUSR(_ usr: String, anyOf usrs: Set<String>, inModule module: Module) throws -> Bool {
//        let usrsKey = usrs.joined(separator: " ")
//        if let cache = dataStore.inheritsFromX[usr, default: [:]][usrsKey] {
//            return cache
//        }
//
//        func result(_ val: Bool) -> Bool {
//            dataStore.inheritsFromX[usr, default: [:]][usrsKey] = val
//            return val
//        }
//
//        let req = SKRequestDictionary(sourcekitd: sourceKit)
//        req[keys.request] = requests.cursorinfo
//        req[keys.compilerargs] = module.compilerArguments
//        req[keys.usr] = usr
//        // We have to store the file of the USR because it looks CursorInfo doesn't returns USRs if you use the wrong one
//        //, except if it's a closed source framework. No idea why it works like that.
//        // Hopefully this won't break in the future.
//        let file: File = dataStore.fileForUSR[usr] ?? module.sourceFiles.first!
//        req[keys.sourcefile] = file.path
//        let cursorInfo = try sourceKit.sendSync(req)
//        guard let annotation: String = cursorInfo[keys.annotated_decl] else {
//            logger.log("Pretending \(usr) inherits from Codable because SourceKit failed to look it up. This can happen if this USR belongs to an @objc class.", verbose: true)
//            return result(true)
//        }
//        let regex = "usr=\\\"(.\\S*)\\\""
//        let regexResult = annotation.match(regex: regex)
//        for res in regexResult {
//            let inheritedUSR = res.captureGroup(1, originalString: annotation)
//            if usrs.contains(inheritedUSR) {
//                return result(true)
//            } else if try inheritsFromAnyUSR(inheritedUSR, anyOf: usrs, inModule: module) {
//                return result(true)
//            }
//        }
//        return result(false)
//    }
}

// MARK: SKResponseDictionary Helpers

extension SKResponseDictionary {
    var isPublic: Bool {
        if let kindId: SKUID = self[sourcekitd.keys.kind], let type = kindId.declarationType(), type == .enumelement {
            return parent.isPublic
        }
        guard let attributes: SKResponseArray = self[sourcekitd.keys.attributes] else {
            return false
        }
        guard attributes.count > 0 else {
            return false
        }
        for i in 0 ..< attributes.count {
            guard let attr: SKUID = attributes[i][sourcekitd.keys.attribute] else {
                continue
            }
            guard attr.asString == AccessControl.public.rawValue || attr.asString == AccessControl.open.rawValue else {
                continue
            }
            return true
        }
        return false
    }

    func isReferencingInternalFramework(dataStore: SourceKitObfuscatorDataStore) -> Bool {
        guard let kindId: SKUID = self[sourcekitd.keys.kind] else {
            return false
        }
        let type = kindId.referenceType() ?? kindId.declarationType()
        guard type == .method || type == .property else {
            return false
        }
        guard let usr: String = self[sourcekitd.keys.usr] else {
            return false
        }
        let usrRelationDict = dataStore.usrRelationDictionary
        if let dict: SKResponseDictionary = usrRelationDict[usr], self.dict.data != dict.dict.data {
            return dict.isReferencingInternalFramework(dataStore: dataStore)
        }
        var isReference = false
        recurse(uid: sourcekitd.keys.related) { [unowned self] dict in
            guard isReference == false else {
                return
//        var visited4 = Set<String>()
//        recurse(uid: sourcekitd.keys.related, visited: &visited4) { [unowned self] dict in
//            guard isReference == false else {
//                return
            }
            guard let usr: String = dict[self.sourcekitd.keys.usr] else {
                return
            }
            if dataStore.processedUsrs.contains(usr) == false {
                isReference = true
            } else if let dict: SKResponseDictionary = usrRelationDict[usr] {
                isReference = dict.isReferencingInternalFramework(dataStore: dataStore)
            }
        }
        return isReference
    }
}

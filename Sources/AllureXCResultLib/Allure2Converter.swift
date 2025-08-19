//
//  Allure2Converter.swift
//
//
//  Created by Vladislav Kiryukhin on 21.12.2021.
//

import Foundation

enum Allure2Converter {
    static func convert(
        testCase: TestCase,
        historyIDProvider: HistoryIDProvider,
        parametersProvider: ParametersProvider
    ) throws -> (test: TestResult, attachments: [LazyAttachment]) {
        let uuid = UUID().uuidString.lowercased()

        let steps = testCase.activities.compactMap { Self.makeStep(from: $0) }

        let minStart = steps.compactMap { $0.start > 0 ? $0.start : nil }.min()
        let maxStop = steps.compactMap { $0.stop > 0 ? $0.stop : nil }.max()

        let startTime = minStart ?? testCase.testRun.startedTime.millis
        let stopTime = maxStop ?? (startTime + testCase.summary.duration.millis)

        let parameters = parametersProvider.makeParameters(testCase: testCase)
        let statusDetails = steps.first(where: { $0.statusDetails != nil })?.statusDetails
        let historyId = historyIDProvider.makeHistoryID(testCase: testCase)

        do {
            let allureProcessingResult = processAllureAnnotations(testCase: testCase)
            
            let test = try TestResult(
                uuid: uuid,
                historyId: historyId,
                testCaseId: allureProcessingResult.testCaseId,
                testCaseName: nil,
                fullName: testCase.summary.identifier,
                labels: allureProcessingResult.labels,
                links: allureProcessingResult.links,
                name: allureProcessingResult.name ?? testCase.summary.name,
                status: Self.makeStatus(for: testCase.summary),
                statusDetails: statusDetails,
                stage: nil,
                description: allureProcessingResult.description,
                descriptionHtml: nil,
                steps: steps,
                attachments: [],
                parameters: parameters,
                start: startTime,
                stop: stopTime
            )

            let attachments: [LazyAttachment] = testCase.attachments

            return (test, attachments)
        } catch ConvertationError.unknownStatus(let msg) {
            throw ConverterError.invalidTestCase(message: msg, name: testCase.summary.name)
        }
    }
}

extension Allure2Converter {
    private static func makeStatus(for summary: TestSummary) throws -> Status {
        switch summary.status {
        case .success: return .passed
        case .failure: return .failed
        case .skipped: return .skipped
        case .expectedFailure: return .passed
        case .unknown(let value):
            throw ConvertationError.unknownStatus("Unknown status for '\(value)'")
        }
    }

    private static func makeAttachment(from attachment: TestAttachment) -> Attachment {
        Attachment(name: attachment.name, source: attachment.name, type: nil)
    }

    private static func makeStep(from activity: TestActivity) -> StepResult? {
        if activity.isAllureAnnotation {
            return nil
        }

        let substeps = activity.subactivities.compactMap { Self.makeStep(from: $0) }
        let attachments = activity.attachments.map { Self.makeAttachment(from: $0) }

        let status: Status
        let statusDetails: StatusDetails?

        if let firstFailedSubstep = substeps.first(where: { $0.status == .failed }) {
            status = firstFailedSubstep.status
            statusDetails = firstFailedSubstep.statusDetails
        } else {
            status = activity.activityType == .failure ? .failed : .passed

            statusDetails = status == .failed
                ? StatusDetails(known: false, muted: false, flaky: false, message: activity.title, trace: "")
                : nil
        }

        return StepResult(
            name: activity.title,
            status: status,
            statusDetails: statusDetails,
            stage: nil,
            description: nil,
            descriptionHtml: nil,
            steps: substeps,
            attachments: attachments,
            parameters: [],
            start: activity.startedTime?.millis ?? 0,
            stop: activity.endedTime?.millis ?? activity.startedTime?.millis ?? 0
        )
    }
    
    private struct AllureProcessingResult {
        let labels: [Label]
        let links: [Link]
        let name: String?
        let description: String?
        let testCaseId: String?
    }
    
    private static func processAllureAnnotations(testCase: TestCase) -> AllureProcessingResult {
        var labels: [String: [String]] = [:]
        var links: [Link] = []
        var testName: String?
        var testDescription: String?
        var testCaseId: String?

        // Add default labels
        if let parentSuite = testCase.summary.path.first {
            labels["parentSuite"] = [parentSuite]
        }

        if let suite = testCase.summary.identifier.split(separator: "/").first {
            labels["suite"] = [String(suite)]
        }

        let hostValue = "\(testCase.destination.name) (\(testCase.destination.identifier))"
        + " on \(testCase.destination.machineIdentifier)"
        labels["host"] = [hostValue]

        // Process allure annotations from activities
        for activity in testCase.activities {
            processAllureAnnotationsRecursively(activity: activity, 
                                               labels: &labels, 
                                               links: &links, 
                                               testName: &testName, 
                                               testDescription: &testDescription, 
                                               testCaseId: &testCaseId)
        }

        let labelArray = labels.flatMap { key, values in
            values.map { Label(name: key, value: $0) }
        }

        return AllureProcessingResult(
            labels: labelArray,
            links: links,
            name: testName,
            description: testDescription,
            testCaseId: testCaseId
        )
    }
    
    private static func processAllureAnnotationsRecursively(
        activity: TestActivity,
        labels: inout [String: [String]],
        links: inout [Link],
        testName: inout String?,
        testDescription: inout String?,
        testCaseId: inout String?
    ) {
        // Process current activity
        if let allureId = activity.allureId {
            testCaseId = allureId
            labels["AS_ID"] = [allureId]
        } else if let name = activity.allureName {
            testName = name
        } else if let description = activity.allureDescription {
            testDescription = description
        } else if let (key, value) = activity.allureLabel {
            labels[key, default: []].append(value)
        } else if let link = activity.allureLink {
            links.append(Link(name: link.name, url: link.url, type: link.type))
        }

        // Process subactivities recursively
        for subactivity in activity.subactivities {
            processAllureAnnotationsRecursively(
                activity: subactivity,
                labels: &labels,
                links: &links,
                testName: &testName,
                testDescription: &testDescription,
                testCaseId: &testCaseId
            )
        }
    }
}

extension TestActivity {
    private static let allureIdPrefix = "allure.id:"
    private static let allureNamePrefix = "allure.name:"
    private static let allureDescriptionPrefix = "allure.description:"
    private static let allureLabelPrefix = "allure.label."
    private static let allureLinkPrefix = "allure.link."
    
    // Legacy prefixes for backward compatibility
    private static let legacyAllureLabelPrefix = "allure_label_"
    private static let legacyAllureLinkPrefix = "allure_link_"

    var isAllureAnnotation: Bool {
        title.hasPrefix(Self.allureIdPrefix) ||
        title.hasPrefix(Self.allureNamePrefix) ||
        title.hasPrefix(Self.allureDescriptionPrefix) ||
        title.hasPrefix(Self.allureLabelPrefix) ||
        title.hasPrefix(Self.allureLinkPrefix) ||
        title.hasPrefix(Self.legacyAllureLabelPrefix) ||
        title.hasPrefix(Self.legacyAllureLinkPrefix)
    }

    var isAllureLabel: Bool {
        title.hasPrefix(Self.allureLabelPrefix) || title.hasPrefix(Self.legacyAllureLabelPrefix)
    }

    var isAllureLink: Bool {
        title.hasPrefix(Self.allureLinkPrefix) || title.hasPrefix(Self.legacyAllureLinkPrefix)
    }

    var allureId: String? {
        guard title.hasPrefix(Self.allureIdPrefix) else { return nil }
        return String(title.dropFirst(Self.allureIdPrefix.count))
    }

    var allureName: String? {
        guard title.hasPrefix(Self.allureNamePrefix) else { return nil }
        return String(title.dropFirst(Self.allureNamePrefix.count))
    }

    var allureDescription: String? {
        guard title.hasPrefix(Self.allureDescriptionPrefix) else { return nil }
        return String(title.dropFirst(Self.allureDescriptionPrefix.count))
    }

    var allureLabel: (key: String, value: String)? {
        if title.hasPrefix(Self.allureLabelPrefix) {
            let content = title.dropFirst(Self.allureLabelPrefix.count)
            guard let colonIndex = content.firstIndex(of: ":") else { return nil }
            let key = String(content[..<colonIndex])
            let value = String(content[content.index(after: colonIndex)...])
            return (key, value.trimmingCharacters(in: .whitespaces))
        } else if title.hasPrefix(Self.legacyAllureLabelPrefix) {
            // Legacy format: allure_label_key_value
            let components = title
                .dropFirst(Self.legacyAllureLabelPrefix.count)
                .split(separator: "_", maxSplits: 1)
            
            guard components.count == 2 else { return nil }
            return (String(components[0]), String(components[1]))
        }
        return nil
    }

    var allureLink: (name: String, type: String, url: String)? {
        if title.hasPrefix(Self.allureLinkPrefix) {
            let content = title.dropFirst(Self.allureLinkPrefix.count)
            
            // Parse pattern: allure.link.{name}[{type}]:{url}
            let regex = try! NSRegularExpression(pattern: #"^(.+?)(?:\[(.+?)\])?:(.+)$"#)
            let nsString = NSString(string: String(content))
            guard let match = regex.firstMatch(in: String(content), options: [], range: NSRange(location: 0, length: nsString.length)) else {
                return nil
            }
            
            let name = nsString.substring(with: match.range(at: 1))
            let type = match.range(at: 2).location != NSNotFound ? nsString.substring(with: match.range(at: 2)) : ""
            let url = nsString.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
            
            return (name, type, url)
        } else if title.hasPrefix(Self.legacyAllureLinkPrefix) {
            // Legacy format: allure_link_name_type_url
            let components = title
                .dropFirst(Self.legacyAllureLinkPrefix.count)
                .split(separator: "_", maxSplits: 2)

            guard components.count == 3 else { return nil }

            return (
                name: String(components[0]),
                type: String(components[1]),
                url: String(components[2])
            )
        }
        return nil
    }
}

extension Allure2Converter {
    enum ConvertationError: Error {
        case unknownStatus(String)
    }
}

extension Date {
    fileprivate var millis: Int { Int(timeIntervalSince1970 * 1000) }
}

extension TimeInterval {
    fileprivate var millis: Int { Int(self * 1000) }
}

import Foundation
import Testing
@testable import liveAPP

struct BuildInformationTests {
    @Test func missingOrUnsupportedInformationRemainsUnknown() {
        for data in [nil, Data("invalid".utf8), Data(#"{"schemaVersion":2,"appRevision":"wrong"}"#.utf8)] {
            let value = BuildInformation.decode(data)
            #expect(value.appRevision == nil)
            #expect(value.report.contains("App commit：未知"))
        }
    }
    @Test func fullRevisionsArePreservedForReports() {
        let sha = String(repeating: "a", count: 40)
        let data = Data("{\"schemaVersion\":1,\"appRevision\":\"\(sha)\",\"appDirty\":true,\"haishinVerification\":\"unverified\"}".utf8)
        let value = BuildInformation.decode(data)
        #expect(value.report.contains(sha))
        #expect(value.report.contains("有未提交修改"))
        #expect(value.verification.contains("尚未核對"))
    }
    @Test func matchingCommitDoesNotHideLocalModifications() {
        let value = BuildInformation.decode(Data(#"{"schemaVersion":1,"haishinVerification":"matched","haishinCheckoutDirty":true}"#.utf8))
        #expect(value.verification.contains("本機修改"))
        let mismatch = BuildInformation.decode(Data(#"{"schemaVersion":1,"haishinVerification":"mismatch"}"#.utf8))
        #expect(mismatch.verification.contains("不同"))
    }
}

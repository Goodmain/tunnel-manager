import XCTest
@testable import TunnelManager

final class ECSResolverTests: XCTestCase {
    func testParseTaskArns() throws {
        let json = #"{"taskArns":["arn:aws:ecs:us-east-1:123:task/cluster/abc123","arn:aws:ecs:us-east-1:123:task/cluster/def456"]}"#
        let arns = try ECSResolver.parseTaskArns(json)
        XCTAssertEqual(arns.count, 2)
        XCTAssertEqual(arns.first, "arn:aws:ecs:us-east-1:123:task/cluster/abc123")
    }

    func testParseTaskArnsEmptyMeansNoTasks() throws {
        // Empty array → resolve() would throw .noRunningTasks because .first is nil.
        let arns = try ECSResolver.parseTaskArns(#"{"taskArns":[]}"#)
        XCTAssertTrue(arns.isEmpty)
    }

    func testParseTargetExtractsTaskAndRuntimeId() throws {
        let json = """
        {"tasks":[{"taskArn":"arn:aws:ecs:us-east-1:123:task/cluster/abc123",
        "containers":[{"name":"app","runtimeId":"abc123-456"}]}]}
        """
        let (taskId, container, runtimeId) = try ECSResolver.parseTarget(json, remotePort: 5432)
        XCTAssertEqual(taskId, "abc123")
        XCTAssertEqual(container, "app")
        XCTAssertEqual(runtimeId, "abc123-456")
    }

    func testParseTargetPrefersContainerWithRuntimeId() throws {
        let json = """
        {"tasks":[{"taskArn":"arn:aws:ecs:us-east-1:123:task/cluster/abc123",
        "containers":[{"name":"sidecar"},{"name":"app","runtimeId":"abc123-456"}]}]}
        """
        let (_, container, runtimeId) = try ECSResolver.parseTarget(json, remotePort: 5432)
        XCTAssertEqual(container, "app")
        XCTAssertEqual(runtimeId, "abc123-456")
    }

    func testParseTaskArnsBadJSONThrows() {
        XCTAssertThrowsError(try ECSResolver.parseTaskArns("not json"))
    }
}

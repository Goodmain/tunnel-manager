import Foundation

/// Resolves an ECS cluster into an SSM target `ecs:{cluster}_{taskId}_{runtimeId}`
/// (ecs-target-resolution capability, design D6). Fresh on every (re)connect.
struct ECSResolver {
    /// Inputs needed to run the two aws calls under aws-vault.
    struct Context {
        let awsVaultPath: String
        let environment: [String: String]
        let profile: String
        let cluster: String
        /// Used to pick a container in a multi-container task.
        let remotePort: Int
    }

    enum ResolveError: LocalizedError {
        case noRunningTasks
        case awsError(String)
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .noRunningTasks: return "No running ECS task found in the cluster."
            case .awsError(let message): return "AWS error: \(message)"
            case .parseError(let message): return "Could not parse AWS response: \(message)"
            }
        }
    }

    struct Resolution {
        let target: String
        let chosenTaskId: String
        let chosenContainerName: String
    }

    // Run off the main actor (blocking aws calls).
    static func resolve(_ ctx: Context) throws -> Resolution {
        let listArgs = vaultArgs(ctx, [
            "aws", "ecs", "list-tasks",
            "--cluster", ctx.cluster,
            "--desired-status", "RUNNING",
            "--output", "json",
        ])
        let listResult = try CommandRunner.run(executable: ctx.awsVaultPath, arguments: listArgs, environment: ctx.environment)
        guard listResult.exitCode == 0 else {
            throw ResolveError.awsError(listResult.stderr.isEmpty ? "list-tasks failed" : listResult.stderr)
        }

        let taskArns = try parseTaskArns(listResult.stdout)
        guard let firstArn = taskArns.first else {
            throw ResolveError.noRunningTasks
        }
        // v1: first RUNNING task (design D6). Log the choice.
        NSLog("ECS resolve: %d running task(s) in %@, choosing %@", taskArns.count, ctx.cluster, firstArn)

        let describeArgs = vaultArgs(ctx, [
            "aws", "ecs", "describe-tasks",
            "--cluster", ctx.cluster,
            "--tasks", firstArn,
            "--output", "json",
        ])
        let describeResult = try CommandRunner.run(executable: ctx.awsVaultPath, arguments: describeArgs, environment: ctx.environment)
        guard describeResult.exitCode == 0 else {
            throw ResolveError.awsError(describeResult.stderr.isEmpty ? "describe-tasks failed" : describeResult.stderr)
        }

        let (taskId, containerName, runtimeId) = try parseTarget(describeResult.stdout, remotePort: ctx.remotePort)
        NSLog("ECS resolve: task %@ container %@ runtime %@", taskId, containerName, runtimeId)
        let target = "ecs:\(ctx.cluster)_\(taskId)_\(runtimeId)"
        return Resolution(target: target, chosenTaskId: taskId, chosenContainerName: containerName)
    }

    private static func vaultArgs(_ ctx: Context, _ command: [String]) -> [String] {
        ["exec", ctx.profile, "--prompt=osascript", "--"] + command
    }

    // MARK: - Parsing (Codable, not regex)

    private struct ListTasksResponse: Decodable { let taskArns: [String] }

    private static func parseTaskArns(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8) else { throw ResolveError.parseError("empty list-tasks output") }
        do {
            return try JSONDecoder().decode(ListTasksResponse.self, from: data).taskArns
        } catch {
            throw ResolveError.parseError(error.localizedDescription)
        }
    }

    private struct DescribeTasksResponse: Decodable {
        struct Task: Decodable {
            let taskArn: String
            let containers: [Container]
        }
        struct Container: Decodable {
            let name: String
            let runtimeId: String?
        }
        let tasks: [Task]
    }

    /// Returns (taskId, containerName, runtimeId). Container selection (D6): the
    /// one exposing remotePort isn't in this payload, so pick first with a
    /// runtimeId; fall back to first container.
    private static func parseTarget(_ json: String, remotePort: Int) throws -> (String, String, String) {
        guard let data = json.data(using: .utf8) else { throw ResolveError.parseError("empty describe-tasks output") }
        let decoded: DescribeTasksResponse
        do {
            decoded = try JSONDecoder().decode(DescribeTasksResponse.self, from: data)
        } catch {
            throw ResolveError.parseError(error.localizedDescription)
        }
        guard let task = decoded.tasks.first else { throw ResolveError.noRunningTasks }
        let taskId = String(task.taskArn.split(separator: "/").last ?? "")

        let containerWithRuntime = task.containers.first(where: { $0.runtimeId != nil })
        guard let container = containerWithRuntime ?? task.containers.first,
              let runtimeId = container.runtimeId else {
            throw ResolveError.parseError("no container runtime id in task")
        }
        return (taskId, container.name, runtimeId)
    }
}

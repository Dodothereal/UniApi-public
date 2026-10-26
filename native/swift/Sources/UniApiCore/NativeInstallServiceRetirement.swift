import Foundation

/// Compatibility facade for failed-install cleanup. A completed rollback keeps
/// the candidate services running, so it never authorizes replacing their files.
public enum NativeInstallServiceRetirement {
    public static func retire(paths: NativePaths, application: URL, instance: String) async -> JSONValue {
        do {
            let dependencies = try NativeUpdateDependencies.production(paths: paths, application: application)
            return await retire(paths: paths, application: application, instance: instance, dependencies: dependencies.system,
                                gui: dependencies.gui, nativeStatus: dependencies.nativeStatus)
        } catch { return result(["status": "refused", "message": .string(error.localizedDescription)]) }
    }
    static func nativeWork(paths: NativePaths) -> @Sendable () throws -> NativeTransferWork {
        let reader = NativeInstallWorkReader(paths: paths)
        return { try reader.read() }
    }
    static func retire(paths: NativePaths, application: URL, instance: String, dependencies: NativeLegacySystemDependencies,
                       gui: @escaping NativeUpdateGUIAdmission.Reader = { try NativeUpdateGUIAdmission.read() },
                       nativeStatus: (@Sendable (Int32, String) throws -> JSONValue)? = nil) async -> JSONValue {
        do {
            let context = try NativeInstallRetirementSystem(paths: paths, application: application, instance: instance, dependencies: dependencies,
                                                            gui: gui, nativeStatus: nativeStatus)
            return result(await NativeLegacyRetirement.retire(paths: paths, io: context.makeIO(), retirementDeadline: 30, rollbackDeadline: 30))
        } catch { return result(["status": "refused", "message": .string(error.localizedDescription)]) }
    }
    private static func result(_ transaction: JSONValue) -> JSONValue {
        let status = transaction["status"].string, retired = status == "retired", partial = status == "recovery-incomplete"
        return ["status": .string(retired ? "retired" : partial ? "partial-recovery" : "refused"),
                "transactionStatus": .string(status), "safeToRestore": .bool(retired), "partialRecovery": .bool(partial),
                "message": transaction["message"]]
    }
}

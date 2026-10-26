import Foundation
import Darwin

// This helper has two privileged shapes, and they differ only in who may talk to it and what
// ends the process. Everything that touches hardware - acquisition, the heartbeat lease, the
// thermal floor, every release path - is the same Controller in both.
//
//   --serve UID PID   one temporary session belonging to one UniApi server process. Launched
//                     through the macOS administrator dialog, so it costs a password every time
//                     the server restarts. Dies with its server.
//   --daemon UID      the installed LaunchDaemon (see install-daemon.sh). It outlives every
//                     server process, which is the whole point: the password is paid once at
//                     install time. Having no owner process, it cannot bind to an owner PID and
//                     authenticates the connecting UID alone - see native/fans/README.md for
//                     what that widens and why the bounded command vocabulary is what holds.
if CommandLine.arguments.count == 2, ["--monitor", "--probe"].contains(CommandLine.arguments[1]) {
    do {
        let hardware = try Hardware()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        repeat {
            let data = try encoder.encode(hardware.snapshot())
            print(String(data:data,encoding:.utf8)!); fflush(stdout)
            if CommandLine.arguments[1] == "--probe" { exit(0) }
            Thread.sleep(forTimeInterval:2)
        } while true
    } catch { fputs(error.localizedDescription + "\n",stderr); exit(1) }
}
let arguments = CommandLine.arguments
// `owner` nil means the installed daemon: no owner process to outlive, no owner PID to check.
let uid: UInt32, owner: pid_t?
if arguments.count == 4, arguments[1] == "--serve", let u = UInt32(arguments[2]), u >= 501,
   let pid = Int32(arguments[3]), pid > 1 { uid = u; owner = pid }
else if arguments.count == 3, arguments[1] == "--daemon", let u = UInt32(arguments[2]), u >= 501 { uid = u; owner = nil }
else { exit(64) }
guard geteuid() == 0 else { exit(64) }
let daemon = owner == nil
signal(SIGPIPE,SIG_IGN)
let hardware: Hardware
do { hardware = try Hardware() } catch { exit(1) }
let controller = Controller(hardware:hardware)
let folder = IPC.directory(uid)
if mkdir(folder,0o755) != 0 && errno != EEXIST { exit(1) }
var info = stat()
guard lstat(folder,&info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0, info.st_mode & 0o022 == 0 else { exit(1) }
let socketPath = daemon ? IPC.controlPath(uid) : IPC.path(uid,owner!)
let fd = socket(AF_UNIX,SOCK_STREAM,0)
guard fd >= 0 else { exit(1) }
// Never unlink a live session: duplicate enabling must fail instead of stealing it. A session
// path is unique per server PID, so a leftover file there cannot be live. The daemon's path is
// fixed, so a crash leaves a socket nobody is listening on and bind would fail forever - probe
// it first and only remove the ones that refuse a connection.
if daemon, access(socketPath,F_OK) == 0 {
    if IPC.reachable(socketPath) { fputs("another uniapi-fans daemon owns \(socketPath)\n",stderr); exit(1) }
    unlink(socketPath)
}
var address = IPC.address(socketPath)
let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard bound == 0 else { exit(1) }
chown(socketPath,uid,gid_t.max); chmod(socketPath,0o600)
listen(fd,4)
var running = true
signal(SIGTERM,SIG_IGN); signal(SIGINT,SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal:SIGTERM,queue:.global())
termination.setEventHandler { running = false }; termination.resume()
let interruption = DispatchSource.makeSignalSource(signal:SIGINT,queue:.global())
interruption.setEventHandler { running = false }; interruption.resume()
let power = PowerObserver {
    // Sleep always returns the fans to macOS before the machine goes down. A temporary session
    // ends there because its server may be gone when the Mac wakes; the daemon keeps listening,
    // so the server can re-apply a kept profile on wake without another password. Either way the
    // hardware is handed back first - waking never resumes an override by itself.
    if !daemon { running = false }
    try? controller.release("Sleep restored automatic control.")
}
guard power.available else { close(fd); unlink(socketPath); exit(1) }
var lastActivity = Date(), lastTick = Date()
while running && (owner.map { kill($0,0) == 0 } ?? true) {
    CFRunLoopRunInMode(.defaultMode,0.001,false)
    if !running { break }
    if Date().timeIntervalSince(lastTick) > 5 {
        // A suspend/resume discontinuity ends the override even if a power event was missed.
        try? controller.release("The control session was interrupted.")
        if !daemon { break }
        lastTick = Date()
    }
    var poller = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
    if poll(&poller,1,250) > 0 {
        let client = accept(fd,nil,nil)
        if client >= 0 {
            var peerUID: uid_t = 0, peerGID: gid_t = 0, peerPID: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            var authorized = getpeereid(client,&peerUID,&peerGID) == 0 && peerUID == uid
            if let owner { authorized = authorized && getsockopt(client,SOL_LOCAL,LOCAL_PEERPID,&peerPID,&size) == 0 && peerPID == owner }
            if authorized {
                var timeout = timeval(tv_sec:1,tv_usec:0)
                setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                do {
                    let request = try JSONDecoder().decode(ControlRequest.self,from:IPC.readLine(fd:client))
                    let reply = controller.handle(request)
                    // Hardware acquisition may take several seconds; do not mistake it for sleep.
                    lastTick = Date()
                    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
                    var data = try encoder.encode(reply); data.append(10)
                    try IPC.sendData(data,fd:client); lastActivity = Date()
                } catch { }
            }
            close(client)
        }
    }
    if Date().timeIntervalSince(lastTick) >= 1 {
        do { try controller.tick() } catch { }
        lastTick = Date()
    }
    // A session with nobody talking to it is abandoned. The daemon is supposed to sit idle
    // between servers; its own heartbeat lease is what stops an *override* outliving its client.
    if !daemon && Date().timeIntervalSince(lastActivity) > 300 { break }
}
// A failed restoration never discards the watchdog. Keep retrying while denying
// further overrides; the UniApi server shows a disconnected session and can still monitor.
var backoff: Double = 0.5
while true {
    do { try controller.release("Control session ended."); break }
    catch { Thread.sleep(forTimeInterval:backoff); backoff = min(5,backoff*2) }
}
close(fd); unlink(socketPath)

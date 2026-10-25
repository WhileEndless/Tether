import Foundation
import Testing
@testable import MonitorKit

/// Every table of the host panel exports as CSV with all its fields.
@Suite struct PanelExportTests {
    func rows(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    @Test func processes() {
        let p = ProcessEntry(pid: 42, user: "user", cpu: 12.5, mem: 1.25, rssKB: 2048, elapsed: "01:02", command: "/usr/bin/python3 -m http.server")
        let r = rows(MonitorExport.processes([p]))
        #expect(r[0] == "pid,user,cpu_percent,memory_percent,resident_bytes,elapsed,name,command")
        #expect(r[1] == "42,user,12.50,1.25,2097152,01:02,python3,/usr/bin/python3 -m http.server")
    }

    @Test func listeningAndConnections() {
        let l = ListeningSocket(proto: "tcp", address: "0.0.0.0", port: 443, process: "nginx", pid: 7, container: nil)
        let lr = rows(MonitorExport.listening([l]))
        #expect(lr[1].hasPrefix("tcp,0.0.0.0,443,HTTPS,"))
        #expect(lr[1].hasSuffix(",nginx,7,"))
        let c = ConnectionEntry(local: "192.0.2.1:22", peer: "192.0.2.9:51000", state: "ESTAB", process: "sshd", isSSH: true)
        #expect(rows(MonitorExport.tcpConnections([c]))[1] == "192.0.2.1:22,192.0.2.9:51000,192.0.2.9,51000,,ESTAB,sshd,yes")
        let login = LoginEntry(user: "user", terminal: "pts/0", since: "10:00", from: "192.0.2.9")
        #expect(rows(MonitorExport.logins([login]))[1] == "user,pts/0,10:00,192.0.2.9")
    }

    @Test func servicesContainersPodsGPUs() {
        let s = ServiceEntry(name: "nginx.service", load: "loaded", active: "active", sub: "running", description: "web, proxy")
        #expect(rows(MonitorExport.services([s]))[1] == "nginx.service,loaded,active,running,\"web, proxy\"")
        let c = ContainerEntry(id: "abc", image: "nginx:1", name: "web", status: "Up 2 hours", state: "running", ports: "0.0.0.0:8080->80/tcp", engine: "docker")
        #expect(rows(MonitorExport.containers([c]))[1] == "abc,web,nginx:1,running,Up 2 hours,0.0.0.0:8080->80/tcp,docker")
        let pod = KubePod(namespace: "default", name: "web-1", phase: "Running", node: "node-a", created: nil, terminating: false,
                          containers: [.init(ready: true, restarts: 2, reason: ""), .init(ready: false, restarts: 1, reason: "CrashLoopBackOff")])
        let pr = rows(MonitorExport.pods([pod]))
        #expect(pr[1].hasPrefix("default,web-1,"))
        #expect(pr[1].contains(",1,2,3,node-a,"))
        #expect(pr[1].hasSuffix(",CrashLoopBackOff,\"1: ready, 2 restarts; 2: not ready, 1 restarts, CrashLoopBackOff\""))
        let g = GPUInfo(index: 0, vendor: .nvidia, name: "GPU A", utilization: 0.5, memoryUsed: 1024, memoryTotal: 4096,
                        temperature: 60, power: 100, powerLimit: 200, uuid: "GPU-0000")
        let gp = GPUProcess(pid: 9, name: "train", memoryUsed: 512, gpu: "GPU-0000")
        let gr = rows(MonitorExport.gpus([g], processes: [gp]))
        #expect(gr[1] == "gpu,0,GPU-0000,NVIDIA,GPU A,50,1024,4096,60,100,200,")
        #expect(gr[2] == "process,0,GPU-0000,,train,,512,,,,,9")          // matched to its GPU by id
    }

    @Test func tablesExportAsJSON() throws {
        let p = ProcessEntry(pid: 42, user: "user", cpu: 1, mem: 2, rssKB: 1, elapsed: "1", command: "top")
        let json = try #require(JSONSerialization.jsonObject(with: MonitorExport.processes([p], format: .json)) as? [[String: String]])
        #expect(json.count == 1 && json[0]["pid"] == "42" && json[0]["command"] == "top" && json[0]["resident_bytes"] == "1024")
    }
}

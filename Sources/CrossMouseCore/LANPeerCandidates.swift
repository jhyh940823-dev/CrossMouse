import Darwin
import Foundation
import Network

/// Uses the actual attached address/netmask, not a saved prefix or a scan of
/// every network adapter. A new/different LAN requires explicit configuration.
enum LANPeerCandidates {
    static func snapshot(previous: String, port: UInt16, path: NWPath?) -> [PeerEndpoint] {
        guard let path, path.status == .satisfied else { return [] }
        let interfaces = path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var rows: [(address: String, mask: String, interface: NWInterface)] = []
        var next = head
        while let pointer = next {
            next = pointer.pointee.ifa_next
            let row = pointer.pointee
            guard row.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  row.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = row.ifa_addr, Int32(address.pointee.sa_family) == AF_INET,
                  let mask = row.ifa_netmask, Int32(mask.pointee.sa_family) == AF_INET,
                  let interface = interfaces.first(where: { $0.name == String(cString: row.ifa_name) }) else { continue }
            func dotted(_ value: UnsafeMutablePointer<sockaddr>) -> String {
                value.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    LocalPeerSubnet.string(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
                }
            }
            rows.append((dotted(address), dotted(mask), interface))
        }
        var excluded = Set(rows.map(\.address))
        for gateway in path.gateways {
            if case .hostPort(let host, _) = gateway { excluded.insert(String(describing: host)) }
        }
        // Exactly one directly attached subnet per sweep; total work remains
        // bounded even on a machine with Wi-Fi plus several Ethernet adapters.
        for row in rows {
            let addresses = LocalPeerSubnet.candidates(previous: previous, local: row.address,
                                                        netmask: row.mask, excluding: excluded)
            if !addresses.isEmpty {
                return addresses.map { PeerEndpoint(host: $0, port: port, interface: row.interface) }
            }
        }
        return []
    }
}

import Foundation

/// An address is a route hint, never the paired computer's identity. Enumerate
/// only a small, directly attached private subnet containing the previous peer.
/// No guessed /24 on a wider network, public ranges, gateways, broadcast, VPNs
/// or arbitrary port ranges. The caller still authenticates every candidate.
public enum LocalPeerSubnet {
    public static func address(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let value = UInt8(part), String(value) == part else { return nil }
            result = (result << 8) | UInt32(value)
        }
        return result
    }

    public static func string(_ address: UInt32) -> String {
        [24, 16, 8, 0].map { String((address >> $0) & 255) }.joined(separator: ".")
    }

    private static func isPrivate(_ value: UInt32) -> Bool {
        value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8
    }

    public static func candidates(previous: String, local: String, netmask: String,
                                  excluding: Set<String> = []) -> [String] {
        guard let peer = address(previous), let own = address(local), let mask = address(netmask),
              isPrivate(peer), isPrivate(own) else { return [] }
        let inverse = ~mask
        // A real contiguous /24 ... /30 netmask: at most 254 host candidates.
        guard inverse >= 3, inverse <= 255, (inverse & (inverse + 1)) == 0 else { return [] }
        let network = own & mask, broadcast = network | inverse
        guard peer & mask == network, peer > network, peer < broadcast,
              own > network, own < broadcast else { return [] }
        // Nearby DHCP allocations first. This changes search order, not scope.
        return ((network + 1)..<broadcast)
            .filter { $0 != own && $0 != peer && !excluding.contains(string($0)) }
            .sorted {
                let a = abs(Int64($0) - Int64(peer)), b = abs(Int64($1) - Int64(peer))
                return a == b ? $0 < $1 : a < b
            }
            .map(string)
    }
}

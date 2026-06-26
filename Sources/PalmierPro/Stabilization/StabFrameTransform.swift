import Foundation
import simd

/// One frame's motion as a normalized-coordinate homography (row-major 3×3),
/// stored flat for Codable. Identity = no motion.
struct StabFrameTransform: Codable, Sendable, Equatable {
    var m: [Double]   // 9 elements, row-major

    static let identity = StabFrameTransform(m: [1,0,0, 0,1,0, 0,0,1])

    init(m: [Double]) { self.m = m.count == 9 ? m : Self.identity.m }

    init(_ matrix: simd_double3x3) {
        // simd is column-major; flatten to row-major.
        m = [
            matrix[0][0], matrix[1][0], matrix[2][0],
            matrix[0][1], matrix[1][1], matrix[2][1],
            matrix[0][2], matrix[1][2], matrix[2][2],
        ]
    }

    var matrix: simd_double3x3 {
        simd_double3x3(rows: [
            SIMD3(m[0], m[1], m[2]),
            SIMD3(m[3], m[4], m[5]),
            SIMD3(m[6], m[7], m[8]),
        ])
    }
}

import Foundation
import zlib

/// gzip (RFC 1952) compression over zlib.
package enum Gzip {
    package struct Failure: Error, Equatable {
        package let code: Int32
    }

    /// windowBits 15 + 16 selects the gzip wrapper.
    private static let gzipWindowBits: Int32 = 15 + 16
    private static let chunkSize = 64 * 1024

    package static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, gzipWindowBits, 8,
                                   Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure(code: status) }
        defer { deflateEnd(&stream) }

        var output = Data()
        var input = data
        status = input.withUnsafeMutableBytes { (src: UnsafeMutableRawBufferPointer) -> Int32 in
            stream.next_in = src.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(src.count)
            return pump(&stream, into: &output) { deflate(&$0, Z_FINISH) }
        }
        guard status == Z_STREAM_END else { throw Failure(code: status) }
        return output
    }

    /// Used by tests to check the wire bytes.
    package static func decompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(&stream, gzipWindowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure(code: status) }
        defer { inflateEnd(&stream) }

        var output = Data()
        var input = data
        status = input.withUnsafeMutableBytes { (src: UnsafeMutableRawBufferPointer) -> Int32 in
            stream.next_in = src.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(src.count)
            return pump(&stream, into: &output) { inflate(&$0, Z_NO_FLUSH) }
        }
        guard status == Z_STREAM_END else { throw Failure(code: status == Z_OK ? Z_DATA_ERROR : status) }
        return output
    }

    /// Runs `step` until the stream ends, errors, or stops making progress,
    /// appending each output chunk. Returns the last zlib status.
    private static func pump(_ stream: inout z_stream, into output: inout Data,
                             _ step: (inout z_stream) -> Int32) -> Int32 {
        var buffer = [Bytef](repeating: 0, count: chunkSize)
        var status: Int32 = Z_OK
        repeat {
            let produced: Int = buffer.withUnsafeMutableBufferPointer { out in
                stream.next_out = out.baseAddress
                stream.avail_out = uInt(out.count)
                status = step(&stream)
                return out.count - Int(stream.avail_out)
            }
            output.append(buffer, count: produced)
            if status == Z_BUF_ERROR && produced == 0 { break }
        } while status == Z_OK
        return status
    }
}

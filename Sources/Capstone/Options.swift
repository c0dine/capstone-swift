import Foundation
import Ccapstone

/// Runtime option for the disassembled engine
public enum DisassemblyOption {
    /// Assembly output syntax
    case syntax(syntax: Syntax)
    /// Break down instruction structure into details
    case detail(value: Bool)
    /// Change engine's mode at run-time
    case mode(mode: Mode)
    /// Skip data when disassembling.
    /// should be skipData(enabled: Bool) but swift is buggy, see https://bugs.swift.org/browse/SR-10077
    case skipDataEnabled(_ enabled: Bool)
    /// Custom setup to skip data when disassembling:
    /// * mnemonic: If nil, ".byte" is used
    /// * callback: User-defined callback to be called when Capstone hits data.
    /// NOTE: if this callback pointer is nil, Capstone would skip a number of bytes depending on architectures, as following:
    ///   * Arm:     2 bytes (Thumb mode) or 4 bytes.
    ///   * Arm64:   4 bytes.
    ///   * Mips:    4 bytes.
    ///   * M680x:   1 byte.
    ///   * PowerPC: 4 bytes.
    ///   * Sparc:   4 bytes.
    ///   * SystemZ: 2 bytes.
    ///   * X86:     1 bytes.
    ///   * XCore:   2 bytes.
    ///   * EVM:     1 bytes.
    ///   * MOS65XX: 1 bytes.
    case skipData(mnemonic: String?, callback: SkipDataCallback?)
    /// Customize instruction mnemonic
    case mnemonic(_ mnemonic: String?, instruction: InstructionType)
    /// Print immediate operands in unsigned form
    case unsigned(value: Bool)
}

/// Return value for a skip data callback
public enum SkipDataResult {
    /// Stop disassembling and return
    case stop
    /// Skip a non-zero number of bytes and continue
    case skip(bytes: Int)
}

/// User-defined callback for skipData option.
///
/// - parameter capstone: `Capstone` instance
/// - parameter code: code being disassembled
/// - parameter offset: the position of the currently-examining byte
/// - returns: a `SkipDataResult` instructing to skip a number of bytes, or stop the disassembly
public typealias SkipDataCallback = (_ capstone: Capstone, _ code: Data, _ offset: Data.Index) -> SkipDataResult

extension Capstone {
    public func set(option: DisassemblyOption) throws {
        let err: cs_err
        switch option {
        case .syntax(syntax: let syntax):
            err = cs_option(handle, CS_OPT_SYNTAX, syntax.rawValue)
        case .detail(value: let value):
            err = cs_option(handle, CS_OPT_DETAIL, value.csOptValue)
            if err == CS_ERR_OK {
                detail = value
            }
        case .unsigned(value: let value):
            err = cs_option(handle, CS_OPT_UNSIGNED, value.csOptValue)
        case .mode(mode: let mode):
            err = cs_option(handle, CS_OPT_MODE, Int(mode.rawValue))
        case .skipDataEnabled(let enabled):
            err = cs_option(handle, CS_OPT_SKIPDATA, enabled.csOptValue)
        case .skipData(mnemonic: let mnemonic, callback: let callback):
            updateMnemonicPointer(mnemonic: mnemonic)
            skipDataCallback = callback
            let cb: cs_skipdata_cb_t!
            if callback == nil {
                cb = nil
            } else {
                cb = { (code, codeSize, offset, userData) -> Int in
                    let cs = Unmanaged<Capstone>.fromOpaque(userData!).takeUnretainedValue()
                    switch(cs.skipDataCallback!(cs, cs.currentCode!, offset)) {
                    case .skip(bytes: let bytes):
                        return bytes
                    case .stop:
                        return 0
                    }
                }
            }
            
            err = withUnsafePointer(to: cs_opt_skipdata(mnemonic: skipDataMnemonicPtr,
                                                        callback: cb,
                                                        user_data: Unmanaged.passUnretained(self).toOpaque()
            ), {
                cs_option(handle, CS_OPT_SKIPDATA, true.csOptValue)
                return cs_option(handle, CS_OPT_SKIPDATA_SETUP, Int(bitPattern: $0))
            })
        case .mnemonic(_: let mnemonic, instruction: let instruction):
            err = mnemonic.withCString { mnemonicPtr in
                withUnsafePointer(to: cs_opt_mnem(id: instruction.rawValue, mnemonic: mnemonicPtr)) {
                    cs_option(handle, CS_OPT_MNEMONIC, Int(bitPattern: $0))
                }
            }
        }
        if err != CS_ERR_OK {
            throw CapstoneError(err)
        }
    }
    
    private func updateMnemonicPointer(mnemonic: String?) {
        // mnemonic pointer used in cs_opt_skipdata must live as long as the handle is used
        skipDataMnemonicPtr?.deallocate()
        skipDataMnemonicPtr = UnsafeMutablePointer<Int8>(string: mnemonic)
    }
}

internal extension Optional where Wrapped == String {
    @inlinable func withCString<Result>(_ body: (UnsafePointer<Int8>?) throws -> Result) rethrows -> Result {
        guard let string = self else {
            return try body(nil)
        }
        return try string.withCString({ try body($0) })
    }
}

internal extension UnsafeMutablePointer where Pointee == Int8 {
    init?(string: String?) {
        guard let string = string else {
            return nil
        }
        let byteCount = 1 + string.lengthOfBytes(using: .utf8)
        self = UnsafeMutablePointer<Int8>.allocate(capacity: byteCount)
        string.withCString({ self.initialize(from: $0, count: byteCount) })
    }
}

fileprivate extension Bool {
    var csOptValue: Int {
        return Int((self ? CS_OPT_ON : CS_OPT_OFF).rawValue)
    }
}

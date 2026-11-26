// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import Foundation
import Security

/// Values for `{!name}` snippet placeholders, kept in the login keychain.
/// A value is read only to hand to the core for one run, as
/// `TERMIGHT_SECRET_<name>`; it never goes into the typed line, the history or
/// the logs (the core replaces it with •••• in output).
enum Secrets {
    static let service = "ca.nordqvist.termight.secret"
    static let envPrefix = "TERMIGHT_SECRET_"

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// A secret's name becomes part of a variable name: letters, digits, `_`.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
            && !(name.first?.isNumber ?? true)
    }

    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    static func value(_ name: String) -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ name: String, _ value: String) throws {
        guard isValidName(name) else { throw Failure(errorDescription: "A secret's name can hold only letters, digits and _.") }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query(name) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(name)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Termight secret: \(name)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            let why = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw Failure(errorDescription: "The Keychain refused: \(why)")
        }
    }

    static func delete(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }

    static func names() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// Environment for the secrets named, and the names not in the Keychain.
    static func environment(for names: [String]) -> (env: [String: String], missing: [String]) {
        var env: [String: String] = [:]
        var missing: [String] = []
        for name in names {
            if let v = value(name) { env[envPrefix + name] = v } else { missing.append(name) }
        }
        return (env, missing)
    }
}

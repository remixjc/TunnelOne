// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NetworkExtension

NEProvider.startSystemExtensionMode()
let controlService = ControlService()
do {
    try controlService.start()
    dispatchMain()
} catch {
    // Never print configuration payloads or key material.
    exit(EXIT_FAILURE)
}

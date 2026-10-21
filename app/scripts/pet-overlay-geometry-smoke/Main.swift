import Foundation
import CoreGraphics

var checks = 0
let petSize = CGSize(width: 72 * 1.12, height: 72 * 1.48)
for window in [CGSize(width: 640, height: 438), CGSize(width: 960, height: 578), CGSize(width: 1280, height: 838)] {
    for x in stride(from: -2000.0, through: 2000.0, by: 200) {
        for y in stride(from: -2000.0, through: 2000.0, by: 200) {
            let offset = PetOverlayGeometry.clamp(CGSize(width: x, height: y), window: window, size: petSize, margin: 12)
            let pet = PetOverlayGeometry.petFrame(offset: offset, window: window, size: petSize, margin: 12)
            let bounds = CGRect(x: 11.999, y: 11.999, width: window.width - 23.998, height: window.height - 23.998)
            precondition(bounds.contains(pet), "Pet escaped \(window): \(pet)")
            for preferred in [CGSize(width: 420, height: 480), CGSize(width: 180, height: 44), CGSize(width: 330, height: 88)] {
                let popup = PetOverlayGeometry.popupFrame(near: pet, window: window, preferred: preferred, margin: 12)
                precondition(bounds.contains(popup), "Popup escaped \(window): \(popup)")
                let unchanged = PetOverlayGeometry.petFrame(offset: offset, window: window, size: petSize, margin: 12)
                precondition(unchanged == pet, "Opening a popup changed the pet anchor")
                checks += 1
            }
        }
    }
}
print("PASS: \(checks) geometry checks; pet/popup remain visible and anchor independent")

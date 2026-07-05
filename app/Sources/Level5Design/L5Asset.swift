import AppKit
import SwiftUI

public enum L5Asset {
    public static var mark: Image {
        if let url = Level5DesignResources.identityMarkURL, let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }

        return Image(systemName: "shippingbox")
    }
}

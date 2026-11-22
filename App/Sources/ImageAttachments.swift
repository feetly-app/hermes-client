import Foundation
import HermesAPI
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Turns picked photos into `ImageAttachment`s and makes thumbnails from them.
///
/// Photos are downscaled to `maxDimension` and re-encoded as JPEG, which keeps each request well under
/// the instance's 10 MB body limit.
enum ImageAttachmentLoader {
    static let maxDimension = 2048
    static let jpegQuality = 0.8

    static func attachment(from item: PhotosPickerItem) async -> ImageAttachment? {
        guard let raw = try? await item.loadTransferable(type: Data.self) else { return nil }
        return jpegAttachment(from: raw)
    }

    static func jpegAttachment(from data: Data) -> ImageAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ImageAttachment(mimeType: "image/jpeg", data: output as Data)
    }

    /// A small preview of image data, or `nil` when the data is not a readable image.
    static func thumbnail(for data: Data, maxPixelSize: Int = 240) -> Image? {
        preview(for: data, maxPixelSize: maxPixelSize)?.image
    }

    /// A preview of image data with its size in pixels, oriented, or `nil` when the data is not a readable
    /// image. The size gives the aspect ratio a message draws the image at.
    static func preview(for data: Data, maxPixelSize: Int) -> ImagePreview? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return ImagePreview(
            image: Image(decorative: cgImage, scale: 1),
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

/// A decoded image and its size in pixels.
struct ImagePreview {
    let image: Image
    let pixelSize: CGSize

    /// Width over height, 1 for an empty size.
    var aspectRatio: CGFloat {
        pixelSize.height > 0 && pixelSize.width > 0 ? pixelSize.width / pixelSize.height : 1
    }
}

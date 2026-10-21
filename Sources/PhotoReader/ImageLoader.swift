import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct PreparedImage: Sendable {
    var encoded: Data
    var mime: String
    var page: Int
    var pageCount: Int
    var pdfData: Data?

    var dataURL: String {
        "data:\(mime);base64,\(encoded.base64EncodedString())"
    }
}

enum ImageLoadError: LocalizedError, Sendable {
    case unsupported
    case unreadableImage
    case unreadablePDF
    case pageOutOfRange(Int)
    case encodeFailed
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "That file isn't a photo or PDF Photo Reader can open."
        case .unreadableImage:
            return "Could not read that image."
        case .unreadablePDF:
            return "Could not read that PDF."
        case .pageOutOfRange(let count):
            let pages = count == 1 ? "1 page" : "\(count) pages"
            return "That PDF has \(pages)."
        case .encodeFailed:
            return "Could not prepare that image."
        case .tooLarge:
            return "That file is too large."
        }
    }
}

enum ImageLoader {
    static let maxSide: CGFloat = 1400
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "tif"]
    private static let pdfMagic = Data([0x25, 0x50, 0x44, 0x46])
    private static let jpegMagic = Data([0xFF, 0xD8, 0xFF])
    private static let byteCap = 80 * 1024 * 1024

    static func looksSupported(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || imageExtensions.contains(ext) { return true }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf) || type.conforms(to: .image)
        }
        return false
    }

    static func load(data: Data, filename: String) throws -> PreparedImage {
        if data.isEmpty { throw ImageLoadError.unreadableImage }
        if data.count > byteCap { throw ImageLoadError.tooLarge }
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "pdf" || data.starts(with: pdfMagic) {
            return try renderPDF(data: data, page: 1)
        }
        do {
            return try renderImage(data: data, filename: filename)
        } catch {
            if ext.isEmpty || imageExtensions.contains(ext) { throw error }
            throw ImageLoadError.unsupported
        }
    }

    static func renderPDF(data: Data, page: Int) throws -> PreparedImage {
        if data.count > byteCap { throw ImageLoadError.tooLarge }
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw ImageLoadError.unreadablePDF
        }
        let count = document.pageCount
        guard page >= 1, page <= count, let pdfPage = document.page(at: page - 1) else {
            throw ImageLoadError.pageOutOfRange(count)
        }
        let image = try render(pdfPage)
        let encoded = try encode(image, jpeg: false)
        return PreparedImage(
            encoded: encoded.data,
            mime: encoded.mime,
            page: page,
            pageCount: count,
            pdfData: data
        )
    }

    static func capture(_ work: @Sendable () throws -> PreparedImage) -> Result<PreparedImage, ImageLoadError> {
        do {
            return .success(try work())
        } catch let error as ImageLoadError {
            return .failure(error)
        } catch {
            return .failure(.unreadableImage)
        }
    }

    private static func renderImage(data: Data, filename: String) throws -> PreparedImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw ImageLoadError.unreadableImage
        }
        guard CGImageSourceGetCount(source) > 0 else { throw ImageLoadError.unreadableImage }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageLoadError.unreadableImage
        }
        let fitted = fit(image, maxSide: maxSide)
        let encoded = try encode(fitted, jpeg: prefersJPEG(data: data, filename: filename))
        return PreparedImage(encoded: encoded.data, mime: encoded.mime, page: 1, pageCount: 1, pdfData: nil)
    }

    /// PDFKit thumbnail renders rotation. Fit the bitmap so the longest side is about 1400 pixels.
    private static func render(_ page: PDFPage) throws -> CGImage {
        let boxes: [PDFDisplayBox] = [.cropBox, .mediaBox]
        var chosen: (PDFDisplayBox, CGSize)?
        for box in boxes {
            let bounds = page.bounds(for: box)
            let width = abs(bounds.width)
            let height = abs(bounds.height)
            if width > 1, height > 1 {
                chosen = (box, CGSize(width: width, height: height))
                break
            }
        }
        guard let (box, size) = chosen else { throw ImageLoadError.unreadablePDF }
        let scale = maxSide / max(size.width, size.height)
        let pointSize = CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
        let thumb = page.thumbnail(of: pointSize, for: box)
        guard thumb.size.width > 1, thumb.size.height > 1, let cg = raster(thumb), cg.width > 0, cg.height > 0 else {
            throw ImageLoadError.unreadablePDF
        }
        return fit(cg, maxSide: maxSide)
    }

    private static func raster(_ image: NSImage) -> CGImage? {
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let cg = rep.cgImage {
            return cg
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func prefersJPEG(data: Data, filename: String) -> Bool {
        if data.starts(with: jpegMagic) { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "heic", "webp"].contains(ext) { return true }
        if ["png", "gif", "tiff", "tif"].contains(ext) { return false }
        let head = String(decoding: data.prefix(64), as: UTF8.self).lowercased()
        if head.contains("heic") || head.contains("heif") || head.contains("webp") { return true }
        return false
    }

    private static func fit(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let pixelWidth = max(1, Int((width * scale).rounded()))
        let pixelHeight = max(1, Int((height * scale).rounded()))
        guard let ctx = bitmapContext(width: pixelWidth, height: pixelHeight, opaque: false) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return ctx.makeImage() ?? image
    }

    private static func encode(_ image: CGImage, jpeg: Bool) throws -> (data: Data, mime: String) {
        if jpeg {
            let flat = flatten(image)
            if let data = destinationData(flat, type: .jpeg, quality: 0.85) {
                return (data, "image/jpeg")
            }
        }
        if let data = destinationData(image, type: .png, quality: nil) {
            return (data, "image/png")
        }
        throw ImageLoadError.encodeFailed
    }

    private static func flatten(_ image: CGImage) -> CGImage {
        guard let ctx = bitmapContext(width: image.width, height: image.height, opaque: true) else { return image }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    private static func destinationData(_ image: CGImage, type: UTType, quality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [:]
        if let quality {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func bitmapContext(width: Int, height: Int, opaque: Bool) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        let info = CGBitmapInfo.byteOrder32Big.rawValue | alpha.rawValue
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: info
        )
    }
}

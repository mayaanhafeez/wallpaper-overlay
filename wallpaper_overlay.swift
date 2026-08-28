// Full-screen wallpaper picker overlay: darkens every display and shows a
// coverflow strip of images from one folder.
//
// It is only the picker. The shell wrapper owns theme discovery and calls the
// wallpaper backend after this process prints the chosen absolute path.
//
//   wallpaper_overlay [--dir <path>] [--title <text>] [--select <path>]
//                     [--accent <hex>] [--value <hex>] [--muted <hex>]
//                     [--title-color <hex>] [--dim <hex>]
//
// stdout is load-bearing: success prints exactly one selected path and exits 0;
// cancel prints nothing and exits 1. Diagnostics go to stderr.

import AppKit
import ImageIO
import QuartzCore

// MARK: - options

/// One colour per role so sketchybar's theme palette can come through without
/// the overlay inventing its own hierarchy.
struct Palette {
    var accent = NSColor(calibratedWhite: 0.96, alpha: 1)
    var value = NSColor(calibratedWhite: 0.96, alpha: 1)
    var muted = NSColor(calibratedWhite: 0.96, alpha: 0.55)
    var title = NSColor(calibratedWhite: 0.96, alpha: 0.75)
    var dim = NSColor.black.withAlphaComponent(0.78)
}

struct Options {
    var dir: String = NSString(string: "~/Pictures/wallpapers").expandingTildeInPath
    /// nil means "use the folder name".
    var title: String? = nil
    var select: String? = nil
    var palette = Palette()

    static func parse(_ argv: [String]) -> Options {
        var opts = Options()
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            let next: String? = (i + 1 < argv.count) ? argv[i + 1] : nil
            switch arg {
            case "--dir":
                if let v = next { opts.dir = NSString(string: v).expandingTildeInPath; i += 1 }
            case "--title":
                if let v = next { opts.title = v; i += 1 }
            case "--select":
                if let v = next { opts.select = NSString(string: v).expandingTildeInPath; i += 1 }
            case "--accent":
                if let v = next, let c = NSColor(hex: v) { opts.palette.accent = c; i += 1 }
            case "--value":
                if let v = next, let c = NSColor(hex: v) { opts.palette.value = c; i += 1 }
            case "--muted":
                if let v = next, let c = NSColor(hex: v) { opts.palette.muted = c; i += 1 }
            case "--title-color":
                if let v = next, let c = NSColor(hex: v) { opts.palette.title = c; i += 1 }
            case "--dim":
                if let v = next, let c = NSColor(hex: v) { opts.palette.dim = c; i += 1 }
            default:
                break
            }
            i += 1
        }
        return opts
    }
}

extension NSColor {
    // "#rrggbb", "rrggbb", "0xaarrggbb" -- the same argb form sketchybar uses.
    convenience init?(hex: String) {
        var text = hex.lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.hasPrefix("0x") { text.removeFirst(2) }
        guard let value = UInt32(text, radix: 16) else { return nil }
        let a, r, g, b: CGFloat
        switch text.count {
        case 8:
            a = CGFloat((value >> 24) & 0xff) / 255
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
        case 6:
            a = 1
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
        default:
            return nil
        }
        self.init(calibratedRed: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - files

struct Wallpaper {
    let url: URL

    var path: String { url.path }
    var filename: String { url.lastPathComponent }
}

private let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"
]

func absolutePath(_ path: String) -> String {
    let expanded = NSString(string: path).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    if url.path.hasPrefix("/") { return url.standardizedFileURL.path }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(expanded)
        .standardizedFileURL.path
}

func wallpapers(in dir: String) -> [Wallpaper] {
    let url = URL(fileURLWithPath: absolutePath(dir), isDirectory: true)
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    return contents.compactMap { url in
        guard !url.lastPathComponent.hasPrefix(".") else { return nil }
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        return Wallpaper(url: url.standardizedFileURL)
    }.sorted {
        $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
    }
}

func stderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

// MARK: - thumbnails

final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Decoded thumbnails, cached in memory for this run and on disk across runs.
///
/// These are full-resolution wallpapers -- decoding the twelve in one theme folder
/// serially costs about 1.7s, and a single 10240x5760 PNG accounts for 744ms of that.
/// Three things keep the picker responsive anyway: decodes run concurrently, the
/// selected image is asked for first, and the downsampled result is kept on disk so a
/// second launch draws immediately instead of decoding again.
final class ThumbnailStore {
    /// Concurrent, but bounded: the unsorted folder holds 66 wallpapers and an
    /// unbounded fan-out there would have every core decoding a different 70MB PNG.
    private let queue = DispatchQueue(label: "wallpaper-overlay.thumbnails",
                                      qos: .userInitiated, attributes: .concurrent)
    private let slots: DispatchSemaphore
    private let cache = NSCache<NSString, ImageBox>()
    private var loading = Set<String>()
    private let pixelWidth: Int
    private let cacheDirectory: URL?

    /// How long a disk entry is kept. This is a retention choice, not a correctness
    /// one -- the cache key already covers staleness, so raising it only costs disk.
    private static let ttl: TimeInterval = 40 * 60

    init(pixelWidth: Int) {
        self.pixelWidth = pixelWidth
        self.slots = DispatchSemaphore(value: ProcessInfo.processInfo.activeProcessorCount)
        cache.countLimit = 18

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let directory = base?.appendingPathComponent("wallpaper-overlay/thumbs", isDirectory: true)
        if let directory,
           (try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)) != nil {
            self.cacheDirectory = directory
        } else {
            // A cache we cannot write is not a reason to fail; decode every time.
            self.cacheDirectory = nil
        }
    }

    func image(for path: String) -> CGImage? {
        cache.object(forKey: path as NSString)?.image
    }

    /// Synchronous disk lookup, cheap enough to run before the window is shown: the
    /// cached file is already thumbnail-sized, so this is a couple of milliseconds
    /// rather than the full-resolution decode it replaces.
    func cachedImage(for path: String) -> CGImage? {
        if let image = image(for: path) { return image }
        guard let image = readCache(for: path) else { return nil }
        cache.setObject(ImageBox(image), forKey: path as NSString)
        return image
    }

    func load(path: String, completion: @escaping (String, CGImage?) -> Void) {
        if let image = image(for: path) {
            completion(path, image)
            return
        }
        guard !loading.contains(path) else { return }
        loading.insert(path)

        queue.async { [weak self] in
            guard let self else { return }
            self.slots.wait()
            let cached = self.readCache(for: path)
            let image = cached ?? self.decode(path: path)
            self.slots.signal()
            DispatchQueue.main.async {
                if let image { self.cache.setObject(ImageBox(image), forKey: path as NSString) }
                self.loading.remove(path)
                completion(path, image)
            }
            // Written after the image is handed over, so a cold launch never pays for
            // the cache it is filling.
            if cached == nil, let image { self.writeCache(image, for: path) }
        }
    }

    /// Decodes everything the ±3 window will not reach into the disk cache, so arrowing
    /// past the fourth image stays instant. Runs below the interactive decodes and
    /// deliberately does not touch the memory cache -- 66 decoded images is exactly what
    /// countLimit exists to prevent.
    func warm(paths: [String]) {
        guard cacheDirectory != nil else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for path in paths {
                if self.cacheURL(for: path).flatMap({ self.unexpired($0) }) != nil { continue }
                self.slots.wait()
                let image = self.decode(path: path)
                self.slots.signal()
                if let image { self.writeCache(image, for: path) }
            }
        }
    }

    /// Drops entries past the hold time. Failures are ignored throughout: a cache sweep
    /// must never be able to affect the picker.
    func sweep() {
        guard let directory = cacheDirectory else { return }
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys) else { return }
            let cutoff = Date().addingTimeInterval(-ThumbnailStore.ttl)
            for entry in entries {
                let modified = (try? entry.resourceValues(forKeys: Set(keys)))?
                    .contentModificationDate
                if let modified, modified >= cutoff { continue }
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    // MARK: cache plumbing

    /// Keyed by the source's identity and the size we rendered it at, so a re-saved
    /// wallpaper or a display with a different backing scale misses cleanly rather than
    /// serving something stale or the wrong size.
    private func cacheURL(for path: String) -> URL? {
        guard let directory = cacheDirectory else { return nil }
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        let seed = "\(path)\0\(Int(modified))\0\(size)\0\(pixelWidth)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(seed.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return directory.appendingPathComponent(String(format: "%016llx.jpg", hash))
    }

    private func unexpired(_ url: URL) -> URL? {
        let key: URLResourceKey = .contentModificationDateKey
        guard let modified = (try? url.resourceValues(forKeys: [key]))?.contentModificationDate,
              modified >= Date().addingTimeInterval(-ThumbnailStore.ttl) else { return nil }
        return url
    }

    private func readCache(for path: String) -> CGImage? {
        guard let url = cacheURL(for: path) else { return nil }
        guard unexpired(url) != nil else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func writeCache(_ image: CGImage, for path: String) {
        guard let url = cacheURL(for: path) else { return }
        // Written to a sibling and renamed: the process exits with exit(), so a warm
        // pass can be killed mid-write, and a truncated JPEG would read back as a
        // perfectly valid -- and wrong -- thumbnail on the next launch.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: temporary, to: url)
    }

    private func decode(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelWidth,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - card

final class Card {
    let root = CALayer()
    private let image = CALayer()
    private let placeholderColor: NSColor
    private let accent: NSColor
    private let scaleFactor: CGFloat
    private(set) var path: String
    /// Set while the card is sliding off. It stays in the view's table until the slide
    /// finishes so that arrowing back can reclaim it mid-flight.
    var departing = false

    init(path: String, accent: NSColor, muted: NSColor, scaleFactor: CGFloat) {
        self.path = path
        self.accent = accent
        self.placeholderColor = muted.withAlphaComponent(0.16)
        self.scaleFactor = scaleFactor

        root.contentsScale = scaleFactor
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = 0
        root.shadowRadius = 24
        root.shadowOffset = CGSize(width: 0, height: -10)

        image.contentsScale = scaleFactor
        image.contentsGravity = .resizeAspectFill
        image.masksToBounds = true
        image.cornerRadius = 16
        image.borderWidth = 0
        image.borderColor = accent.cgColor
        image.backgroundColor = placeholderColor.cgColor
        root.addSublayer(image)
    }

    func set(path newPath: String, cgImage: CGImage?) {
        path = newPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = cgImage
        image.backgroundColor = cgImage == nil ? placeholderColor.cgColor : NSColor.clear.cgColor
        CATransaction.commit()
    }

    func setGeometry(frame: CGRect, opacity: Float, focused: Bool, z: CGFloat, animated: Bool) {
        root.zPosition = z
        if animated { settlePresentation() }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(OverlayView.transition)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        root.frame = frame
        root.opacity = opacity
        root.shadowOpacity = focused ? 0.35 : 0
        image.frame = root.bounds
        image.cornerRadius = focused ? 18 : 14
        image.borderWidth = focused ? 2 : 0
        image.borderColor = accent.cgColor
        root.shadowPath = CGPath(roundedRect: root.bounds, cornerWidth: image.cornerRadius,
                                 cornerHeight: image.cornerRadius, transform: nil)
        CATransaction.commit()
    }

    func contains(_ point: CGPoint) -> Bool {
        let layer = root.presentation() ?? root
        return layer.frame.contains(point)
    }

    private func settlePresentation() {
        guard let presentation = root.presentation() else {
            root.removeAllAnimations()
            image.removeAllAnimations()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.position = presentation.position
        root.bounds = presentation.bounds
        root.opacity = presentation.opacity
        root.removeAllAnimations()
        image.removeAllAnimations()
        CATransaction.commit()
    }
}

// MARK: - view

final class OverlayView: NSView {
    /// One discrete step. Short enough that a held arrow key keeps up, and paired with
    /// cards that actually travel in and out it reads as a slide rather than a fade.
    static let transition: CFTimeInterval = 0.14

    private let dim = CALayer()
    private let titleLabel = CATextLayer()
    private let filenameLabel = CATextLayer()
    private let pagerLabel = CATextLayer()
    private let hintLabel = CATextLayer()
    private let pagerLayer = CALayer()
    private let palette: Palette
    private let wallpapers: [Wallpaper]
    private let thumbnails: ThumbnailStore
    private let scaleFactor: CGFloat
    private let centerSize: CGSize
    private var cards: [String: Card] = [:]
    private(set) var selected: Int

    init(frame: NSRect, options: Options, wallpapers: [Wallpaper], selected: Int,
         scaleFactor: CGFloat) {
        self.palette = options.palette
        self.wallpapers = wallpapers
        self.selected = selected
        self.scaleFactor = scaleFactor
        self.centerSize = OverlayView.cardSize(for: frame.size)
        self.thumbnails = ThumbnailStore(pixelWidth: Int(ceil(centerSize.width * scaleFactor)))
        super.init(frame: frame)

        wantsLayer = true
        let host = CALayer()
        host.frame = bounds
        host.contentsScale = scaleFactor
        layer = host

        dim.frame = bounds
        dim.backgroundColor = palette.dim.cgColor
        dim.contentsScale = scaleFactor
        host.addSublayer(dim)

        configure(label: titleLabel, size: 12, weight: .semibold, color: palette.title)
        titleLabel.string = (options.title
            ?? NSString(string: options.dir).lastPathComponent).uppercased()
        titleLabel.frame = CGRect(x: 0, y: bounds.midY + centerSize.height / 2 + 42,
                                  width: bounds.width, height: 20)
        host.addSublayer(titleLabel)

        configure(label: filenameLabel, size: 13, weight: .regular, color: palette.value)
        filenameLabel.frame = CGRect(x: 0, y: bounds.midY - centerSize.height / 2 - 44,
                                     width: bounds.width, height: 20)
        host.addSublayer(filenameLabel)

        pagerLayer.frame = CGRect(x: 0, y: bounds.midY - centerSize.height / 2 - 76,
                                  width: bounds.width, height: 16)
        pagerLayer.contentsScale = scaleFactor
        host.addSublayer(pagerLayer)

        configure(label: pagerLabel, size: 10, weight: .regular, color: palette.muted)
        pagerLabel.frame = pagerLayer.frame
        host.addSublayer(pagerLabel)

        configure(label: hintLabel, size: 10, weight: .regular, color: palette.muted)
        hintLabel.string = "←/→ browse   ⏎ set   esc cancel"
        hintLabel.frame = CGRect(x: 0, y: bounds.midY - centerSize.height / 2 - 104,
                                 width: bounds.width, height: 16)
        host.addSublayer(hintLabel)

        layoutCards(animated: false)
        updateText()
        prefetch()
    }

    required init?(coder: NSCoder) { nil }

    private static func cardSize(for screen: CGSize) -> CGSize {
        // The display's aspect is the shape every wallpaper will occupy.
        let aspect = screen.width / max(1, screen.height)
        var width = screen.width * 0.40
        var height = width / aspect
        if height > screen.height * 0.52 {
            height = screen.height * 0.52
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    private static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont(name: "JetBrainsMono Nerd Font", size: size)
            ?? NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func configure(label: CATextLayer, size: CGFloat, weight: NSFont.Weight,
                           color: NSColor) {
        label.font = OverlayView.font(size: size, weight: weight)
        label.fontSize = size
        label.alignmentMode = .center
        label.foregroundColor = color.cgColor
        label.contentsScale = scaleFactor
    }

    func move(to index: Int) {
        let clamped = min(max(0, index), wallpapers.count - 1)
        guard clamped != selected else { return }
        selected = clamped
        layoutCards(animated: true)
        updateText()
        prefetch()
    }

    func selectFirst() { move(to: 0) }
    func selectLast() { move(to: wallpapers.count - 1) }

    func clickedIndex(at point: CGPoint) -> Int? {
        for distance in 0...2 {
            let slots = distance == 0 ? [0] : [-distance, distance]
            for slot in slots {
                let index = selected + slot
                guard wallpapers.indices.contains(index) else { continue }
                let path = wallpapers[index].path
                guard let card = cards[path], !card.departing,
                      card.contains(point) else { continue }
                return index
            }
        }
        return nil
    }

    private func layoutCards(animated: Bool) {
        let visible = (-2 ... 2).compactMap { slot -> (Int, Int)? in
            let index = selected + slot
            guard wallpapers.indices.contains(index) else { return nil }
            return (slot, index)
        }
        let wanted = Set(visible.map { wallpapers[$0.1].path })

        for (path, card) in cards where !wanted.contains(path) {
            guard !card.departing else { continue }
            guard animated else {
                card.root.removeFromSuperlayer()
                cards.removeValue(forKey: path)
                continue
            }
            // Slide it out rather than deleting it on the spot, and keep it in the table
            // until it lands so a reversal can catch it. The completion block re-checks
            // the flag: by the time it runs the card may have been reclaimed.
            card.departing = true
            let exit = card.root.frame.midX < bounds.midX ? -3 : 3
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak card] in
                guard let self, let card, card.departing else { return }
                card.root.removeFromSuperlayer()
                self.cards.removeValue(forKey: path)
            }
            card.setGeometry(frame: frame(for: exit), opacity: opacity(for: exit),
                             focused: false, z: z(for: exit), animated: true)
            CATransaction.commit()
        }

        for (slot, index) in visible.sorted(by: { $0.0 < $1.0 }) {
            let wallpaper = wallpapers[index]
            let path = wallpaper.path
            let card: Card
            let travelling: Bool
            if let existing = cards[path] {
                card = existing
                // Reclaimed mid-exit: clearing the flag defuses its completion block.
                card.departing = false
                travelling = true
            } else {
                card = Card(path: path, accent: palette.accent, muted: palette.muted,
                            scaleFactor: scaleFactor)
                card.set(path: path, cgImage: thumbnails.cachedImage(for: path))
                cards[path] = card
                layer?.addSublayer(card.root)
                if animated {
                    // Park it off-screen on the side it is arriving from, instantly, so
                    // that the animated pass below has somewhere to travel from.
                    let entry = slot < 0 ? -3 : 3
                    card.setGeometry(frame: frame(for: entry), opacity: opacity(for: entry),
                                     focused: false, z: z(for: entry), animated: false)
                }
                travelling = animated
            }
            card.setGeometry(frame: frame(for: slot), opacity: opacity(for: slot),
                             focused: slot == 0, z: z(for: slot),
                             animated: animated && travelling)
        }
    }

    private func frame(for slot: Int) -> CGRect {
        let factor = scale(for: slot)
        let size = CGSize(width: centerSize.width * factor, height: centerSize.height * factor)
        let sign = slot < 0 ? -1 : 1
        let distance: CGFloat
        switch abs(slot) {
        case 1: distance = centerSize.width * 0.58
        case 2: distance = centerSize.width * 0.92
        case 3: distance = centerSize.width * 1.25
        default: distance = 0
        }
        let center = CGPoint(x: bounds.midX + CGFloat(sign) * distance, y: bounds.midY)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    // |slot| == 3 is never a resting position -- it is only where cards slide in from
    // and out to, far enough past the edge that the travel reads as motion, not a pop.
    private func scale(for slot: Int) -> CGFloat {
        switch abs(slot) {
        case 1: return 0.72
        case 2: return 0.52
        case 3: return 0.40
        default: return 1
        }
    }

    private func opacity(for slot: Int) -> Float {
        switch abs(slot) {
        case 1: return 0.55
        case 2: return 0.25
        case 3: return 0
        default: return 1
        }
    }

    private func z(for slot: Int) -> CGFloat {
        CGFloat(10 - abs(slot))
    }

    private func updateText() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        filenameLabel.string = wallpapers[selected].filename
        updatePager()
        CATransaction.commit()
    }

    private func updatePager() {
        pagerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        if wallpapers.count > 15 {
            pagerLabel.string = "\(selected + 1) / \(wallpapers.count)"
            return
        }
        pagerLabel.string = ""
        let active: CGFloat = 7
        let inactive: CGFloat = 5
        let gap: CGFloat = 8
        let widths = wallpapers.indices.map { $0 == selected ? active : inactive }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
        var x = (bounds.width - total) / 2

        for i in wallpapers.indices {
            let side = widths[i]
            let dot = CAShapeLayer()
            dot.contentsScale = scaleFactor
            dot.frame = CGRect(x: x, y: (pagerLayer.bounds.height - side) / 2,
                               width: side, height: side)
            dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.fillColor = i == selected
                ? palette.accent.cgColor
                : palette.muted.withAlphaComponent(0.28).cgColor
            pagerLayer.addSublayer(dot)
            x += side + gap
        }
    }

    /// Ordered by distance from the selection rather than by index, so the image the
    /// user is looking at claims a decode slot first. Ascending order put it fourth in
    /// line, behind up to three unrelated full-resolution decodes.
    /// Called once the overlay is on screen: everything the ±3 window will not reach is
    /// decoded into the disk cache in the background, and stale entries are dropped.
    func warmRemaining() {
        let near = Set((max(0, selected - 3) ... min(wallpapers.count - 1, selected + 3))
            .map { wallpapers[$0].path })
        thumbnails.warm(paths: wallpapers.map(\.path).filter { !near.contains($0) })
        thumbnails.sweep()
    }

    private func prefetch() {
        var indices = [selected]
        for step in 1 ... 3 {
            for index in [selected - step, selected + step] where wallpapers.indices.contains(index) {
                indices.append(index)
            }
        }
        for index in indices {
            let path = wallpapers[index].path
            thumbnails.load(path: path) { [weak self] loadedPath, image in
                guard let self, let card = self.cards[loadedPath], card.path == loadedPath else {
                    return
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                card.set(path: loadedPath, cgImage: image)
                CATransaction.commit()
            }
        }
    }
}

// MARK: - window

/// The other displays get the backdrop and nothing else, so the desktop dims
/// everywhere while the picker stays on the screen the pointer is on.
final class DimView: NSView {
    init(frame: NSRect, color: NSColor, scaleFactor: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        let host = CALayer()
        host.frame = bounds
        host.contentsScale = scaleFactor
        host.backgroundColor = color.cgColor
        layer = host
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - window

final class OverlayWindow: NSWindow {
    // Borderless windows refuse key status by default, which would swallow Escape.
    override var canBecomeKey: Bool { true }
}

// MARK: - controller

final class Controller: NSObject, NSApplicationDelegate {
    private let options: Options
    private let wallpapers: [Wallpaper]
    private var windows: [OverlayWindow] = []
    private var view: OverlayView!
    private var closing = false

    init(options: Options, wallpapers: [Wallpaper]) {
        self.options = options
        self.wallpapers = wallpapers
    }

    private func makeWindow(covering screen: NSScreen) -> OverlayWindow {
        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.setFrame(screen.frame, display: true)
        window.alphaValue = 0
        return window
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The carousel goes where the pointer is; every other display is covered
        // too, so one bright monitor cannot sit next to a dimmed one.
        let mouse = NSEvent.mouseLocation
        let active = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let selected = initialSelection()

        for screen in NSScreen.screens {
            let scaleFactor = screen.backingScaleFactor
            let window = makeWindow(covering: screen)
            let bounds = NSRect(origin: .zero, size: screen.frame.size)

            if screen === active {
                view = OverlayView(frame: bounds, options: options, wallpapers: wallpapers,
                                   selected: selected, scaleFactor: scaleFactor)
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
            } else {
                window.contentView = DimView(frame: bounds, color: options.palette.dim,
                                             scaleFactor: scaleFactor)
                window.orderFront(nil)
            }
            windows.append(window)
        }

        view.warmRemaining()

        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            for window in windows { window.animator().alphaValue = 1 }
        }

        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                return self.handleKey(event) ? nil : event
            case .leftMouseDown:
                self.handleClick(event)
                return nil
            default:
                return event
            }
        }
    }

    private func initialSelection() -> Int {
        guard let select = options.select else { return 0 }
        let path = absolutePath(select)
        return wallpapers.firstIndex { $0.path == path } ?? 0
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123:
            view.move(to: view.selected - 1)
        case 124:
            view.move(to: view.selected + 1)
        case 53:
            dismiss(status: 1)
        case 36, 76:
            choose()
        case 115:
            view.selectFirst()
        case 119:
            view.selectLast()
        default:
            let chars = event.charactersIgnoringModifiers?.lowercased()
            if chars == "h" {
                view.move(to: view.selected - 1)
            } else if chars == "l" {
                view.move(to: view.selected + 1)
            } else {
                return false
            }
        }
        return true
    }

    private func handleClick(_ event: NSEvent) {
        guard event.window?.contentView === view else {
            dismiss(status: 1)
            return
        }
        let point = view.convert(event.locationInWindow, from: nil)
        guard let index = view.clickedIndex(at: point) else {
            dismiss(status: 1)
            return
        }
        if index == view.selected { choose() } else { view.move(to: index) }
    }

    private func choose() {
        FileHandle.standardOutput.write(Data((wallpapers[view.selected].path + "\n").utf8))
        dismiss(status: 0)
    }

    private func dismiss(status: Int32) {
        guard !closing else { return }
        closing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            for window in windows { window.animator().alphaValue = 0 }
        }, completionHandler: {
            exit(status)
        })
    }
}

// MARK: - entry

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let images = wallpapers(in: options.dir)
if images.isEmpty {
    stderr("wallpaper_overlay: no images found in \(absolutePath(options.dir))")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // overlay, not a dock app
let controller = Controller(options: options, wallpapers: images)
app.delegate = controller
app.run()

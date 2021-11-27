import XCTest
@testable import DMCMovieWriter

final class DMCMovieWriterTests: XCTestCase {
    func tempMovieURL() -> URL {
        // https://nshipster.com/temporary-files/
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
        let tempFilename = "\(ProcessInfo().globallyUniqueString).mov"
        return tmpDir.appendingPathComponent(tempFilename)
    }
    
    func testCanWriteStuff() throws {
        let width = 640
        let height = 480
        let outpath = tempMovieURL()
        
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: outpath.absoluteURL.path))

        let movieWriter = try! DMCMovieWriter(outpath: outpath, width: width, height: height)
        
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath.fill(rect)
            return true
        }
        
        try movieWriter.addFrame(image, duration: 3.0)
        try movieWriter.finish()
        
        // Some test, huh.
        XCTAssertTrue(fm.fileExists(atPath: outpath.absoluteURL.path))
        try fm.removeItem(at: outpath)
    }
    
    func testInvalidDuration() throws {
        let width = 640
        let height = 480
        let outpath = tempMovieURL()
        
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: outpath.absoluteURL.path))

        let movieWriter = try! DMCMovieWriter(outpath: outpath, width: width, height: height)
        
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath.fill(rect)
            return true
        }
        
        for _ in 0..<3 {
            try movieWriter.addFrame(image, duration: -1.0)
        }
        // Failure should manifest once all frames have been written.
        XCTAssertThrowsError(try movieWriter.finish())
        if fm.fileExists(atPath: outpath.absoluteURL.path) {
            try fm.removeItem(at: outpath)
        }
    }
    
}

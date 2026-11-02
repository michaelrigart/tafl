import Foundation

public enum ConfigWatchEvent {
    /// Truncating a file in place posts an attribute event alone, ahead of the write that fills it;
    /// reading then would see an empty file. The write that follows reloads.
    public static func shouldReload(mask: DispatchSource.FileSystemEvent) -> Bool {
        mask != .attrib
    }
}

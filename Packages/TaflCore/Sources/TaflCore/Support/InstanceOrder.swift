import Foundation

public enum InstanceOrder {
    /// A copy defers to one that started earlier, the lower process id breaking a tie, so two
    /// copies started together do not both quit.
    public static func defers(own: (launchDate: Date?, pid: Int32), to other: (launchDate: Date?, pid: Int32)) -> Bool {
        if let ownDate = own.launchDate, let otherDate = other.launchDate, ownDate != otherDate {
            return otherDate < ownDate
        }
        return other.pid < own.pid
    }
}

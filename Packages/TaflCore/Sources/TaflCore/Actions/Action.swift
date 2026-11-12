import Foundation

public enum Action: String, CaseIterable, Codable, Sendable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    case firstThird = "first-third"
    case centerThird = "center-third"
    case lastThird = "last-third"
    case firstTwoThirds = "first-two-thirds"
    case centerTwoThirds = "center-two-thirds"
    case lastTwoThirds = "last-two-thirds"
    case maximize
    case maximizeHeight = "maximize-height"
    case center
    case restore
    case larger
    case smaller
    case displayLeft = "display-left"
    case displayRight = "display-right"
    case displayUp = "display-up"
    case displayDown = "display-down"
    case displayUnderPointer = "display-under-pointer"

    public var summary: String {
        switch self {
        case .leftHalf: "Left half of the display"
        case .rightHalf: "Right half of the display"
        case .topHalf: "Top half of the display"
        case .bottomHalf: "Bottom half of the display"
        case .topLeft: "Top left quarter"
        case .topRight: "Top right quarter"
        case .bottomLeft: "Bottom left quarter"
        case .bottomRight: "Bottom right quarter"
        case .firstThird: "First third of the display"
        case .centerThird: "Middle third of the display"
        case .lastThird: "Last third of the display"
        case .firstTwoThirds: "First two thirds of the display"
        case .centerTwoThirds: "Middle two thirds of the display"
        case .lastTwoThirds: "Last two thirds of the display"
        case .maximize: "Fill the display"
        case .maximizeHeight: "Fill the height of the display, keeping the width"
        case .center: "Center the window, keeping its size"
        case .restore: "Return to the frame before Tafl's first move"
        case .larger: "Make the window larger on every side"
        case .smaller: "Make the window smaller on every side"
        case .displayLeft: "Move to the display on the left"
        case .displayRight: "Move to the display on the right"
        case .displayUp: "Move to the display above"
        case .displayDown: "Move to the display below"
        case .displayUnderPointer: "Move to the display under the pointer"
        }
    }
}
